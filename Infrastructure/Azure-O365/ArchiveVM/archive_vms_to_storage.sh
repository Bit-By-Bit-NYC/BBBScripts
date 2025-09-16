#!/usr/bin/env bash
set -euo pipefail

CFG="./config.txt"
[[ -f "$CFG" ]] || echo "WARN: Missing $CFG (defaults will be used where possible)"
# shellcheck disable=SC1090
source "$CFG" 2>/dev/null || true

# ---------- sane defaults & aliases ----------
VM_SUBSCRIPTION_ID="${VM_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
STORAGE_SUBSCRIPTION_ID="${STORAGE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

VM_RESOURCE_GROUP="${VM_RESOURCE_GROUP:-rg-Spirits}"
STORAGE_RESOURCE_GROUP="${STORAGE_RESOURCE_GROUP:-rg-Spirits-1022621}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-storspirits1022621}"
CONTAINER="${CONTAINER:-archive}"
BBB_TICKET="${BBB_TICKET:-1022621}"
VM_FILTER="${VM_FILTER:-}"

DEST_SAS_HOURS="${DEST_SAS_HOURS:-72}"
SRC_SAS_HOURS="${SRC_SAS_HOURS:-24}"

STOP_VM_FOR_SNAPSHOT="${STOP_VM_FOR_SNAPSHOT:-false}"
DELETE_SNAPSHOTS_AFTER_COPY="${DELETE_SNAPSHOTS_AFTER_COPY:-true}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-false}"

DRY_RUN="${DRY_RUN:-false}"  # NEW: snapshots only; no uploads/copies

if [[ "${KEEP_SNAPSHOTS,,}" == "true" ]]; then
  DELETE_SNAPSHOTS_AFTER_COPY=false
fi
if [[ "${DRY_RUN,,}" == "true" ]]; then
  # Force keep snapshots in dry run
  DELETE_SNAPSHOTS_AFTER_COPY=false
fi

ENABLE_COLD_ARCHIVE="${ENABLE_COLD_ARCHIVE:-false}"
COLD_CONTAINER="${COLD_CONTAINER:-archive-cold}"

COST_RATE_PAGE_GB="${COST_RATE_PAGE_GB:-0.045}"
COST_RATE_ARCHIVE_GB="${COST_RATE_ARCHIVE_GB:-0.00099}"

# Cross-platform ISO-UTC helper (works on macOS and Linux)
iso_utc_in() { # hours
  local hrs="${1:-72}"
  python3 - "$hrs" <<'PY'
import sys, datetime
hrs = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
print((now + datetime.timedelta(hours=hrs)).strftime("%Y-%m-%dT%H:%MZ"))
PY
}

# Subscriptions summary
echo "[*] VM subscription:       ${VM_SUBSCRIPTION_ID:-<unset>}"
echo "[*] Storage subscription:  ${STORAGE_SUBSCRIPTION_ID:-<unset>}"
echo "[*] VM RG:                 $VM_RESOURCE_GROUP"
echo "[*] Storage RG:            $STORAGE_RESOURCE_GROUP"
echo "[*] Storage Account:       $STORAGE_ACCOUNT"
echo "[*] Containers:            page=$CONTAINER  cold=$COLD_CONTAINER (enabled=$ENABLE_COLD_ARCHIVE)"
echo "[*] Ticket:                $BBB_TICKET"
echo "[*] STOP_VM_FOR_SNAPSHOT=$STOP_VM_FOR_SNAPSHOT | DELETE_SNAPSHOTS_AFTER_COPY=$DELETE_SNAPSHOTS_AFTER_COPY | KEEP_SNAPSHOTS=$KEEP_SNAPSHOTS | DRY_RUN=$DRY_RUN"

# Remember original subscription to restore later
ORIG_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")

switch_sub() {
  local sub="$1"
  [[ -z "$sub" ]] && return 0
  az account set --subscription "$sub"
}

# ---------- STORAGE MANAGEMENT PLANE ----------
switch_sub "$STORAGE_SUBSCRIPTION_ID"
# --- Ensure RG and Storage Account exist ---
switch_sub "$STORAGE_SUBSCRIPTION_ID"

# Create resource group if missing
if ! az group show --name "$STORAGE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "[*] Creating storage resource group $STORAGE_RESOURCE_GROUP ..."
  az group create --name "$STORAGE_RESOURCE_GROUP" --location eastus2   # or your preferred region
fi

# Create storage account if missing
if ! az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  echo "[*] Creating storage account $STORAGE_ACCOUNT ..."
  az storage account create \
     --name "$STORAGE_ACCOUNT" \
     --resource-group "$STORAGE_RESOURCE_GROUP" \
     --sku Standard_LRS \
     --kind StorageV2 \
     --access-tier Hot
