#!/usr/bin/env bash
set -euo pipefail

#==================== CONFIG (read from ./config.txt if present) ====================
CFG="./config.txt"
[[ -f "$CFG" ]] && source "$CFG" || true

# IDs & Resources
VM_SUBSCRIPTION_ID="${VM_SUBSCRIPTION_ID:-5a8f2111-71ad-42fb-a6e1-58d3676ca6ad}"
STORAGE_SUBSCRIPTION_ID="${STORAGE_SUBSCRIPTION_ID:-74fe5f2d-c8d1-487c-9c9d-78a2a2fe77cd}"
VM_RESOURCE_GROUP="${VM_RESOURCE_GROUP:-rg-Spirits}"
STORAGE_RESOURCE_GROUP="${STORAGE_RESOURCE_GROUP:-rg-Spirits-1022621}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-storspirits1022621}"
CONTAINER="${CONTAINER:-archive}"
BBB_TICKET="${BBB_TICKET:-1022621}"

# Modes / Options
VM_FILTER="${VM_FILTER:-}"                       # e.g. "az-spirits az-spirits2"
STOP_VM_FOR_SNAPSHOT="${STOP_VM_FOR_SNAPSHOT:-false}"
DELETE_SNAPSHOTS_AFTER_COPY="${DELETE_SNAPSHOTS_AFTER_COPY:-true}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Cold archive
ENABLE_COLD_ARCHIVE="${ENABLE_COLD_ARCHIVE:-false}"
COLD_CONTAINER="${COLD_CONTAINER:-archive-cold}"
COLD_ONLY="${COLD_ONLY:-false}"                  # true = copy existing page blobs to cold only
COLD_SOURCE_PREFIX="${COLD_SOURCE_PREFIX:-}"     # e.g. "az-spirits/20250916T122914Z/"

# SAS durations (hours)
DEST_SAS_HOURS="${DEST_SAS_HOURS:-72}"
SRC_SAS_HOURS="${SRC_SAS_HOURS:-24}"

# Cost rates ($/GB-month)
COST_RATE_PAGE_GB="${COST_RATE_PAGE_GB:-0.045}"
COST_RATE_ARCHIVE_GB="${COST_RATE_ARCHIVE_GB:-0.00099}"

# Honor KEEP_SNAPSHOTS and DRY_RUN
if [[ "${KEEP_SNAPSHOTS,,}" == "true" ]]; then DELETE_SNAPSHOTS_AFTER_COPY=false; fi
if [[ "${DRY_RUN,,}" == "true" ]]; then DELETE_SNAPSHOTS_AFTER_COPY=false; fi

#==================== Helpers ====================
iso_utc_in() {  # UTC now + N hours, portable for macOS
  local hrs="${1:-72}"
  python3 - "$hrs" <<'PY'
import sys, datetime
hrs=int(sys.argv[1])
now=datetime.datetime.now(datetime.timezone.utc)
print((now+datetime.timedelta(hours=hrs)).strftime("%Y-%m-%dT%H:%MZ"))
PY
}

switch_sub() {
  local sub="$1"; [[ -z "${sub:-}" ]] && return 0
  az account set --subscription "$sub"
}

