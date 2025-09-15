#!/usr/bin/env bash
set -euo pipefail

CFG="./config.txt"
[[ -f "$CFG" ]] || echo "WARN: Missing $CFG (defaults will be used where possible)"
# shellcheck disable=SC1090
source "$CFG" 2>/dev/null || true

# ---------- sane defaults & aliases ----------
VM_SUBSCRIPTION_ID="${VM_SUBSCRIPTION_ID:-$SUBSCRIPTION_ID:-}"
STORAGE_SUBSCRIPTION_ID="${STORAGE_SUBSCRIPTION_ID:-$SUBSCRIPTION_ID:-}"

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
if [[ "${KEEP_SNAPSHOTS,,}" == "true" ]]; then
  DELETE_SNAPSHOTS_AFTER_COPY=false
fi

ENABLE_COLD_ARCHIVE="${ENABLE_COLD_ARCHIVE:-false}"
COLD_CONTAINER="${COLD_CONTAINER:-archive-cold}"

COST_RATE_PAGE_GB="${COST_RATE_PAGE_GB:-0.045}"
COST_RATE_ARCHIVE_GB="${COST_RATE_ARCHIVE_GB:-0.00099}"

# Subscriptions summary
echo "[*] VM subscription:       ${VM_SUBSCRIPTION_ID:-<unset>}"
echo "[*] Storage subscription:  ${STORAGE_SUBSCRIPTION_ID:-<unset>}"
echo "[*] VM RG:                 $VM_RESOURCE_GROUP"
echo "[*] Storage RG:            $STORAGE_RESOURCE_GROUP"
echo "[*] Storage Account:       $STORAGE_ACCOUNT"
echo "[*] Containers:            page=$CONTAINER  cold=$COLD_CONTAINER (enabled=$ENABLE_COLD_ARCHIVE)"
echo "[*] Ticket:                $BBB_TICKET"
echo "[*] STOP_VM_FOR_SNAPSHOT=$STOP_VM_FOR_SNAPSHOT | DELETE_SNAPSHOTS_AFTER_COPY=$DELETE_SNAPSHOTS_AFTER_COPY | KEEP_SNAPSHOTS=$KEEP_SNAPSHOTS"

# Remember original subscription to restore later
ORIG_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")

switch_sub() {
  local sub="$1"
  [[ -z "$sub" ]] && return 0
  az account set --subscription "$sub"
}

# ---------- STORAGE MANAGEMENT PLANE (may be different subscription) ----------
switch_sub "$STORAGE_SUBSCRIPTION_ID"

# Resolve storage account & posture
SA_JSON="$(az storage account show -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -o json)"
SA_ID="$(echo "$SA_JSON" | jq -r .id)"
if [[ -z "${SA_ID:-}" || "$SA_ID" == "null" ]]; then
  echo "FATAL: Storage account $STORAGE_ACCOUNT not found in $STORAGE_RESOURCE_GROUP"; exit 1
fi
PUB_ACCESS="$(echo "$SA_JSON" | jq -r '.publicNetworkAccess // "Enabled"')"
DEF_ACTION="$(echo "$SA_JSON" | jq -r '.networkRuleSet.defaultAction // "Allow"')"
echo "[*] Storage publicNetworkAccess=$PUB_ACCESS, defaultAction=$DEF_ACTION"

if [[ "$PUB_ACCESS" != "Enabled" || "$DEF_ACTION" != "Allow" ]]; then
  echo
  echo ">>> STORAGE ACCESS IS RESTRICTED."
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

# Ensure containers (AAD control plane)
az storage container create --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER" --auth-mode login || true
if [[ "${ENABLE_COLD_ARCHIVE,,}" == "true" ]]; then
  az storage container create --account-name "$STORAGE_ACCOUNT" --name "$COLD_CONTAINER" --auth-mode login || true
fi

DEST_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
COLD_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${COLD_CONTAINER}"
END_TIME=$(date -u -d "+${DEST_SAS_HOURS} hour" '+%Y-%m-%dT%H:%MZ')

# Data-plane RBAC hint (for AAD SAS)
ME_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
HAS_DATA_ROLE="$(az role assignment list --assignee-object-id "$ME_OID" --scope "$SA_ID" \
  --query "[?contains(roleDefinitionName, 'Storage Blob Data')].roleDefinitionName | length(@)" -o tsv 2>/dev/null || echo 0)"