fi
# Resolve storage account & posture
SA_JSON="$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -o json)"
SA_ID="$(echo "$SA_JSON" | jq -r .id)"
if [[ -z "${SA_ID:-}" || "$SA_ID" == "null" ]]; then
  echo "FATAL: Storage account $STORAGE_ACCOUNT not found in $STORAGE_RESOURCE_GROUP"; exit 1
fi
PUB_ACCESS="$(echo "$SA_JSON" | jq -r '.publicNetworkAccess // "Enabled"')"
DEF_ACTION="$(echo "$SA_JSON" | jq -r '.networkRuleSet.defaultAction // "Allow"')"
echo "[*] Storage publicNetworkAccess=$PUB_ACCESS, defaultAction=$DEF_ACTION"

if [[ "${DRY_RUN,,}" != "true" ]]; then
  if [[ "$PUB_ACCESS" != "Enabled" || "$DEF_ACTION" != "Allow" ]]; then
    echo
    echo ">>> STORAGE ACCESS IS RESTRICTED (this will block uploads)."
    echo "    publicNetworkAccess: $PUB_ACCESS   defaultAction: $DEF_ACTION"
    read -r -p "Temporarily set to publicNetworkAccess=Enabled and defaultAction=Allow for this run? [y/N] " ANS
    if [[ "${ANS,,}" == "y" || "${ANS,,}" == "yes" ]]; then
      az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --public-network-access Enabled
      az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --default-action Allow --bypass AzureServices
      echo "INFO: Storage firewall temporarily opened."
    else
      echo "FATAL: Storage remains locked down; uploads will fail. Aborting."
      exit 1
    fi
  fi
fi

# Ensure containers (AAD control plane) — skipped only if DRY_RUN
if [[ "${DRY_RUN,,}" != "true" ]]; then
  az storage container create --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" --auth-mode login || true
  if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
    az storage container create --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" --auth-mode login || true
  fi
fi

DEST_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
COLD_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONTAINER}"
END_TIME="$(iso_utc_in "${DEST_SAS_HOURS}")"

# Data-plane RBAC hint (for AAD SAS)
ME_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")"
HAS_DATA_ROLE=0
if [[ -n "$ME_OID" ]]; then
  HAS_DATA_ROLE="$(az role assignment list --assignee-object-id "$ME_OID" --scope "$SA_ID" \
    --query "[?contains(roleDefinitionName, 'Storage Blob Data')].roleDefinitionName | length(@)" -o tsv 2>/dev/null || echo 0)"
fi
if [[ "${HAS_DATA_ROLE:-0}" -eq 0 && "${DRY_RUN,,}" != "true" ]]; then
  echo "WARN: No 'Storage Blob Data *' RBAC; user-delegation SAS may fail. Will try account key fallback."
fi

# Mint SAS for page container (skip if DRY_RUN)
DEST_SAS=""
COLD_SAS=""
if [[ "${DRY_RUN,,}" != "true" ]]; then
  DEST_SAS="$(az storage container generate-sas \
    --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" \
    --expiry "$END_TIME" --permissions racwdl \
    --auth-mode login --as-user -o tsv 2>/dev/null || true)"
  if [[ -z "${DEST_SAS:-}" ]]; then
    SA_KEY="$(az storage account keys list -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query [0].value -o tsv)"
    DEST_SAS="$(az storage container generate-sas \
      --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" \
      --expiry "$END_TIME" --permissions racwdl \
      --account-key "$SA_KEY" -o tsv)"
  fi

  if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
    COLD_SAS="$(az storage container generate-sas \
      --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" \
      --expiry "$END_TIME" --permissions racwdl \
      --auth-mode login --as-user -o tsv 2>/dev/null || true)"
    if [[ -z "${COLD_SAS:-}" ]]; then
      SA_KEY="$(az storage account keys list -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query [0].value -o tsv)"
      COLD_SAS="$(az storage container generate-sas \
        --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" \
        --expiry "$END_TIME" --permissions racwdl \
        --account-key "$SA_KEY" -o tsv)"
    fi
  fi

  # Preflight write test (quick-fail)
  echo "[*] Preflight: testing AzCopy write to the container..."
  echo "ok" > /tmp/.preflight.txt
  azcopy copy "/tmp/.preflight.txt" "${DEST_BASE}/_preflight/.write.txt?${DEST_SAS}" --overwrite=true
else
  echo "[*] DRY RUN: skipping container SAS and preflight upload."