safe_snap_name() {  # <=80 chars, normalized + tiny hash for uniqueness
  local vm="$1" disk_short="$2" ts="$3" disk_id="$4"
  local base="${vm}-${disk_short}"
  base="$(printf "%s" "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-{2,}/-/g; s/^[-_]+|[-_]+$//g')"
  local h; h="$(printf "%s" "$disk_id" | shasum -a 256 | cut -c1-6)"
  local final="${base}-${ts}-${h}"
  if (( ${#final} > 80 )); then
    local tail_len=$((1 + ${#ts} + 1 + 6))
    local keep_len=$((80 - tail_len))
    base="${base:0:$keep_len}"
    final="${base}-${ts}-${h}"
  fi
  printf "%s" "$final"
}

create_snapshot_with_retry() {
  local disk_id="$1" snap_name="$2" rg="$3"
  local sid=""
  sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
        --tags "bbb-ticket=$BBB_TICKET" "source=disk" --query id -o tsv 2>/dev/null || true)"
  if [[ ! "$sid" =~ ^/subscriptions/.*/providers/Microsoft\.Compute/snapshots/.*$ ]]; then
    echo "WARN: snapshot create did not return an ID for $snap_name" >&2
    sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
          --tags "bbb-ticket=$BBB_TICKET" "source=disk" --query id -o tsv 2>/dev/null || true)"
  fi
  if [[ ! "$sid" =~ ^/subscriptions/.*/providers/Microsoft\.Compute/snapshots/.*$ ]]; then
    echo "ERROR: snapshot create failed for $snap_name" >&2
    sid=""
  else
    az snapshot show --ids "$sid" --query "{name:name,time:timeCreated}" -o tsv >/dev/null 2>&1 || true
  fi
  printf "%s" "$sid"
}

upload_file() {  # AzCopy + SAS (skip in DRY_RUN)
  local local_path="$1" blob_rel="$2" sas="$3" base="$4"
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "DRY-RUN: would upload ${blob_rel}"
    return 0
  fi
  azcopy copy "$local_path" "${base}/${blob_rel}?${sas}" --overwrite=true
}

show_blob() {     # AAD view
  local name="$1" cont="$2"
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "DRY-RUN: would show blob ${cont}/${name}"
    return 0
  fi
  az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$cont" \
    --name "$name" --auth-mode login \
    --query "{blobType:properties.blobType,size:properties.contentLength}"
}

#==================== Banner ====================
echo "[*] VM subscription:       ${VM_SUBSCRIPTION_ID}"
echo "[*] Storage subscription:  ${STORAGE_SUBSCRIPTION_ID}"
echo "[*] VM RG:                 ${VM_RESOURCE_GROUP}"
echo "[*] Storage RG:            ${STORAGE_RESOURCE_GROUP}"
echo "[*] Storage Account:       ${STORAGE_ACCOUNT}"
echo "[*] Containers:            page=${CONTAINER}  cold=${COLD_CONTAINER} (enabled=${ENABLE_COLD_ARCHIVE})"
echo "[*] Ticket:                ${BBB_TICKET}"
echo "[*] STOP_VM_FOR_SNAPSHOT=${STOP_VM_FOR_SNAPSHOT} | DELETE_SNAPSHOTS_AFTER_COPY=${DELETE_SNAPSHOTS_AFTER_COPY} | KEEP_SNAPSHOTS=${KEEP_SNAPSHOTS} | DRY_RUN=${DRY_RUN}"

ORIG_SUB="$(az account show --query id -o tsv 2>/dev/null || echo "")"

#==================== Ensure RG + Storage exist (even DRY_RUN) ====================
switch_sub "$STORAGE_SUBSCRIPTION_ID"

if ! az group show --name "$STORAGE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "[*] Creating storage resource group ${STORAGE_RESOURCE_GROUP} ..."
  az group create --name "$STORAGE_RESOURCE_GROUP" --location eastus2 >/dev/null
fi
if ! az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  echo "[*] Creating storage account ${STORAGE_ACCOUNT} ..."
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$STORAGE_RESOURCE_GROUP" \
    --sku Standard_LRS --kind StorageV2 --access-tier Hot >/dev/null
fi

# Posture
SA_JSON="$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -o json)"
PUB_ACCESS="$(echo "$SA_JSON" | jq -r '.publicNetworkAccess // "Enabled"')"
DEF_ACTION="$(echo "$SA_JSON" | jq -r '.networkRuleSet.defaultAction // "Allow"')"
echo "[*] Storage publicNetworkAccess=${PUB_ACCESS}, defaultAction=${DEF_ACTION}"

# Prompt to open firewall if uploads would be blocked
if [[ "${DRY_RUN,,}" != "true" && "$DEF_ACTION" != "Allow" ]]; then
  echo
  echo ">>> STORAGE ACCESS IS RESTRICTED (this will block uploads)."
  echo "    publicNetworkAccess: ${PUB_ACCESS}   defaultAction: ${DEF_ACTION}"
  read -r -p "Temporarily set to publicNetworkAccess=Enabled and defaultAction=Allow for this run? [y/N] " ANS
  if [[ "${ANS,,}" == "y" || "${ANS,,}" == "yes" ]]; then
    az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --public-network-access Enabled >/dev/null
    az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --default-action Allow --bypass AzureServices >/dev/null
    echo "INFO: Storage firewall temporarily opened."
  else
    echo "FATAL: Storage remains locked down; uploads will fail. Aborting."
    exit 1
  fi
fi

# Ensure containers
if [[ "${DRY_RUN,,}" != "true" ]]; then
  az storage container create --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" --auth-mode login >/dev/null || true
  if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
    az storage container create --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" --auth-mode login >/dev/null || true
  fi
fi

DEST_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
COLD_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONTAINER}"
END_TIME="$(iso_utc_in "${DEST_SAS_HOURS}")"

# Container SAS (AAD as-user, fallback to key)
DEST_SAS=""
if [[ "${DRY_RUN,,}" != "true" ]]; then
  DEST_SAS="$(az storage container generate-sas \
    --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" \
    --expiry "$END_TIME" --permissions racwdl \
    --auth-mode login --as-user -o tsv 2>/dev/null || true)"
  if [[ -z "${DEST_SAS:-}" ]]; then
    SA_KEY="$(az storage account keys list -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query [0].value -o tsv)"
    DEST_SAS="$(az storage container generate-sas \
      --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" \
      --expiry "$END_TIME" --permissions racwdl --account-key "$SA_KEY" -o tsv)"
  fi
fi

# Preflight write
if [[ "${DRY_RUN,,}" != "true" ]]; then
  echo "[*] Preflight: testing AzCopy write to the container..."
  echo "ok" > /tmp/.preflight.txt
  azcopy copy "/tmp/.preflight.txt" "${DEST_BASE}/_preflight/.write.txt?${DEST_SAS}" --overwrite=true
else
  echo "[*] DRY RUN: skipping container SAS and preflight upload."
fi

#==================== COLD_ONLY (copy page -> block Archive) ====================
if [[ "${COLD_ONLY,,}" == "true" ]]; then
  echo
  echo "[*] COLD_ONLY: copying existing VHDs from '${CONTAINER}/${COLD_SOURCE_PREFIX}' to '${COLD_CONTAINER}/' as BLOCK blobs (Archive tier)"
  az storage container create --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" --auth-mode login >/dev/null || true

  echo "[*] Enumerating source VHDs in '${CONTAINER}/${COLD_SOURCE_PREFIX}'..."
  mapfile -t SRC_VHDS < <(az storage blob list \
      --account-name "$STORAGE_ACCOUNT" \
      --container-name "$CONTAINER" \
      --prefix "${COLD_SOURCE_PREFIX}" \
      --auth-mode login \
      --query "[?ends_with(name, '.vhd')].name" -o tsv)

  if (( ${#SRC_VHDS[@]} == 0 )); then
    echo "FATAL: No .vhd blobs found under '${CONTAINER}/${COLD_SOURCE_PREFIX}'."
    exit 1
  fi

  TOTAL_ARCHIVE_BYTES=0
  for NAME in "${SRC_VHDS[@]}"; do
    echo "   -> Cold copy (block blob, Archive) ${NAME}"
    END_READ="$(iso_utc_in 24)"
    SRC_READ_SAS="$(az storage blob generate-sas \
        --account-name "$STORAGE_ACCOUNT" --container-name "$CONTAINER" --name "$NAME" \
        --permissions r --expiry "$END_READ" --auth-mode login --as-user -o tsv 2>/dev/null || true)"
    if [[ -z "${SRC_READ_SAS:-}" ]]; then
      SA_KEY="$(az storage account keys list -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query [0].value -o tsv)"
      SRC_READ_SAS="$(az storage blob generate-sas \
          --account-name "$STORAGE_ACCOUNT" --container-name "$CONTAINER" --name "$NAME" \
          --permissions r --expiry "$END_READ" --account-key "$SA_KEY" -o tsv)"
    fi

    az storage blob copy start \
      --account-name "$STORAGE_ACCOUNT" \
      --destination-container "$COLD_CONTAINER" \
      --destination-blob "$NAME" \
      --source-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${NAME}?${SRC_READ_SAS}" \
      --tier Archive --auth-mode login

    BYTES="$(az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$COLD_CONTAINER" \
             --name "$NAME" --auth-mode login --query "properties.contentLength" -o tsv || echo 0)"
    TOTAL_ARCHIVE_BYTES=$((TOTAL_ARCHIVE_BYTES + BYTES))
  done

  # Cost estimate (cold-only)
  GB=$((1024*1024*1024))
  ARCH_GB=$(python3 - <<PY
print(round(${TOTAL_ARCHIVE_BYTES}/$GB, 2))
PY
)
  EST_ARCH_COST=$(python3 - <<PY
print(round(${TOTAL_ARCHIVE_BYTES}/$GB * ${COST_RATE_ARCHIVE_GB}, 2))
PY
)
  TS_NOW=$(date -u +"%Y%m%dT%H%M%SZ")
  echo
  echo "===== Rough Monthly Storage Estimate (COLD ONLY) ====="
  echo "Archive blobs:      ${ARCH_GB} GB  @ \$${COST_RATE_ARCHIVE_GB}/GB-mo  ≈ \$${EST_ARCH_COST}/mo"
  echo "NOTE: Capacity only; excludes transactions/rehydration and regional variance."

  SUMMARY_JSON=$(cat <<J
{"mode":"COLD_ONLY","ticket":"${BBB_TICKET}","run":"${TS_NOW}",
"storageAccount":"${STORAGE_ACCOUNT}","containers":{"page":"${CONTAINER}","cold":"${COLD_CONTAINER}"},
"prefixFilter":"${COLD_SOURCE_PREFIX}","bytes":{"archive":${TOTAL_ARCHIVE_BYTES}},
"gb":{"archive":${ARCH_GB}},"rates":{"archiveUSDPerGBMonth":${COST_RATE_ARCHIVE_GB}},
"estimateUSDPerMonth":{"archive":${EST_ARCH_COST}}}
J
)
  echo "$SUMMARY_JSON" | jq .
  # Upload cost summary under page container to keep convention
  if [[ "${DRY_RUN,,}" != "true" ]]; then
    azcopy copy <(printf "%s" "$SUMMARY_JSON") \
      "${DEST_BASE}/_runs/${TS_NOW}/cost-summary.json?${DEST_SAS}" \
      --from-to=LocalBlob --overwrite=true
  fi
  echo
  echo "COLD_ONLY complete. Cold copies live under '${COLD_CONTAINER}/${COLD_SOURCE_PREFIX}'."
  exit 0
fi

#==================== NORMAL PATH ====================
TS=$(date -u +"%Y%m%dT%H%M%SZ")
START=$SECONDS
TOTAL_PAGE_BYTES=0
TOTAL_ARCHIVE_BYTES=0

# Minimal run marker
upload_file <(printf '{"runStartedUtc":"%s","ticket":"%s","dryRun":%s}' "$TS" "$BBB_TICKET" "${DRY_RUN,,}") \
  "_runs/${TS}/run-start.json" "${DEST_SAS:-}" "$DEST_BASE" || true

# Enumerate VMs
switch_sub "$VM_SUBSCRIPTION_ID"
echo "[*] Enumerating VMs in ${VM_RESOURCE_GROUP} ..."
mapfile -t ALL_VMS < <(az vm list -g "$VM_RESOURCE_GROUP" --query "[].name" -o tsv)
if [[ -n "${VM_FILTER:-}" ]]; then
  VM_LIST=()
  for v in "${ALL_VMS[@]}"; do for f in $VM_FILTER; do [[ "$v" == "$f" ]] && VM_LIST+=("$v"); done; done
else
  VM_LIST=("${ALL_VMS[@]}")
fi
[[ ${#VM_LIST[@]} -gt 0 ]] || { echo "FATAL: No VMs found in $VM_RESOURCE_GROUP"; exit 1; }

for VM in "${VM_LIST[@]}"; do
  echo -e "\n=== VM: ${VM} =========================================="
  switch_sub "$VM_SUBSCRIPTION_ID"
  DEST_PREFIX="${VM}/${TS}"

  # Optional stop/deallocate
  if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
    echo "[*] Deallocating ${VM} ..."
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
    echo "vmName: ${VM}"
    echo "timestamp: ${TS}"
    echo "ticket: ${BBB_TICKET}"
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

  # Restore guide (exact paths)
  switch_sub "$VM_SUBSCRIPTION_ID"
  OS_TYPE="$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType // empty')"
  VM_SIZE="$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize // empty')"
  OS_DISK_ID="$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id')"
  OS_SHORT="$(basename "$OS_DISK_ID")"
  mapfile -t DATA_LUNS  < <(echo "$VM_JSON" | jq -r '[.storageProfile.dataDisks[]? | .lun] | .[]')
  mapfile -t DATA_IDS   < <(echo "$VM_JSON" | jq -r '[.storageProfile.dataDisks[]? | .managedDisk.id] | .[]')
  DATA_SHORTS=(); for DIDX in "${!DATA_IDS[@]}"; do DATA_SHORTS+=("$(basename "${DATA_IDS[$DIDX]}")"); done

  PAGE_CONT="${CONTAINER}"; PAGE_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${PAGE_CONT}"
  COLD_CONT="${COLD_CONTAINER}"; COLD_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONT}"
  OS_VHD_PATH="${VM}/${TS}/${OS_SHORT}.vhd"
  DATA_VHD_PATHS=(); for s in "${DATA_SHORTS[@]}"; do DATA_VHD_PATHS+=("${VM}/${TS}/${s}.vhd"); done
  case "${OS_TYPE^^}" in WINDOWS) OS_TYPE="Windows" ;; LINUX) OS_TYPE="Linux" ;; *) OS_TYPE="<Linux|Windows>" ;; esac

  {
    echo "RESTORE GUIDE for VM: ${VM}   (ticket ${BBB_TICKET})"
    echo "Timestamp: ${TS}"
    echo
    echo "Prereqs:"
    echo "  az login"
    echo "  az account set --subscription ${STORAGE_SUBSCRIPTION_ID}"
    echo
    echo "Function to mint short SAS for a blob (12h):"
    echo "END=\$(python3 - <<'PY'; import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=12)).strftime('%Y-%m-%dT%H:%MZ')); PY)"
    echo "sas() { az storage blob generate-sas --account-name ${STORAGE_ACCOUNT} --container-name ${PAGE_CONT} --name \"\$1\" --permissions r --expiry \"\$END\" --auth-mode login -o tsv; }"
    echo
    echo "A) OS disk from VHD:"
    echo "   ${PAGE_BASE}/${OS_VHD_PATH}"
    echo "   OS_SAS=\$(sas \"${OS_VHD_PATH}\")"
    echo "   OS_DISK_ID=\$(az disk create -g ${VM_RESOURCE_GROUP} -n restored-osdisk-${VM}-${TS} --source \"${PAGE_BASE}/${OS_VHD_PATH}?\${OS_SAS}\" --query id -o tsv)"
    echo
    echo "B) Create VM from OS disk:"
    echo "   az vm create -g ${VM_RESOURCE_GROUP} -n restored-${VM}-${TS} --attach-os-disk \"\${OS_DISK_ID}\" --os-type ${OS_TYPE} --size ${VM_SIZE:-<choose-size>}"
    echo
    if ((${#DATA_VHD_PATHS[@]})); then
      echo "C) Data disks (attach with original LUNs):"
      for i in "${!DATA_VHD_PATHS[@]}"; do
        dp="${DATA_VHD_PATHS[$i]}"; lun="${DATA_LUNS[$i]}"; short="${DATA_SHORTS[$i]}"
        echo "   # LUN ${lun}"
        echo "   DD${i}_SAS=\$(sas \"${dp}\")"
        echo "   DD${i}_ID=\$(az disk create -g ${VM_RESOURCE_GROUP} -n restored-data-${VM}-${short}-${TS} --source \"${PAGE_BASE}/${dp}?\${DD${i}_SAS}\" --query id -o tsv)"
        echo "   az vm disk attach -g ${VM_RESOURCE_GROUP} --vm-name restored-${VM}-${TS} --disk \"\${DD${i}_ID}\" --lun ${lun}"
        echo
      done
    else
      echo "C) No data disks detected."
      echo
    fi
    if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
      echo "D) If using cold archive instead:"
      echo "   Rehydrate the cold blob to Cool, then service-copy into a page blob before steps A–C."
      echo "   Cold OS: ${COLD_BASE}/${OS_VHD_PATH}"
    fi
    echo
    echo "Cleanup snapshots by tag:"
    echo "  az snapshot list --query \"[?tags.'bbb-ticket'=='${BBB_TICKET}'].id\" -o tsv | xargs -n1 az snapshot delete --ids"
  } > "${TMPDIR}/restore_steps.txt"

  switch_sub "$STORAGE_SUBSCRIPTION_ID"
  upload_file "${TMPDIR}/restore_steps.txt" "${DEST_PREFIX}/_meta/restore_steps.txt" "${DEST_SAS:-}" "$DEST_BASE"

  echo "[5/9] Snapshots ..."
  switch_sub "$VM_SUBSCRIPTION_ID"
  SNAP_IDS=(); SNAP_DISK_SHORT_NAMES=()
  for DID in $DISK_IDS; do
    DNAME="$(basename "$DID")"
    SNAME="$(safe_snap_name "$VM" "$DNAME" "$TS" "$DID")"
    echo "   -> ${SNAME}"
    SID="$(create_snapshot_with_retry "$DID" "$SNAME" "$VM_RESOURCE_GROUP")"
    if [[ -n "${SID:-}" ]]; then
      SNAP_IDS+=("$SID")
      SNAP_DISK_SHORT_NAMES+=("$DNAME")
    else
      echo "ERROR: Snapshot not created for ${SNAME}" >&2
    fi
  done
  [[ ${#SNAP_IDS[@]} -gt 0 ]] || { echo "FATAL: no snapshots created; aborting."; exit 1; }

  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "[6/9] DRY RUN: skipping VHD copy. Would have copied:"
    for i in "${!SNAP_IDS[@]}"; do
      SHORT="${SNAP_DISK_SHORT_NAMES[$i]}"
      echo "      ${DEST_BASE}/${DEST_PREFIX}/${SHORT}.vhd"
    done
    echo "[7/9] DRY RUN: skipping cold-archive copies."
  else
    echo "[6/9] Copy snapshots to VHD page blobs ..."
    switch_sub "$STORAGE_SUBSCRIPTION_ID"
    COPIED_VHDS=()
    for i in "${!SNAP_IDS[@]}"; do
      SID="${SNAP_IDS[$i]}"; SHORT="${SNAP_DISK_SHORT_NAMES[$i]}"
      DEST_VHD_NAME="${SHORT}.vhd"; DEST_PATH="${DEST_PREFIX}/${DEST_VHD_NAME}"
      SRC_SAS_URL="$(az snapshot grant-access --ids "$SID" --duration-in-seconds $(( SRC_SAS_HOURS*3600 )) --access-level Read --query accessSAS -o tsv)"
      echo "   -> Copy ${DEST_VHD_NAME}"
      azcopy copy "$SRC_SAS_URL" "${DEST_BASE}/${DEST_PATH}?${DEST_SAS}" --overwrite=true
      PROPS="$(show_blob "${DEST_PATH}" "$CONTAINER")"; echo "      ${PROPS}"
      BYTES="$(az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$CONTAINER" \
               --name "${DEST_PATH}" --auth-mode login --query "properties.contentLength" -o tsv)"
      TOTAL_PAGE_BYTES=$((TOTAL_PAGE_BYTES + BYTES))
      COPIED_VHDS+=("${DEST_PATH}")
    done

    if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
      echo "[7/9] Cold archive copies (BLOCK blob, Archive tier) ..."
      for PATH in "${COPIED_VHDS[@]}"; do
        echo "   -> Cold copy (Archive) $(basename "$PATH")"
        END_READ="$(iso_utc_in 24)"
        SRC_READ_SAS="$(az storage blob generate-sas --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" -n "$PATH" \
                           --permissions r --expiry "$END_READ" --auth-mode login --as-user -o tsv 2>/dev/null || true)"
        if [[ -z "${SRC_READ_SAS:-}" ]]; then
          SA_KEY="$(az storage account keys list -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query [0].value -o tsv)"
          SRC_READ_SAS="$(az storage blob generate-sas --account-name "$STORAGE_ACCOUNT" -c "$CONTAINER" -n "$PATH" \
                           --permissions r --expiry "$END_READ" --account-key "$SA_KEY" -o tsv)"
        fi
        az storage blob copy start \
          --account-name "$STORAGE_ACCOUNT" \
          --destination-container "$COLD_CONTAINER" \
          --destination-blob "$PATH" \
          --source-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${PATH}?${SRC_READ_SAS}" \
          --tier Archive --auth-mode login
        C_BYTES="$(az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$COLD_CONTAINER" \
                   --name "$PATH" --auth-mode login --query "properties.contentLength" -o tsv || echo 0)"
        TOTAL_ARCHIVE_BYTES=$((TOTAL_ARCHIVE_BYTES + C_BYTES))
      done
    else
      echo "[7/9] Cold archive disabled"
    fi
  fi

  echo "[8/9] README ..."
  {
    echo "/****************************************************"
    echo "Archived VM artifacts."
    echo "- VHD page blobs under '${CONTAINER}/${VM}/${TS}/'."
    echo "- Restore steps: '${CONTAINER}/${VM}/${TS}/_meta/restore_steps.txt'"
    if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
      echo "- Cold copies (block blob, Archive tier) under '${COLD_CONTAINER}/${VM}/${TS}/'."
    fi
    echo "****************************************************/"
  } > "${TMPDIR}/README.txt"
  switch_sub "$STORAGE_SUBSCRIPTION_ID"
  upload_file "${TMPDIR}/README.txt" "${DEST_PREFIX}/_meta/README.txt" "${DEST_SAS:-}" "$DEST_BASE"

  # Restart & cleanup
  if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Starting VM ${VM} ..."
    az vm start -g "$VM_RESOURCE_GROUP" -n "$VM" || echo "WARN: start failed"
  fi
  if [[ "${DELETE_SNAPSHOTS_AFTER_COPY,,}" == "true" && "${DRY_RUN,,}" != "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Deleting snapshots for ${VM} ..."
    for SID in "${SNAP_IDS[@]}"; do
      az snapshot delete --ids "$SID" || echo "WARN: snapshot delete failed for $SID"
    done
  else
    echo "INFO: Keeping snapshots for ${VM} (DELETE_SNAPSHOTS_AFTER_COPY=false or DRY_RUN=true)."
  fi
  rm -rf "$TMPDIR"
  echo "=== DONE: ${VM} → ${DEST_BASE}/${DEST_PREFIX}"
done

#==================== Cost estimate (print + upload) ====================
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

  SUMMARY_JSON=$(cat <<J
{"mode":"NORMAL","ticket":"${BBB_TICKET}","run":"${TS}",
"vmSubscription":"${VM_SUBSCRIPTION_ID}","storageSubscription":"${STORAGE_SUBSCRIPTION_ID}",
"vmResourceGroup":"${VM_RESOURCE_GROUP}","storageAccount":"${STORAGE_ACCOUNT}",
"containers":{"page":"${CONTAINER}"$([[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]] && printf ', "cold":"%s"' "$COLD_CONTAINER")},
"bytes":{"page":${TOTAL_PAGE_BYTES},"archive":${TOTAL_ARCHIVE_BYTES}},
"gb":{"page":${PAGE_GB},"archive":${ARCH_GB}},
"rates":{"pageUSDPerGBMonth":${COST_RATE_PAGE_GB},"archiveUSDPerGBMonth":${COST_RATE_ARCHIVE_GB}},
"estimateUSDPerMonth":{"page":${EST_PAGE_COST},"archive":${EST_ARCH_COST},"total":${EST_TOTAL}}}
J
)
  echo "$SUMMARY_JSON" | jq .
  upload_file <(printf "%s" "$SUMMARY_JSON") "_runs/${TS}/cost-summary.json" "${DEST_SAS:-}" "$DEST_BASE" || true
fi

#==================== Security posture / re-secure ====================
echo
echo "===== Storage Account Security Validation ====="
PUB_ACCESS_NOW=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query publicNetworkAccess -o tsv)
DEF_ACTION_NOW=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query networkRuleSet.defaultAction -o tsv)
HTTPS_ONLY=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query enableHttpsTrafficOnly -o tsv)
TLS_MIN=$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query minimumTlsVersion -o tsv)
BLOB_VERSION=$(az storage account blob-service-properties show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query isVersioningEnabled -o tsv 2>/dev/null || echo "unknown")
SOFT_DELETE=$(az storage account blob-service-properties show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query deleteRetentionPolicy.enabled -o tsv 2>/dev/null || echo "unknown")

echo "publicNetworkAccess: ${PUB_ACCESS_NOW}"
echo "defaultAction:       ${DEF_ACTION_NOW}"
echo "httpsOnly:           ${HTTPS_ONLY}"
echo "minTLS:              ${TLS_MIN}"
echo "blobVersioning:      ${BLOB_VERSION}"
echo "softDelete:          ${SOFT_DELETE}"
if [[ "$PUB_ACCESS_NOW" != "Disabled" && "$DEF_ACTION_NOW" != "Deny" ]]; then
  echo "WARN: Public network still open (Enabled/Allow). Consider Deny/Private Endpoints."
fi
if [[ "$HTTPS_ONLY" != "true" || "$TLS_MIN" != "TLS1_2" ]]; then
  echo "WARN: Enforce HTTPS-only and set minimum TLS to TLS1_2."
fi
echo "=============================================="

if [[ "${DRY_RUN,,}" != "true" ]]; then
  read -r -p "Re-secure storage firewall now (set defaultAction=Deny)? [Y/n] " RES
  if [[ -z "${RES:-}" || "${RES,,}" == "y" || "${RES,,}" == "yes" ]]; then
    az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --default-action Deny --bypass AzureServices >/dev/null
    echo "INFO: Storage firewall set to Deny."
  else
    echo "INFO: Leaving storage firewall as-is."
  fi
fi

# Restore original subscription
[[ -n "${ORIG_SUB}" ]] && az account set --subscription "$ORIG_SUB" || true
