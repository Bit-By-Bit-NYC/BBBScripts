#!/usr/bin/env bash
set -euo pipefail

# ---------- Tunables ----------
DEBUG=${DEBUG:-false}; $DEBUG && set -x
WAIT_MODE=${WAIT_MODE:-nowait}     # wait | nowait
ENABLE_TIMEOUT_SECS=${ENABLE_TIMEOUT_SECS:-3600}
POLL_INTERVAL_SECS=${POLL_INTERVAL_SECS:-30}

# ---------- Colors ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

# ---------- Helpers ----------
log(){ printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need jq; need az

# ---------- Config ----------
[[ -f ./config.txt ]] || { cat >&2 <<'EOT'
Missing ./config.txt. Example:
SUBSCRIPTION_ID=<subId>
RESOURCE_GROUP=<rg>
VAULT_NAME=<vault>
FABRIC_NAME=<fabric>
PROTECTION_CONTAINER_NAME=<container>
API_VERSION=2025-02-01
EOT
exit 1; }
# shellcheck disable=SC1091
source ./config.txt

: "${SUBSCRIPTION_ID:?}"; : "${RESOURCE_GROUP:?}"; : "${VAULT_NAME:?}"
: "${FABRIC_NAME:?}"; : "${PROTECTION_CONTAINER_NAME:?}"; : "${API_VERSION:?}"

az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
BASE_PC="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.RecoveryServices/vaults/$VAULT_NAME/replicationFabrics/$FABRIC_NAME/replicationProtectionContainers/$PROTECTION_CONTAINER_NAME"
BASE_RPI="$BASE_PC/replicationProtectedItems"

az extension add -n site-recovery -y >/dev/null 2>&1 || true
mkdir -p ./logs

# ---------- Selection parsing (newline output; robust with IFS) ----------
expand_selection(){
  # input like: "1-5,8,12-13"
  local input="$1"
  local IFS=',' parts p a b
  read -ra parts <<< "$input"
  for p in "${parts[@]}"; do
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      if (( a <= b )); then
        for ((i=a;i<=b;i++)); do echo "$i"; done
      else
        for ((i=a;i>=b;i--)); do echo "$i"; done
      fi
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      echo "$p"
    fi
  done
}

# ---------- Inventory ----------
get_rpis_json(){ az rest --method get --url "$BASE_RPI?api-version=$API_VERSION"; }

print_inventory(){
  # unhealthy first (Critical/Warning/Unknown), healthy (Normal) last
  local js="$1"
  # Build an ordered list with a 'group' flag: 0 = needs attention, 1 = healthy
  jq -r '
    .value
    | map({
        name: .name,
        friendly: .properties.friendlyName,
        health: (.properties.replicationHealth // "Unknown"),
        rpo: (.properties.providerSpecificDetails.lastRpoInSeconds // "null"),
        group: (if (.properties.replicationHealth // "") == "Normal" then 1 else 0 end)
      })
    | sort_by(.group, (.rpo|tonumber? // 999999999), .friendly)
    | to_entries[]
    | "\(.key+1)|\(.value.friendly)|\(.value.name)|\(.value.health)|\(.value.rpo)"
  ' <<<"$js" | while IFS='|' read -r idx friendly name health rpo; do
    case "$health" in
      Normal) color="$GREEN";;
      Warning) color="$YELLOW";;
      Critical) color="$RED";;
      *) color="$DIM";;
    esac
    printf "%s%s) %s | %s | %s | Health:%s%s%s | RPO:%s%s\n" \
      "$RESET" "$idx" "$friendly" "$name" "$name" "$color" "$health" "$RESET" "${rpo}" "$RESET"
  done
}

# ---------- Backup ----------
backup_rpi(){
  local rpi_name="$1" rpi_friendly="$2"
  local ts folder; ts=$(date -u +'%Y%m%d_%H%M%S'); folder="./replback_${ts}/${rpi_name}"
  mkdir -p "$folder"
  log "🔹 Backup: [$rpi_friendly] ($rpi_name) → $folder"
  az rest --method get --url "$BASE_RPI/$rpi_name?api-version=$API_VERSION" > "$folder/protected_item.json"
  log "✅ Backup complete: $folder/protected_item.json"
  echo "$folder"
}

# ---------- Disable & wait ----------
disable_rpi_and_wait_removed(){
  local rpi_name="$1"
  log "🔸 Disable: [$rpi_name] (InMageRcm)"
  az rest --method post \
    --url "$BASE_RPI/$rpi_name/remove?api-version=$API_VERSION" \
    --body '{ "properties": { "replicationProviderInput": { "instanceType": "DisableProtectionProviderSpecificInput" } } }' >/dev/null
  local start=$(date +%s)
  while az rest --method get --url "$BASE_RPI/$rpi_name?api-version=$API_VERSION" >/dev/null 2>&1; do
    log "   … waiting for RPI removal (elapsed $(( $(date +%s)-start ))s)"
    sleep 20
  done
  log "✅ RPI removed: [$rpi_name]"
}

# ---------- Wait for enable ----------
wait_for_enable_success(){
  local rpi_name="$1"
  local start=$(date +%s)
  while true; do
    if ! az rest --method get --url "$BASE_RPI/$rpi_name?api-version=$API_VERSION" >/dev/null 2>&1; then
      log "   … RPI not visible yet (elapsed $(( $(date +%s)-start ))s)"
    else
      local rpi_json state health rpo rp_time
      rpi_json=$(az rest --method get --url "$BASE_RPI/$rpi_name?api-version=$API_VERSION")
      state=$(echo "$rpi_json" | jq -r '.properties.protectionState')
      health=$(echo "$rpi_json" | jq -r '.properties.replicationHealth')
      rpo=$(echo "$rpi_json" | jq -r '.properties.providerSpecificDetails.lastRpoInSeconds // "null"')
      rp_time=$(echo "$rpi_json" | jq -r '.properties.providerSpecificDetails.lastRecoveryPointReceived // "null"')
      log "   … status: protectionState=$state, replicationHealth=$health, lastRpo=${rpo}, lastRecoveryPointReceived=${rp_time} (elapsed $(( $(date +%s)-start ))s)"
      if [[ "$state" == "Protected" ]] && [[ "$health" == "Normal" || "$health" == "Warning" ]]; then
        log "✅ Enable completed"
        return 0
      fi
    fi
    (( $(date +%s)-start >= ENABLE_TIMEOUT_SECS )) && { log "❌ Timeout waiting for enable success"; return 1; }
    sleep "$POLL_INTERVAL_SECS"
  done
}

# ---------- Preflight/Remap ----------
source_machine_snapshot(){
  local fdmid="$1"
  az rest --method get --url "https://management.azure.com$fdmid?api-version=2023-06-06" \
    | jq -c '{name:.name, power:(.properties.powerStatus//"Unknown"), ips:(.properties.ipAddresses//[]), vmtools:(.properties.vmwareToolsStatus//"Unknown")}'
}
preflight_ok(){
  local snap="$1"
  local pwr ipcount
  pwr=$(jq -r '.power' <<<"$snap")
  ipcount=$(jq -r '.ips | length' <<<"$snap")
  [[ "$pwr" == "ON" && "$ipcount" -gt 0 ]]
}
remap_fdmid_by_name(){
  local fdmid="$1" friendly="$2"
  local site; site=$(awk -F'/machines/' '{print $1}' <<<"$fdmid")
  local list
  list=$(az rest --method get --url "https://management.azure.com$site/machines?api-version=2023-06-06")
  jq -r --arg FN "$friendly" '
    .value[]
    | select((.properties.friendlyName//.name | ascii_downcase)==($FN|ascii_downcase))
    | .id' <<<"$list" | head -n1
}

# ---------- Enable via CLI (portal-equivalent) ----------
enable_from_backup_cli(){
  local folder="$1"
  local bjson="$folder/protected_item.json"
  [[ -f "$bjson" ]] || { echo "Missing backup JSON: $bjson" >&2; return 1; }

  local friendly rpi_name
  friendly=$(jq -r '.properties.friendlyName' "$bjson")
  rpi_name=$(jq -r '.name' "$bjson")

  local FDMID POLICY PSRV RUNAS TNET TTEST TDIAG TRG TVM TVMSIZE LOGSA
  FDMID=$(jq -r '.properties.providerSpecificDetails.fabricDiscoveryMachineId' "$bjson")
  POLICY=$(jq -r '.properties.policyId' "$bjson")
  PSRV=$(jq -r '.properties.providerSpecificDetails.processServerId' "$bjson")
  RUNAS=$(jq -r '.properties.providerSpecificDetails.runAsAccountId' "$bjson")
  TNET=$(jq -r '.properties.providerSpecificDetails.targetNetworkId' "$bjson")
  TTEST=$(jq -r '.properties.providerSpecificDetails.testNetworkId' "$bjson")
  TDIAG=$(jq -r '.properties.providerSpecificDetails.targetBootDiagnosticsStorageAccountId' "$bjson")
  TRG=$(jq -r '.properties.providerSpecificDetails.targetResourceGroupId // .properties.targetResourceGroupId // empty' "$bjson")
  TVM=$(jq -r '.properties.providerSpecificDetails.targetVmName' "$bjson")
  TVMSIZE=$(jq -r '.properties.providerSpecificDetails.targetVmSize' "$bjson")
  LOGSA=$(jq -r '(.properties.providerSpecificDetails.protectedDisks[0].logStorageAccountId // .properties.providerSpecificDetails.targetBootDiagnosticsStorageAccountId)' "$bjson")

  # Preflight & optional remap
  local snap newfdm
  snap=$(source_machine_snapshot "$FDMID" 2>/dev/null || true)
  if [[ -z "$snap" ]]; then
    log "   ⚠️  Could not read discovery record; attempting remap by name…"
    newfdm=$(remap_fdmid_by_name "$FDMID" "$friendly" || true)
    if [[ -n "$newfdm" ]]; then
      FDMID="$newfdm"
      snap=$(source_machine_snapshot "$FDMID" 2>/dev/null || true)
      log "   ↪ remapped discovery id: $FDMID"
    fi
  fi
  if [[ -n "$snap" ]] && ! preflight_ok "$snap"; then
    log "   ⏭️  Skipping enable: source VM not ready (needs power=ON and IP)."
    {
      printf "%s,%s,%s,%s,%s\n" \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$friendly" "$rpi_name" \
        "$(jq -r '.power' <<<"$snap")" "$(jq -c '.ips' <<<"$snap")"
    } >> ./logs/skipped.csv
    return 0
  fi

  local PROV_JSON_FILE="/tmp/prov_${rpi_name}.json"
  jq -n \
    --arg f "$FDMID" --arg p "$PSRV" --arg r "$RUNAS" \
    --arg tn "$TNET" --arg tt "$TTEST" --arg td "$TDIAG" \
    --arg trg "$TRG" --arg tvm "$TVM" --arg size "$TVMSIZE" --arg logsa "$LOGSA" \
    '{ "in-mage-rcm": {
        "fabric-discovery-machine-id":$f,
        "process-server-id":$p,
        "run-as-account-id":$r,
        "target-network-id":$tn,
        "test-network-id":$tt,
        "target-boot-diagnostics-storage-account-id":$td,
        "target-resource-group-id":$trg,
        "target-vm-name":$tvm,
        "target-vm-size":$size,
        "disks-default":{"disk-type":"StandardSSD_LRS","log-storage-account-id":$logsa}
      }}' > "$PROV_JSON_FILE"

  if [[ "$WAIT_MODE" == "nowait" ]]; then
    log "🔹 Queue enable (no-wait) for [$friendly]"
    az site-recovery protected-item create \
      -g "$RESOURCE_GROUP" --vault-name "$VAULT_NAME" \
      --fabric-name "$FABRIC_NAME" \
      --protection-container "$PROTECTION_CONTAINER_NAME" \
      --replicated-protected-item-name "$rpi_name" \
      --policy-id "$POLICY" \
      --provider-details @"$PROV_JSON_FILE" \
      --only-show-errors -o none \
      > "/tmp/asr_enable_${rpi_name}.log" 2>&1 &
    local pid=$!
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') | PID=$pid | VM=$friendly | RPI=$rpi_name | LOG=/tmp/asr_enable_${rpi_name}.log" >> ./asr_enable_queue.txt
    log "   queued: PID $pid  log:/tmp/asr_enable_${rpi_name}.log"
    return 0
  else
    log "🔹 Enable (wait) for [$friendly]"
    az site-recovery protected-item create \
      -g "$RESOURCE_GROUP" --vault-name "$VAULT_NAME" \
      --fabric-name "$FABRIC_NAME" \
      --protection-container "$PROTECTION_CONTAINER_NAME" \
      --replicated-protected-item-name "$rpi_name" \
      --policy-id "$POLICY" \
      --provider-details @"$PROV_JSON_FILE"
    wait_for_enable_success "$rpi_name"
  fi
}

restore_cycle(){
  local rpi_name="$1" friendly="$2"
  local folder; folder=$(backup_rpi "$rpi_name" "$friendly")
  disable_rpi_and_wait_removed "$rpi_name"
  enable_from_backup_cli "$folder"
}

list_backups_newest(){
  # portable newest-first without GNU printf; relies on shell glob order reversed by ls -t
  ls -t ./replback_*/*/protected_item.json 2>/dev/null || true
}

queue_status(){
  log "Recent ASR jobs:"
  az site-recovery job list -g "$RESOURCE_GROUP" --vault-name "$VAULT_NAME" \
    --query "sort_by([].{Name:name,State:properties.state,Task:properties.displayName,Item:properties.targetObjectName,Start:properties.startTime}, &Start) | reverse(@)[:20]" -o table || true
  [[ -f ./logs/skipped.csv ]] && { log "Skipped (preflight failed):"; column -t -s, ./logs/skipped.csv || cat ./logs/skipped.csv; }
}

# ---------- Menu ----------
echo "Choose mode:
  1) backup
  2) backup → disable → queue enable (recommended; WAIT_MODE=$WAIT_MODE)
  3) restore-from-backup (disable if present → queue enable; newest backups first)"
read -r MODE

case "$MODE" in
  1|2)
    log "Fetching protected items (inventory)…"
    RPIS_JSON=$(get_rpis_json)

    # keep the ordered lines for indexed selection
    mapfile -t ORDERED < <(jq -r '
      .value
      | map({
          name: .name,
          friendly: .properties.friendlyName,
          health: (.properties.replicationHealth // "Unknown"),
          rpo: (.properties.providerSpecificDetails.lastRpoInSeconds // "null"),
          group: (if (.properties.replicationHealth // "") == "Normal" then 1 else 0 end)
        })
      | sort_by(.group, (.rpo|tonumber? // 999999999), .friendly)
      | to_entries[]
      | "\(.key+1)|\(.value.friendly)|\(.value.name)|\(.value.health)|\(.value.rpo)"
    ' <<<"$RPIS_JSON")

    # pretty print with colors
    idx=1
    while IFS='|' read -r _ friendly name health rpo; do
      case "$health" in
        Normal) color="$GREEN";;
        Warning) color="$YELLOW";;
        Critical) color="$RED";;
        *) color="$DIM";;
      esac
      printf "%s%d) %s | %s | Health:%s%s%s | RPO:%s%s\n" \
        "$RESET" "$idx" "$friendly" "$name" "$color" "$health" "$RESET" "${rpo}" "$RESET"
      ((idx++))
    done < <(printf '%s\n' "${ORDERED[@]}")

    echo "Enter number(s) or ranges (e.g., 1-5,8,12-13):"
    read -r SEL

    # iterate indices (one per line)
    while IFS= read -r IDX; do
      [[ -z "$IDX" ]] && continue
      # validate integer
      [[ "$IDX" =~ ^[0-9]+$ ]] || { log "Skipping invalid token [$IDX]"; continue; }
      # find the corresponding stored line
      LINE="${ORDERED[$((IDX-1))]:-}"
      [[ -z "$LINE" ]] && { log "Skipping out-of-range index [$IDX]"; continue; }
      FRIENDLY=$(awk -F'|' '{print $2}' <<<"$LINE" | xargs)
      RPI_NAME=$(awk -F'|' '{print $3}' <<<"$LINE" | xargs)
      log "===== Processing [$FRIENDLY] ($RPI_NAME) ====="
      if [[ "$MODE" == "1" ]]; then
        _folder=$(backup_rpi "$RPI_NAME" "$FRIENDLY") >/dev/null
      else
        restore_cycle "$RPI_NAME" "$FRIENDLY"
      fi
      log "===== Done [$FRIENDLY] ====="
    done < <(expand_selection "$SEL")

    queue_status
    ;;
  3)
    log "Scanning backups (newest first)…"
    mapfile -t BACKUPS < <(list_backups_newest)
    (( ${#BACKUPS[@]} )) || { echo "No backups found." >&2; exit 1; }
    for i in "${!BACKUPS[@]}"; do echo "$((i+1))) ${BACKUPS[$i]}"; done
    echo "Enter number(s) or ranges (e.g., 1-3,7):"
    read -r SEL
    while IFS= read -r IDX; do
      [[ -z "$IDX" ]] && continue
      [[ "$IDX" =~ ^[0-9]+$ ]] || { log "Skipping invalid token [$IDX]"; continue; }
      BF="${BACKUPS[$((IDX-1))]:-}"; [[ -z "$BF" ]] && { log "Skipping out-of-range index [$IDX]"; continue; }
      FOLDER="$(dirname "$BF")"
      local_name=$(jq -r '.name' "$BF"); FRIENDLY=$(jq -r '.properties.friendlyName' "$BF")
      log "===== Restoring from backup for [$FRIENDLY] (RPI: $local_name) ====="
      if az rest --method get --url "$BASE_RPI/$local_name?api-version=$API_VERSION" >/dev/null 2>&1; then
        log "Existing RPI found; disabling first…"; disable_rpi_and_wait_removed "$local_name"
      else
        log "No existing RPI; proceeding to enable."
      fi
      enable_from_backup_cli "$FOLDER"
      log "===== Done [$FRIENDLY] ====="
    done < <(expand_selection "$SEL")
    queue_status
    ;;
  *) echo "Invalid option"; exit 1;;
esac