fi

# Helpers
# Build a valid snapshot name (<=80 chars), using vm + diskShort + ts and a short hash
safe_snap_name() {
  local vm="$1" disk_short="$2" ts="$3" disk_id="$4"

  # Allowed: letters, numbers, hyphen, underscore (Azure is permissive with -/_)
  local base="${vm}-${disk_short}"
  base="$(printf "%s" "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-{2,}/-/g; s/^[-_]+|[-_]+$//g')"

  # Tiny hash from disk id to keep uniqueness even after truncation
  local h; h="$(printf "%s" "$disk_id" | shasum -a 256 | cut -c1-6)"

  # Compose final with timestamp and hash: <base>-<ts>-<h>
  local final="${base}-${ts}-${h}"

  # Truncate to 80 chars max
  if (( ${#final} > 80 )); then
    # leave room for "-<ts>-<h>" (len = 1 + len(ts) + 1 + 6)
    local tail_len=$((1 + ${#ts} + 1 + 6))
    local keep_len=$((80 - tail_len))
    base="${base:0:$keep_len}"
    final="${base}-${ts}-${h}"
  fi
  printf "%s" "$final"
}

upload_file() {
  local local_path="$1" blob_rel="$2" sas="$3" base="$4"
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "DRY-RUN: would upload ${blob_rel}"
    return 0
  fi
  local dest_url="${base}/${blob_rel}?${sas}"
  azcopy copy "$local_path" "$dest_url" --overwrite=true
}
show_blob() {
  local name="$1" cont="$2"
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "DRY-RUN: would show blob ${cont}/${name}"
    return 0
  fi
  az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$cont" \
    --name "$name" --auth-mode login \
    --query "{blobType:properties.blobType, size:properties.contentLength}"
}
create_snapshot_with_retry() {
  local disk_id="$1" snap_name="$2" rg="$3"
  local sid=""

  # Attempt 1: capture ONLY stdout (ID), drop stderr
  sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
        --tags "bbb-ticket=$BBB_TICKET" "source=disk" \
        --query id -o tsv 2>/dev/null || true)"

  # Validate the ID format
  if [[ ! "$sid" =~ ^/subscriptions/.*/providers/Microsoft\.Compute/snapshots/.*$ ]]; then
    echo "WARN: snapshot create did not return an ID for $snap_name (attempt 1)" >&2
    # Attempt 2: still capture only stdout; let az print errors to the terminal
    sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
          --tags "bbb-ticket=$BBB_TICKET" "source=disk" \
          --query id -o tsv 2>/dev/null || true)"
  fi

  # Final check; if still bad, show one verbose call (to stderr) and give up
  if [[ ! "$sid" =~ ^/subscriptions/.*/providers/Microsoft\.Compute/snapshots/.*$ ]]; then
    echo "ERROR: snapshot create failed for $snap_name — verbose output follows:" >&2
    az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
      --tags "bbb-ticket=$BBB_TICKET" "source=disk" -o json 1>/dev/null
    sid=""
  else
    # Quiet verify without polluting stdout
    az snapshot show --ids "$sid" --query "{name:name,time:timeCreated}" -o tsv >/dev/null 2>&1 || true
  fi

  printf "%s" "$sid"
}

TS=$(date -u +"%Y%m%dT%H%M%SZ")
START=$SECONDS
TOTAL_PAGE_BYTES=0
TOTAL_ARCHIVE_BYTES=0
RUN_META_DIR="_runs/${TS}"
upload_file <(printf '{"runStartedUtc":"%s","ticket":"%s","dryRun":%s}' "$TS" "$BBB_TICKET" "${DRY_RUN,,}") "${RUN_META_DIR}/run-start.json" "${DEST_SAS:-}" "$DEST_BASE" || true

# ---------- VM MANAGEMENT PLANE ----------
switch_sub "$VM_SUBSCRIPTION_ID"

echo "[*] Enumerating VMs in $VM_RESOURCE_GROUP ..."
mapfile -t ALL_VMS < <(az vm list -g "$VM_RESOURCE_GROUP" --query "[].name" -o tsv)
if [[ -n "${VM_FILTER:-}" ]]; then
  VM_LIST=()
  for v in "${ALL_VMS[@]}"; do for f in $VM_FILTER; do [[ "$v" == "$f" ]] && VM_LIST+=("$v"); done; done
else
  VM_LIST=("${ALL_VMS[@]}")
fi
[[ ${#VM_LIST[@]} -gt 0 ]] || { echo "FATAL: No VMs found in $VM_RESOURCE_GROUP"; exit 1; }

for VM in "${VM_LIST[@]}"; do
  echo -e "\n=== VM: $VM =========================================="
  switch_sub "$VM_SUBSCRIPTION_ID"   # <--- ADD THIS
  DEST_PREFIX="${VM}/${TS}"

  if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
    echo "[*] Deallocating $VM ..."
    az vm deallocate -g "$VM_RESOURCE_GROUP" -n "$VM" --no-wait || true
    az vm wait -g "$VM_RESOURCE_GROUP" -n "$VM" --deallocated || true
  fi

  echo "[1/9] VM JSON ..."
  VM_JSON="$(az vm show -g "$VM_RESOURCE_GROUP" -n "$VM")"

  echo "[2/9] IP & NIC info ..."
  IP_JSON="$(az vm list-ip-addresses -g "$VM_RESOURCE_GROUP" -n "$VM" -o json)"
  NIC_IDS="$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id')"

  echo "[3/9] Disks ..."
  DISK_IDS="$(echo "$VM_JSON" | jq -r \
    '[.storageProfile.osDisk.managedDisk.id] + ([.storageProfile.dataDisks[].managedDisk.id] // []) | .[]')"
  [[ -n "${DISK_IDS:-}" ]] || { echo "FATAL: No disks found; aborting."; exit 1; }

  TMPDIR="$(mktemp -d)"
  {
    echo "vmName: $VM"
    echo "timestamp: $TS"
    echo "ticket: $BBB_TICKET"
    echo "disks:"
    for DID in $DISK_IDS; do echo "  - $(basename "$DID") ($DID)"; done
  } > "${TMPDIR}/manifest.yaml"
  printf "%s" "$VM_JSON" > "${TMPDIR}/vm.json"
  printf "%s" "$IP_JSON" > "${TMPDIR}/ip.json"
  printf "%s" "$NIC_IDS" > "${TMPDIR}/nics.txt"

  echo "[4/9] Upload metadata ..."
  switch_sub "$STORAGE_SUBSCRIPTION_ID"
  upload_file "${TMPDIR}/manifest.yaml" "${DEST_PREFIX}/_meta/manifest.yaml" "${DEST_SAS:-}" "$DEST_BASE"
  upload_file "${TMPDIR}/vm.json"       "${DEST_PREFIX}/_meta/vm.json"       "${DEST_SAS:-}" "$DEST_BASE"
  upload_file "${TMPDIR}/ip.json"       "${DEST_PREFIX}/_meta/ip.json"       "${DEST_SAS:-}" "$DEST_BASE"
  upload_file "${TMPDIR}/nics.txt"      "${DEST_PREFIX}/_meta/nics.txt"      "${DEST_SAS:-}" "$DEST_BASE"
  show_blob "${DEST_PREFIX}/_meta/manifest.yaml" "$CONTAINER" >/dev/null || true

  # Upload restore steps reference (skipped in DRY_RUN)
 # ----- Build a concrete restore guide for THIS VM -----
# Gather details we already have for this VM
switch_sub "$VM_SUBSCRIPTION_ID"
OS_TYPE="$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType // empty')"
VM_SIZE="$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize // empty')"
OS_DISK_ID="$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id')"
OS_SHORT="$(basename "$OS_DISK_ID")"

# Build arrays for data disks: LUN -> short name
mapfile -t DATA_LUNS < <(echo "$VM_JSON" | jq -r '[.storageProfile.dataDisks[]? | .lun] | .[]')
mapfile -t DATA_IDS  < <(echo "$VM_JSON" | jq -r '[.storageProfile.dataDisks[]? | .managedDisk.id] | .[]')
DATA_SHORTS=()
for DIDX in "${!DATA_IDS[@]}"; do
  DATA_SHORTS+=("$(basename "${DATA_IDS[$DIDX]}")")
done

# Destinations (exact)
PAGE_CONT="${CONTAINER}"
PAGE_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${PAGE_CONT}"
COLD_CONT="${COLD_CONTAINER}"
COLD_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONT}"

# Compose per-disk page-blob paths (what our copy creates)
OS_VHD_PATH="${VM}/${TS}/${OS_SHORT}.vhd"
DATA_VHD_PATHS=()
for s in "${DATA_SHORTS[@]}"; do DATA_VHD_PATHS+=("${VM}/${TS}/${s}.vhd"); done

# Choose OS type text for az (fallback if unknown)
if [[ -z "${OS_TYPE:-}" ]]; then
  OS_TYPE_PLACEHOLDER="<Linux|Windows>"
else
  # normalize to Linux|Windows
  case "${OS_TYPE^^}" in
    WINDOWS) OS_TYPE="Windows" ;;
    LINUX)   OS_TYPE="Linux" ;;
    *)       OS_TYPE="<Linux|Windows>" ;;
  esac
fi

# Create restore_steps.txt with concrete commands and exact paths
{
  echo "RESTORE GUIDE for VM: ${VM}   (ticket ${BBB_TICKET})"
  echo "Timestamp: ${TS}"
  echo
  echo "Region note:"
  echo "  - Create managed disks in the SAME region as the storage account (${STORAGE_RESOURCE_GROUP}/${STORAGE_ACCOUNT})."
  echo
  echo "Detected from archive:"
  echo "  VM size: ${VM_SIZE:-<choose-size>}"
  echo "  OS type: ${OS_TYPE}"
  echo
  echo "Prereqs (one-time in your terminal):"
  echo "  az login"
  echo "  az account set --subscription ${STORAGE_SUBSCRIPTION_ID}"
  echo
  echo "Generate a short-lived SAS (12h) for each VHD as you go; example function:"
  echo "END=\$(python3 - <<'PY'; import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=12)).strftime('%Y-%m-%dT%H:%MZ')); PY)"
  echo "sas() { az storage blob generate-sas --account-name ${STORAGE_ACCOUNT} --container-name ${PAGE_CONT} --name \"\$1\" --permissions r --expiry \"\$END\" --auth-mode login -o tsv; }"
  echo
  echo "A) Create OS disk from the archived VHD"
  echo "   OS VHD:"
  echo "     ${PAGE_BASE}/${OS_VHD_PATH}"
  echo "   Commands:"
  echo "     OS_SAS=\$(sas \"${OS_VHD_PATH}\")"
  echo "     OS_DISK_ID=\$(az disk create -g ${VM_RESOURCE_GROUP} -n restored-osdisk-${VM}-${TS} \\"
  echo "        --source \"${PAGE_BASE}/${OS_VHD_PATH}?\${OS_SAS}\" --query id -o tsv)"
  echo
  echo "B) Create the VM from that OS disk"
  echo "   az vm create -g ${VM_RESOURCE_GROUP} -n restored-${VM}-${TS} \\"
  echo "       --attach-os-disk \"\${OS_DISK_ID}\" --os-type ${OS_TYPE} --size ${VM_SIZE:-<choose-size>}"
  echo
  if ((${#DATA_VHD_PATHS[@]})); then
    echo "C) Create data disks and attach with original LUNs"
    for i in "${!DATA_VHD_PATHS[@]}"; do
      dp="${DATA_VHD_PATHS[$i]}"
      lun="${DATA_LUNS[$i]}"
      short="${DATA_SHORTS[$i]}"
      echo "   # Data disk (LUN ${lun})"
      echo "   DD${i}_SAS=\$(sas \"${dp}\")"
      echo "   DD${i}_ID=\$(az disk create -g ${VM_RESOURCE_GROUP} -n restored-data-${VM}-${short}-${TS} \\"
      echo "       --source \"${PAGE_BASE}/${dp}?\${DD${i}_SAS}\" --query id -o tsv)"
      echo "   az vm disk attach -g ${VM_RESOURCE_GROUP} --vm-name restored-${VM}-${TS} --disk \"\${DD${i}_ID}\" --lun ${lun}"
      echo
    done
  else
    echo "C) No data disks detected for this VM."
    echo
  fi
  echo "D) Networking"
  echo "   - Recreate/attach NIC(s) as needed (see ${PAGE_BASE}/${VM}/${TS}/_meta/ip.json and nics.txt)."
  echo "   - Apply any tags or diagnostics from _meta/vm.json."
  echo
  if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
    echo "E) If using Cold Archive copies instead of page blobs"
    echo "   For each VHD below, rehydrate the block blob in the cold container, copy into a page blob, then proceed with steps A–C."
    echo
    echo "   Cold blobs (Archive tier):"
    echo "   OS:   ${COLD_BASE}/${OS_VHD_PATH}"
    for dp in "${DATA_VHD_PATHS[@]}"; do
      echo "   DATA: ${COLD_BASE}/${dp}"
    done
    echo
    echo "   Example rehydrate+convert for OS VHD:"
    echo "     # 1) Rehydrate to Cool"
    echo "     az storage blob set-tier --account-name ${STORAGE_ACCOUNT} -c ${COLD_CONT} -n \"${OS_VHD_PATH}\" --tier Cool --rehydrate-priority High --auth-mode login"
    echo "     # Wait until archiveStatus clears"
    echo "     # 2) Create empty page blob in ${PAGE_CONT} with same size"
    echo "     SIZE=\$(az storage blob show --account-name ${STORAGE_ACCOUNT} -c ${COLD_CONT} -n \"${OS_VHD_PATH}\" --auth-mode login --query properties.contentLength -o tsv)"
    echo "     az storage blob create --account-name ${STORAGE_ACCOUNT} -c ${PAGE_CONT} -n \"${OS_VHD_PATH}\" --type page --content-length \"\$SIZE\" --auth-mode login"
    echo "     # 3) Server-side copy into the page blob"
    echo "     COLD_SAS=\$(az storage blob generate-sas --account-name ${STORAGE_ACCOUNT} -c ${COLD_CONT} -n \"${OS_VHD_PATH}\" --permissions r --expiry \"\$END\" --auth-mode login -o tsv)"
    echo "     az storage blob copy start --account-name ${STORAGE_ACCOUNT} --destination-container ${PAGE_CONT} --destination-blob \"${OS_VHD_PATH}\" \\"
    echo "        --source-uri \"${COLD_BASE}/${OS_VHD_PATH}?\${COLD_SAS}\" --auth-mode login"
    echo "     # Then continue with step A using ${PAGE_BASE}/${OS_VHD_PATH}"
    echo
  fi
  echo "Verification tips:"
  echo "  - VHD page blob should report blobType=PageBlob and a non-zero size."
  echo "  - Managed disks should show provisioningState=Succeeded before creating the VM."
  echo
  echo "Cleanup (snapshots were tagged bbb-ticket=${BBB_TICKET}):"
  echo "  az snapshot list --query \"[?tags.'bbb-ticket'=='${BBB_TICKET}'].id\" -o tsv | xargs -n1 az snapshot delete --ids"
} > "${TMPDIR}/restore_steps.txt"

# Upload (or DRY-RUN print) the file
switch_sub "$STORAGE_SUBSCRIPTION_ID"
upload_file "${TMPDIR}/restore_steps.txt" "${DEST_PREFIX}/_meta/restore_steps.txt" "${DEST_SAS:-}" "$DEST_BASE"
  echo "[5/9] Snapshots ..."
  switch_sub "$VM_SUBSCRIPTION_ID"
  SNAP_IDS=()
  SNAP_DISK_SHORT_NAMES=()   # NEW: keeps the basename for each snapshot
  for DID in $DISK_IDS; do
    DNAME="$(basename "$DID")"
    SNAME="$(safe_snap_name "$VM" "$DNAME" "$TS" "$DID")"
    echo "   -> $SNAME"
    SID="$(create_snapshot_with_retry "$DID" "$SNAME" "$VM_RESOURCE_GROUP")"
    if [[ -n "${SID:-}" ]]; then
      SNAP_IDS+=("$SID")
      SNAP_DISK_SHORT_NAMES+=("$DNAME")
    else
      echo "ERROR: Snapshot not created for $SNAME"
    fi
  done
  [[ ${#SNAP_IDS[@]} -gt 0 ]] || { echo "FATAL: no snapshots created; aborting."; exit 1; }

  if [[ "${DRY_RUN,,}" == "true" ]]; then
  echo "[6/9] DRY RUN: skipping VHD copy. Would have copied:"
    for i in "${!SNAP_IDS[@]}"; do
    SHORT="${SNAP_DISK_SHORT_NAMES[$i]}"
    DEST_VHD_NAME="${SHORT}.vhd"
    echo "      ${DEST_BASE}/${DEST_PREFIX}/${DEST_VHD_NAME}"
    done
    echo "[7/9] DRY RUN: skipping cold-archive copies."
  else
    echo "[6/9] Copy snapshots to VHD page blobs ..."
   echo "[6/9] Copy snapshots to VHD page blobs ..."
    COPIED_VHDS=()
    for i in "${!SNAP_IDS[@]}"; do
    SID="${SNAP_IDS[$i]}"
    SHORT="${SNAP_DISK_SHORT_NAMES[$i]}"
    DEST_VHD_NAME="${SHORT}.vhd"
    DEST_PATH="${DEST_PREFIX}/${DEST_VHD_NAME}"

    SRC_SAS_URL="$(az snapshot grant-access --ids "$SID" \
                    --duration-in-seconds $(( SRC_SAS_HOURS*3600 )) \
                    --access-level Read --query accessSAS -o tsv)"

    switch_sub "$STORAGE_SUBSCRIPTION_ID"
    echo "   -> Copy $DEST_VHD_NAME"
    azcopy copy "$SRC_SAS_URL" "${DEST_BASE}/${DEST_PATH}?${DEST_SAS}" --overwrite=true

    PROPS="$(show_blob "${DEST_PATH}" "$CONTAINER")"
    echo "      ${PROPS}"
    BYTES="$(az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$CONTAINER" \
            --name "${DEST_PATH}" --auth-mode login --query "properties.contentLength" -o tsv)"
    TOTAL_PAGE_BYTES=$((TOTAL_PAGE_BYTES + BYTES))
    COPIED_VHDS+=("${DEST_PATH}")
    done

    if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
      echo "[7/9] Cold archive copies (Block Blob -> Archive tier) ..."
      for PATH in "${COPIED_VHDS[@]}"; do
        COLD_PATH="${PATH}"
        echo "   -> Cold copy $(basename "$PATH")"
        azcopy copy "${DEST_BASE}/${PATH}?${DEST_SAS}" "${COLD_BASE}/${COLD_PATH}?${COLD_SAS}" --overwrite=true
        az storage blob set-tier --account-name "$STORAGE_ACCOUNT" --container-name "$COLD_CONTAINER" \
          --name "$COLD_PATH" --tier Archive --auth-mode login
        C_BYTES="$(az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$COLD_CONTAINER" \
                   --name "$COLD_PATH" --auth-mode login --query "properties.contentLength" -o tsv)"
        TOTAL_ARCHIVE_BYTES=$((TOTAL_ARCHIVE_BYTES + C_BYTES))
      done
    else
      echo "[7/9] Cold archive disabled"
    fi
  fi

  echo "[8/9] README ..."
  cat > "${TMPDIR}/README.txt" <<'TXT'
/****************************************************
Archived VM materials for later restore.
- VHDs are page blobs (OS+data). Page blobs do NOT support Cool/Archive tiers.
- Metadata JSON covers size, NICs, IPs, tags, plan, etc.
- Restore: see _meta/restore_steps.txt for step-by-step.
****************************************************/
TXT
  switch_sub "$STORAGE_SUBSCRIPTION_ID"
  upload_file "${TMPDIR}/README.txt" "${DEST_PREFIX}/_meta/README.txt" "${DEST_SAS:-}" "$DEST_BASE"

  if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Starting VM $VM ..."
    az vm start -g "$VM_RESOURCE_GROUP" -n "$VM" || echo "WARN: start failed"
  fi

  # Snapshot cleanup
  if [[ "${DELETE_SNAPSHOTS_AFTER_COPY,,}" == "true" && "${DRY_RUN,,}" != "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Deleting snapshots for $VM ..."
    for SID in "${SNAP_IDS[@]}"; do
      az snapshot delete --ids "$SID" || echo "WARN: snapshot delete failed for $SID"
    done
  else
    echo "INFO: Keeping snapshots for $VM (DELETE_SNAPSHOTS_AFTER_COPY=false or DRY_RUN=true)."
  fi

  rm -rf "$TMPDIR"
  echo "=== DONE: $VM → ${DEST_BASE}/${DEST_PREFIX}"
done

DUR=$((SECONDS-START))

# ---------- COST ESTIMATE ----------
if [[ "${DRY_RUN,,}" != "true" ]]; then
  GB=$((1024*1024*1024))
  PAGE_GB=$(python3 - <<PY
print(round(${TOTAL_PAGE_BYTES}/$GB, 2))
PY
)
  ARCH_GB=$(python3 - <<PY
print(round(${TOTAL_ARCHIVE_BYTES}/$GB, 2))
PY
)
  EST_PAGE_COST=$(python3 - <<PY
print(round(${TOTAL_PAGE_BYTES}/$GB * ${COST_RATE_PAGE_GB}, 2))
PY
)
  EST_ARCH_COST=$(python3 - <<PY
print(round(${TOTAL_ARCHIVE_BYTES}/$GB * ${COST_RATE_ARCHIVE_GB}, 2))
PY
)
  EST_TOTAL=$(python3 - <<PY
print(round(${TOTAL_PAGE_BYTES}/$GB * ${COST_RATE_PAGE_GB} + ${TOTAL_ARCHIVE_BYTES}/$GB * ${COST_RATE_ARCHIVE_GB}, 2))
PY
)

  echo
  echo "===== Rough Monthly Storage Estimate ====="
  echo "Page blobs (VHDs):  ${PAGE_GB} GB  @ \$${COST_RATE_PAGE_GB}/GB-mo  ≈ \$${EST_PAGE_COST}/mo"
  if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
    echo "Archive blobs:      ${ARCH_GB} GB  @ \$${COST_RATE_ARCHIVE_GB}/GB-mo  ≈ \$${EST_ARCH_COST}/mo"
  fi
  echo "-----------------------------------------"
  echo "Estimated total:    \$${EST_TOTAL}/mo (capacity only)"
  echo "NOTE: Approximate; excludes transactions/rehydration and regional price diffs."

  SUMMARY_JSON=$(cat <<J
{
  "ticket": "${BBB_TICKET}",
  "run": "${TS}",
  "vmSubscription": "${VM_SUBSCRIPTION_ID}",
  "storageSubscription": "${STORAGE_SUBSCRIPTION_ID}",
  "vmResourceGroup": "${VM_RESOURCE_GROUP}",
  "storageAccount": "${STORAGE_ACCOUNT}",
  "containers": {"page":"${CONTAINER}"$([[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]] && printf ', "cold":"%s"' "$COLD_CONTAINER")},
  "bytes": { "page": ${TOTAL_PAGE_BYTES}, "archive": ${TOTAL_ARCHIVE_BYTES} },
  "gb":    { "page": ${PAGE_GB}, "archive": ${ARCH_GB} },
  "rates": { "pageUSDPerGBMonth": ${COST_RATE_PAGE_GB}, "archiveUSDPerGBMonth": ${COST_RATE_ARCHIVE_GB} },
  "estimateUSDPerMonth": { "page": ${EST_PAGE_COST}, "archive": ${EST_ARCH_COST}, "total": ${EST_TOTAL} },
  "completedSeconds": ${DUR},
  "notes": "Capacity-only estimate."
}
J
)
  echo "$SUMMARY_JSON" | jq .
  switch_sub "$STORAGE_SUBSCRIPTION_ID"
  upload_file <(printf "%s" "$SUMMARY_JSON") "_runs/${TS}/cost-summary.json" "${DEST_SAS:-}" "$DEST_BASE" || true
else
  echo
  echo "===== DRY RUN COMPLETE ====="
  echo "Snapshots were created; no uploads or VHD copies were performed."
fi

# ---------- SECURITY VALIDATION ----------
echo
echo "===== Storage Account Security Validation ====="
PUB_ACCESS_NOW=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query publicNetworkAccess -o tsv)
DEF_ACTION_NOW=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query networkRuleSet.defaultAction -o tsv)
HTTPS_ONLY=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query enableHttpsTrafficOnly -o tsv)
TLS_MIN=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query minimumTlsVersion -o tsv)
SHARED_KEY=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query allowSharedKeyAccess -o tsv 2>/dev/null || echo "unknown")
BLOB_VERSION=$(az storage account blob-service-properties show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query isVersioningEnabled -o tsv 2>/dev/null || echo "unknown")
SOFT_DELETE=$(az storage account blob-service-properties show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query deleteRetentionPolicy.enabled -o tsv 2>/dev/null || echo "unknown")

echo "publicNetworkAccess: $PUB_ACCESS_NOW"
echo "defaultAction:       $DEF_ACTION_NOW"
echo "httpsOnly:           $HTTPS_ONLY"
echo "minTLS:              $TLS_MIN"
echo "allowSharedKeyAccess:$SHARED_KEY"
echo "blobVersioning:      $BLOB_VERSION"
echo "softDelete:          $SOFT_DELETE"
if [[ "$PUB_ACCESS_NOW" != "Disabled" && "$DEF_ACTION_NOW" != "Deny" ]]; then
  echo "WARN: Public access is still open (Enabled/Allow). Consider Deny and/or Private Endpoints."
fi
if [[ "$HTTPS_ONLY" != "true" || "$TLS_MIN" != "TLS1_2" ]]; then
  echo "WARN: Enforce HTTPS-only and TLS1_2 minimum."
fi
if [[ "$BLOB_VERSION" != "true" || "$SOFT_DELETE" != "true" ]]; then
  echo "INFO: Consider enabling versioning + soft-delete for safety nets."
fi
echo "=============================================="

# Final prompt to re-secure firewall (skip in DRY RUN if nothing was opened)
if [[ "${DRY_RUN,,}" != "true" ]]; then
  echo
  read -r -p "Re-secure storage (set defaultAction=Deny again)? [Y/n] " RES
  if [[ -z "${RES:-}" || "${RES,,}" == "y" || "${RES,,}" == "yes" ]]; then
    az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" \
      --default-action Deny --bypass AzureServices
    echo "INFO: Storage firewall set to Deny."
  else
    echo "INFO: Leaving storage firewall as-is (Allow)."
  fi
fi

# Restore original subscription (if any)
[[ -n "$ORIG_SUB" ]] && az account set --subscription "$ORIG_SUB" || true