if [[ "${HAS_DATA_ROLE:-0}" -eq 0 ]]; then
  echo "WARN: No 'Storage Blob Data *' RBAC; user-delegation SAS may fail. Will try account key fallback."
fi

# Mint SAS for page container
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

# Mint SAS for cold container if enabled
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

# Helpers
upload_file() {
  local local_path="$1" blob_rel="$2" sas="$3" base="$4"
  local dest_url="${base}/${blob_rel}?${sas}"
  azcopy copy "$local_path" "$dest_url" --overwrite=true   # show progress
}
show_blob() {
  local name="$1" cont="$2"
  az storage blob show --account-name "$STORAGE_ACCOUNT" --container-name "$cont" \
    --name "$name" --auth-mode login \
    --query "{blobType:properties.blobType, size:properties.contentLength}"
}
create_snapshot_with_retry() {
  local disk_id="$1" snap_name="$2" rg="$3"
  local sid=""
  sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
        --tags "bbb-ticket=$BBB_TICKET" "source=disk" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "${sid:-}" ]]; then
    echo "WARN: snapshot create returned empty for $snap_name — retrying with verbose output…"
    sid="$(az snapshot create -g "$rg" -n "$snap_name" --source "$disk_id" \
          --tags "bbb-ticket=$BBB_TICKET" "source=disk" --query id -o tsv 2>&1 || true)"
    if [[ ! "$sid" =~ ^/subscriptions/.*/providers/Microsoft\.Compute/snapshots/.*$ ]]; then
      echo "ERROR creating snapshot $snap_name:"
      echo "$sid"
      sid=""
    fi
  fi
  if [[ -n "${sid:-}" ]]; then
    az snapshot show --ids "$sid" --query "{name:name,time:timeCreated}" -o tsv
  fi
  printf "%s" "$sid"
}

# Run context
TS=$(date -u +"%Y%m%dT%H%M%SZ")
START=$SECONDS
TOTAL_PAGE_BYTES=0
TOTAL_ARCHIVE_BYTES=0
RUN_META_DIR="_runs/${TS}"
upload_file <(printf '{"runStartedUtc":"%s","ticket":"%s"}' "$TS" "$BBB_TICKET") "${RUN_META_DIR}/run-start.json" "$DEST_SAS" "$DEST_BASE" || true

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
  upload_file "${TMPDIR}/manifest.yaml" "${DEST_PREFIX}/_meta/manifest.yaml" "$DEST_SAS" "$DEST_BASE"
  upload_file "${TMPDIR}/vm.json"       "${DEST_PREFIX}/_meta/vm.json"       "$DEST_SAS" "$DEST_BASE"
  upload_file "${TMPDIR}/ip.json"       "${DEST_PREFIX}/_meta/ip.json"       "$DEST_SAS" "$DEST_BASE"
  upload_file "${TMPDIR}/nics.txt"      "${DEST_PREFIX}/_meta/nics.txt"      "$DEST_SAS" "$DEST_BASE"
  show_blob "${DEST_PREFIX}/_meta/manifest.yaml" "$CONTAINER" >/dev/null

  # Upload restore steps reference
  cat > "${TMPDIR}/restore_steps.txt" <<'RST'
RESTORE GUIDE (from archived VHDs)

A) FAST PATH (page-blob VHDs):
1) Pick OS VHD path in the archive container: <vm>/<timestamp>/<osdisk>.vhd
2) Create managed disk from the VHD:
   az disk create -g <rg> -n <osdisk-name> --source "https://<account>.blob.core.windows.net/<container>/<path>?<sas>"
3) Create VM from that disk:
   az vm create -g <rg> -n <vm-name> --attach-os-disk <osdisk-id> --os-type <Linux|Windows> --size <vmSize>
4) For each data disk VHD:
   - az disk create --source "<block SAS URL>"
   - az vm disk attach --vm-name <vm-name> --disk <disk-id> --lun <original-lun>
5) Recreate/attach NIC(s) (see _meta/ip.json and _meta/nics.txt). Apply tags/diagnostics from _meta/vm.json.

B) COLD PATH (block-blob Archive), only if you enabled cold copies:
1) Rehydrate archive blob to Cool:
   az storage blob set-tier --tier Cool --rehydrate-priority High --name <vm>/<ts>/<disk>.vhd -c <cold-container> -n <blob> --auth-mode login
   Wait until rehydrate completes (archiveStatus clears).
