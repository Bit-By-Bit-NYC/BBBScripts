#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.3"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
ts() { date -u +"%Y%m%dT%H%M%SZ"; }
trim_all() {
  local s="${1//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}
slug() { tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

need az
need jq
need azcopy

CFG="./config.txt"
[[ -f "$CFG" ]] || die "config.txt not found next to the script."
# shellcheck disable=SC1090
source "$CFG"

echo "[*] Script version: ${SCRIPT_VERSION}"

# Required config
: "${SUBSCRIPTION_ID:?set in config.txt}"       # use "current" to not force a switch
: "${VM_RESOURCE_GROUP:?set in config.txt}"

# Defaults
STOP_VM_FOR_SNAPSHOT="$(trim_all "${STOP_VM_FOR_SNAPSHOT:-false}")"
KEEP_SNAPSHOTS="$(trim_all "${KEEP_SNAPSHOTS:-false}")"
COLD_COPY="$(trim_all "${COLD_COPY:-false}")"
COLD_ONLY="$(trim_all "${COLD_ONLY:-false}")"
ARCHIVE_CONTAINER="$(trim_all "${ARCHIVE_CONTAINER:-archive}")"
COLD_CONTAINER="$(trim_all "${COLD_CONTAINER:-archive-cold}")"
DEST_RG_PREFIX="$(trim_all "${DEST_RG_PREFIX:-rg-archive}")"
SA_PREFIX="$(trim_all "${SA_PREFIX:-storarchive}")"
SA_SKU="$(trim_all "${SA_SKU:-Standard_LRS}")"
SA_KIND="$(trim_all "${SA_KIND:-StorageV2}")"
SA_MIN_TLS="$(trim_all "${SA_MIN_TLS:-TLS1_2}")"
DEST_SAS_HOURS="$(trim_all "${DEST_SAS_HOURS:-24}")"
TICKET="$(trim_all "${TICKET:-none}")"

echo "[*] Config says SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
echo "[*] Source VM Resource Group: ${VM_RESOURCE_GROUP}"
echo "[*] Containers: archive=${ARCHIVE_CONTAINER} cold=${COLD_CONTAINER}"
echo "[*] Flags: STOP_VM=${STOP_VM_FOR_SNAPSHOT} KEEP_SNAPSHOTS=${KEEP_SNAPSHOTS} COLD_COPY=${COLD_COPY} COLD_ONLY=${COLD_ONLY}"
echo "[*] Provisioning: DEST_RG_PREFIX=${DEST_RG_PREFIX} SA_PREFIX=${SA_PREFIX} SKU=${SA_SKU} KIND=${SA_KIND}"
echo "[*] Ticket: ${TICKET}"
echo

echo "[*] Current az context:"
az account show --query "{name:name,id:id,tenant:tenantId,user:user.name}" -o table \
  || die "Not logged in. Run 'az login' first."
CURRENT_SUB_ID="$(az account show --query id -o tsv)"

# Only switch if explicitly different
if [[ "${SUBSCRIPTION_ID}" != "current" && "${SUBSCRIPTION_ID}" != "${CURRENT_SUB_ID}" ]]; then
  echo "[*] Switching az context to subscription ${SUBSCRIPTION_ID} ..."
  az account set --subscription "${SUBSCRIPTION_ID}" || die "Unable to set subscription."
  CURRENT_SUB_ID="$(az account show --query id -o tsv)"
fi

VM_RESOURCE_GROUP="$(trim_all "$VM_RESOURCE_GROUP")"

# ---------- Find RG in current or any subscription (auto-switch) ----------
if ! az group show -n "${VM_RESOURCE_GROUP}" >/dev/null 2>&1; then
  echo "[-] Resource group '${VM_RESOURCE_GROUP}' not found in ${CURRENT_SUB_ID}."
  echo "[*] Searching all visible subscriptions..."
  mapfile -t SUBS < <(az account list --query "[].{id:id,name:name}" -o tsv)
  FOUND_SUB=""
  FOUND_NAME=""
  for row in "${SUBS[@]}"; do
    sid="${row%%$'\t'*}"
    sname="${row#*$'\t'}"
    if az group show -n "${VM_RESOURCE_GROUP}" --subscription "${sid}" >/dev/null 2>&1; then
      FOUND_SUB="${sid}"
      FOUND_NAME="${sname}"
      echo "[+] Found RG '${VM_RESOURCE_GROUP}' in subscription: ${sname} (${sid})"
      break
    fi
  done
  if [[ -n "${FOUND_SUB}" ]]; then
    if [[ "${FOUND_SUB}" != "${CURRENT_SUB_ID}" ]]; then
      echo "[*] Auto-switching az context to discovered subscription '${FOUND_NAME}' (${FOUND_SUB}) ..."
      az account set --subscription "${FOUND_SUB}" || die "Failed to set subscription."
      CURRENT_SUB_ID="${FOUND_SUB}"
    else
      echo "[*] RG is in current subscription; no switch needed."
    fi
  else
    die "Resource group '${VM_RESOURCE_GROUP}' not found in any accessible subscription."
  fi
fi

echo
echo "[*] Effective az context after discovery:"
az account show --query "{name:name,id:id,tenant:tenantId,user:user.name}" -o table
echo

echo "[*] Enumerating VMs in RG '${VM_RESOURCE_GROUP}'..."
mapfile -t VM_LINES < <(az vm list -g "${VM_RESOURCE_GROUP}" --query "[].{name:name,location:location}" -o tsv)
[[ ${#VM_LINES[@]} -gt 0 ]] || die "No VMs found in resource group '${VM_RESOURCE_GROUP}'."

i=1; declare -A VM_MAP VM_LOC
for line in "${VM_LINES[@]}"; do
  name="$(trim_all "${line%%$'\t'*}")"
  loc="$(trim_all "${line#*$'\t'}")"
  VM_MAP["$i"]="$name"
  VM_LOC["$name"]="$loc"
  printf "  %2d) %s  (%s)\n" "$i" "$name" "$loc"
  ((i++))
done

read -r -p "Select a VM to archive (number): " CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalid selection."
VM_NAME="${VM_MAP[$CHOICE]:-}"
[[ -n "$VM_NAME" ]] || die "No VM mapped to selection $CHOICE."
VM_LOCATION="$(trim_all "${VM_LOC[$VM_NAME]}")"
[[ -n "$VM_LOCATION" ]] || die "Could not resolve VM location."
STAMP="$(ts)"

echo
echo "[*] Selected VM: ${VM_NAME}"
echo "[*] VM Location: ${VM_LOCATION}"
echo

# ---------- Naming with ticket suffix ----------
t_slug="$(echo "$TICKET" | slug)"
ticket_digits_full="$(echo "$TICKET" | tr -cd '0-9')"
[[ -z "$ticket_digits_full" ]] && ticket_digits_full="0000"

# RG: rg-archive-<region>[-<ticket>]
RG_NAME_BASE="${DEST_RG_PREFIX}-$(echo "${VM_LOCATION}" | slug)"
RG_NAME="$RG_NAME_BASE"
[[ -n "$t_slug" && "$t_slug" != "none" ]] && RG_NAME="${RG_NAME_BASE}-${t_slug}"

# Storage Account: valid, no hyphens, ≤24 chars, starts with letter, suffix t<full ticket digits>
SUB_HASH="$(echo -n "${CURRENT_SUB_ID}" | sha1sum | cut -c1-6)"
LOC_SLUG="$(echo "${VM_LOCATION}" | slug)"
BASE="$(printf "%s%s%s" "$(echo "$SA_PREFIX" | slug)" "$LOC_SLUG" "$SUB_HASH")"
BASE="${BASE,,}"; BASE="${BASE//[^a-z0-9]/}"

SUFFIX="t${ticket_digits_full}"
MAXLEN=24
BASELEN=$((MAXLEN - ${#SUFFIX}))
(( BASELEN < 1 )) && BASELEN=1
SA_CANDIDATE="${BASE:0:${BASELEN}}${SUFFIX}"
if [[ ! "$SA_CANDIDATE" =~ ^[a-z] ]]; then
  SA_CANDIDATE="a${SA_CANDIDATE:0:$((MAXLEN-1))}"
fi
while (( ${#SA_CANDIDATE} < 3 )); do SA_CANDIDATE="${SA_CANDIDATE}0"; done
STORAGE_ACCOUNT="$SA_CANDIDATE"

echo "[*] Target RG: ${RG_NAME}"
echo "[*] Target Storage Account: ${STORAGE_ACCOUNT}"

# ---------- Create/Tag RG ----------
if ! az group show -n "${RG_NAME}" >/dev/null 2>&1; then
  echo "[*] Creating resource group '${RG_NAME}' in '${VM_LOCATION}' ..."
  az group create -n "${RG_NAME}" -l "${VM_LOCATION}" \
    --tags ticket="${TICKET}" source="vm-archive-script" >/dev/null
else
  echo "[*] Updating tags on existing RG '${RG_NAME}' ..."
  az group update -n "${RG_NAME}" --set tags.ticket="${TICKET}" tags.source="vm-archive-script" >/dev/null
fi

# ---------- Create/Tag Storage Account ----------
if ! az storage account show -g "${RG_NAME}" -n "${STORAGE_ACCOUNT}" >/dev/null 2>&1; then
  echo "[*] Creating storage account '${STORAGE_ACCOUNT}' in '${VM_LOCATION}' ..."
  az storage account create \
    -g "${RG_NAME}" -n "${STORAGE_ACCOUNT}" -l "${VM_LOCATION}" \
    --sku "${SA_SKU}" --kind "${SA_KIND}" \
    --min-tls-version "${SA_MIN_TLS}" \
    --https-only true \
    --allow-blob-public-access false \
    --tags ticket="${TICKET}" bbb_ticket="${TICKET}" source="vm-archive-script" >/dev/null
else
  echo "[*] Updating tags on storage account '${STORAGE_ACCOUNT}' ..."
  if ! az storage account update \
      -g "${RG_NAME}" -n "${STORAGE_ACCOUNT}" \
      --set tags.ticket="${TICKET}" tags.bbb_ticket="${TICKET}" tags.source="vm-archive-script" >/dev/null; then
    echo "[!] Warning: failed to update tags on storage account '${STORAGE_ACCOUNT}', continuing..." >&2
  fi
fi

echo "[*] Fetching storage account key..."
SA_KEY="$(az storage account keys list -g "${RG_NAME}" -n "${STORAGE_ACCOUNT}" --query '[0].value' -o tsv)"
[[ -n "$SA_KEY" ]] || die "Failed to fetch storage account key."

echo "[*] Ensuring containers exist..."
az storage container create --name "${ARCHIVE_CONTAINER}" \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" >/dev/null
az storage container create --name "${COLD_CONTAINER}" \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" >/dev/null

ARCHIVE_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${ARCHIVE_CONTAINER}"
COLD_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONTAINER}"

# ---------- Generate container SAS for AzCopy ----------
END_TIME="$(date -u -d "+${DEST_SAS_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")"

DEST_SAS_RAW="$(az storage container generate-sas \
  --account-name "${STORAGE_ACCOUNT}" \
  --name "${ARCHIVE_CONTAINER}" \
  --expiry "${END_TIME}" \
  --permissions racwdl \
  --account-key "${SA_KEY}" -o tsv)"
DEST_SAS="$(trim_all "${DEST_SAS_RAW}")"
[[ -n "${DEST_SAS}" ]] || die "Failed to generate SAS for archive container."

if [[ "${COLD_COPY,,}" == "true" || "${COLD_ONLY,,}" == "true" ]]; then
  COLD_SAS_RAW="$(az storage container generate-sas \
    --account-name "${STORAGE_ACCOUNT}" \
    --name "${COLD_CONTAINER}" \
    --expiry "${END_TIME}" \
    --permissions racwdl \
    --account-key "${SA_KEY}" -o tsv)"
  COLD_SAS="$(trim_all "${COLD_SAS_RAW}")"
  [[ -n "${COLD_SAS}" ]] || die "Failed to generate SAS for cold container."
else
  COLD_SAS=""
fi

# ---------- Optional stop VM ----------
if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
  echo "[*] Stopping VM '${VM_NAME}' for consistent snapshots..."
  az vm deallocate -g "${VM_RESOURCE_GROUP}" -n "${VM_NAME}" --no-wait
  az vm wait -g "${VM_RESOURCE_GROUP}" -n "${VM_NAME}" --deallocated
fi

# ---------- Discover disks ----------
echo "[*] Discovering disks for '${VM_NAME}' ..."
VM_JSON="$(az vm show -g "${VM_RESOURCE_GROUP}" -n "${VM_NAME}")"
OS_DISK_ID="$(jq -r '.storageProfile.osDisk.managedDisk.id' <<<"$VM_JSON")"
mapfile -t DATA_DISK_IDS < <(jq -r '.storageProfile.dataDisks[].managedDisk.id // empty' <<<"$VM_JSON")
DISK_IDS=("$OS_DISK_ID" "${DATA_DISK_IDS[@]}")
[[ ${#DISK_IDS[@]} -gt 0 ]] || die "No managed disks found."

# ---------- Snapshot + export via AzCopy ----------
SNAP_IDS=()
NEW_BLOBS=()

for DISK_ID in "${DISK_IDS[@]}"; do
  DISK_JSON="$(az disk show --ids "${DISK_ID}")"
  DISK_NAME="$(jq -r '.name' <<<"$DISK_JSON")"
  DISK_RG="$(jq -r '.resourceGroup' <<<"$DISK_JSON")"
  echo "    - Disk: ${DISK_NAME} (rg=${DISK_RG})"

  SNAP_NAME="${DISK_NAME}-snap-$(ts)"
  echo "      > Creating snapshot: ${SNAP_NAME}"
  az snapshot create -g "${DISK_RG}" -n "${SNAP_NAME}" --source "${DISK_ID}" --sku Standard_LRS \
    --tags ticket="${TICKET}" bbb_ticket="${TICKET}" source="vm-archive-script" >/dev/null

  SNAP_ID="$(az snapshot show -g "${DISK_RG}" -n "${SNAP_NAME}" --query id -o tsv)"
  SNAP_IDS+=("${SNAP_ID}")

  echo "      > Granting snapshot read SAS..."
  SNAP_SAS_RAW="$(az snapshot grant-access --duration-in-seconds 86400 --access-level Read --ids "${SNAP_ID}" --query accessSAS -o tsv)"
  SNAP_SAS="$(trim_all "${SNAP_SAS_RAW}")"
  if [[ -z "${SNAP_SAS}" ]]; then
    die "Snapshot SAS is empty for ${SNAP_NAME}; grant-access may have failed."
  fi

  DEST_BLOB="${VM_NAME}-${DISK_NAME}-$(ts).vhd"
  DEST_URL="${ARCHIVE_URL}/${DEST_BLOB}?${DEST_SAS}"

  echo "      > AzCopy debug:"
  echo "        SRC length: ${#SNAP_SAS}"
  echo "        SRC start : ${SNAP_SAS:0:80}"
  echo "        DEST      : ${DEST_URL}"

  # Hot copy: keep as PageBlob
  azcopy copy "${SNAP_SAS}" "${DEST_URL}" \
    --from-to=BlobBlob \
    --blob-type=PageBlob \
    --overwrite=false

  # Metadata on hot blob – best-effort
  if ! az storage blob metadata update \
      --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" \
      --container-name "${ARCHIVE_CONTAINER}" --name "${DEST_BLOB}" \
      --metadata bbb_ticket="${TICKET}" >/dev/null; then
    echo "[!] Warning: failed to set metadata on hot blob '${DEST_BLOB}' (archive)." >&2
  fi

  NEW_BLOBS+=("${DEST_BLOB}")

  echo "      > Revoking snapshot SAS..."
  az snapshot revoke-access --ids "${SNAP_ID}" >/dev/null
done

# ---------- Cold copy (COLD_COPY or COLD_ONLY) ----------
if [[ "${COLD_COPY,,}" == "true" || "${COLD_ONLY,,}" == "true" ]]; then
  echo "[*] Cold copy enabled (COLD_COPY=${COLD_COPY}, COLD_ONLY=${COLD_ONLY}) → copying to '${COLD_CONTAINER}'..."
  for BLOB in "${NEW_BLOBS[@]}"; do
    SRC="${ARCHIVE_URL}/${BLOB}?${DEST_SAS}"
    DST="${COLD_URL}/${BLOB}?${COLD_SAS}"
    echo "    - AzCopy cold: ${SRC} -> ${DST}"

    # Cold copy: explicitly create as BlockBlob so Archive tier is valid
    azcopy copy "${SRC}" "${DST}" \
      --from-to=BlobBlob \
      --blob-type=BlockBlob \
      --overwrite=false

    if ! az storage blob metadata update \
        --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" \
        --container-name "${COLD_CONTAINER}" --name "${BLOB}" \
        --metadata bbb_ticket="${TICKET}" >/dev/null; then
      echo "[!] Warning: failed to set metadata on cold blob '${BLOB}' (cold)." >&2
    fi

    if ! az storage blob set-tier \
        --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" \
        --container-name "${COLD_CONTAINER}" --name "${BLOB}" \
        --tier Archive >/dev/null; then
      echo "[!] Warning: failed to set Archive tier on cold blob '${BLOB}'." >&2
    fi

    if [[ "${COLD_ONLY,,}" == "true" ]]; then
      echo "    - COLD_ONLY=true → deleting hot blob ${BLOB} from '${ARCHIVE_CONTAINER}'"
      if ! az storage blob delete \
          --account-name "${STORAGE_ACCOUNT}" --account-key "${SA_KEY}" \
          --container-name "${ARCHIVE_CONTAINER}" --name "${BLOB}" >/dev/null; then
        echo "[!] Warning: failed to delete hot blob '${BLOB}' from archive (COLD_ONLY)." >&2
      fi
    fi
  done
fi

# ---------- Cleanup ----------
if [[ "${KEEP_SNAPSHOTS,,}" == "true" ]]; then
  echo "[*] KEEP_SNAPSHOTS=true -> leaving snapshots."
else
  echo "[*] Deleting snapshots..."
  for SID in "${SNAP_IDS[@]}"; do az snapshot delete --ids "${SID}" >/dev/null || true; done
fi

echo "=============================================="
echo "[✓] Archive complete for VM '${VM_NAME}' at $(date -u)"
echo "    Script version: ${SCRIPT_VERSION}"
echo "    Effective subscription: ${CURRENT_SUB_ID}"
echo "    Region: ${VM_LOCATION}"
echo "    RG (dest): ${RG_NAME}   [tags: ticket=${TICKET}]"
echo "    Storage: ${STORAGE_ACCOUNT}   [tags: ticket=${TICKET}, bbb_ticket=${TICKET}]"
echo "    Archive container: ${ARCHIVE_CONTAINER}"
echo "    COLD_COPY=${COLD_COPY} COLD_ONLY=${COLD_ONLY}"
[[ "${COLD_COPY,,}" == "true" || "${COLD_ONLY,,}" == "true" ]] && echo "    Cold container: ${COLD_CONTAINER} (Archive tier)"
echo "    Ticket: ${TICKET}"
echo "=============================================="