2) Convert to page blob:
   - Get size: az storage blob show ... --query properties.contentLength
   - Create empty page blob in page container (same size):
     az storage blob create --type page --content-length <size> -c <page-container> -n <path> --auth-mode login
   - Server-side copy:
     az storage blob copy start --destination-container <page-container> --destination-blob <path> \
       --source-uri "https://<account>.blob.core.windows.net/<cold-container>/<path>?<sas>" --auth-mode login
   - Wait for copyStatus=success, then proceed as in A) with that page blob URL.

Notes:
- Generation: If VM was Gen2, Azure will infer when creating disk. If needed: az disk create --hyper-v-generation V2
- Regions: import must be in same region as storage account.
- Permissions: you need Storage Blob Data rights (AAD) or SAS with read access to the VHDs.
RST
  upload_file "${TMPDIR}/restore_steps.txt" "${DEST_PREFIX}/_meta/restore_steps.txt" "$DEST_SAS" "$DEST_BASE"

  echo "[5/9] Snapshots ..."
  switch_sub "$VM_SUBSCRIPTION_ID"
  SNAP_IDS=()
  for DID in $DISK_IDS; do
    DNAME="$(basename "$DID")"
    SNAME="${VM}-${DNAME}-${TS}"
    echo "   -> $SNAME"
    SID="$(create_snapshot_with_retry "$DID" "$SNAME" "$VM_RESOURCE_GROUP")"
    if [[ -n "${SID:-}" ]]; then
      SNAP_IDS+=("$SID")
    else
      echo "ERROR: Snapshot not created for $SNAME"
    fi
  done
  [[ ${#SNAP_IDS[@]} -gt 0 ]] || { echo "FATAL: no snapshots created; aborting."; exit 1; }

  echo "[6/9] Copy snapshots to VHD page blobs ..."
  COPIED_VHDS=()
  for SID in "${SNAP_IDS[@]}"; do
    SNAME="$(az snapshot show --ids "$SID" --query name -o tsv)"
    ORIG_DNAME="${SNAME#"${VM}-"}"; ORIG_DNAME="${ORIG_DNAME%"-${TS}"}"
    DEST_VHD_NAME="${ORIG_DNAME}.vhd"
    DEST_PATH="${DEST_PREFIX}/${DEST_VHD_NAME}"
    SRC_SAS_URL="$(az snapshot grant-access --ids "$SID" --duration-in-seconds $(( SRC_SAS_HOURS*3600 )) --access-level Read --query accessSAS -o tsv)"

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
  upload_file "${TMPDIR}/README.txt" "${DEST_PREFIX}/_meta/README.txt" "$DEST_SAS" "$DEST_BASE"

  if [[ "${STOP_VM_FOR_SNAPSHOT,,}" == "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Starting VM $VM ..."
    az vm start -g "$VM_RESOURCE_GROUP" -n "$VM" || echo "WARN: start failed"
  fi

  if [[ "${DELETE_SNAPSHOTS_AFTER_COPY,,}" == "true" ]]; then
    switch_sub "$VM_SUBSCRIPTION_ID"
    echo "[*] Deleting snapshots for $VM ..."
    for SID in "${SNAP_IDS[@]}"; do
      az snapshot delete --ids "$SID" || echo "WARN: snapshot delete failed for $SID"
    done
  else
    echo "INFO: Keeping snapshots for $VM (DELETE_SNAPSHOTS_AFTER_COPY=false or KEEP_SNAPSHOTS=true)."
  fi

  rm -rf "$TMPDIR"
  echo "=== DONE: $VM → ${DEST_BASE}/${DEST_PREFIX}"
done

DUR=$((SECONDS-START))

# ---------- COST ESTIMATE ----------
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
upload_file <(printf "%s" "$SUMMARY_JSON") "_runs/${TS}/cost-summary.json" "$DEST_SAS" "$DEST_BASE" || true

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

# Final prompt to re-secure firewall
echo
read -r -p "Re-secure storage (set defaultAction=Deny again)? [Y/n] " RES
if [[ -z "${RES:-}" || "${RES,,}" == "y" || "${RES,,}" == "yes" ]]; then
  az storage account update -g "$STORAGE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" \
    --default-action Deny --bypass AzureServices
  echo "INFO: Storage firewall set to Deny."
else
  echo "INFO: Leaving storage firewall as-is (Allow)."
fi

# Restore original subscription (if any)
[[ -n "$ORIG_SUB" ]] && az account set --subscription "$ORIG_SUB" || true
echo "[*] 


