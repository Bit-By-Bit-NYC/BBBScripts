#!/usr/bin/env bash
set -euo pipefail

# ===== Colors =====
if [[ -t 1 ]]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; DIM=$'\033[2m'
  RESET=$'\033[0m'; BOLDY=$'\033[1;33m'; MAGENTA=$'\033[35m'
else
  RED=""; YELLOW=""; BLUE=""; DIM=""; RESET=""; BOLDY=""; MAGENTA=""
fi

log(){ printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need az; need jq

# ===== Config =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/config.txt"
[[ -f "$CFG" ]] || { cat >&2 <<'EOT'
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
source "$CFG"

: "${SUBSCRIPTION_ID:?}"; : "${RESOURCE_GROUP:?}"; : "${VAULT_NAME:?}"
: "${FABRIC_NAME:?}"; : "${PROTECTION_CONTAINER_NAME:?}"; : "${API_VERSION:?}"

az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

BASE_PC="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.RecoveryServices/vaults/$VAULT_NAME/replicationFabrics/$FABRIC_NAME/replicationProtectionContainers/$PROTECTION_CONTAINER_NAME"
LIST_URL="$BASE_PC/replicationProtectedItems?api-version=$API_VERSION"

STATE_DIR="$SCRIPT_DIR/state"
LAST_JSON="$STATE_DIR/last_status.json"
mkdir -p "$STATE_DIR"

# ===== Fetch ALL pages robustly into JSONL =====
log "Fetching protected items…"
TMP_JSONL="$(mktemp)"
URL="$LIST_URL"
while : ; do
  PAGE=$(az rest --method get --url "$URL")
  # append items as JSONL
  jq -c '.value[]? // empty' <<<"$PAGE" >> "$TMP_JSONL"
  next=$(jq -r '.nextLink // empty' <<<"$PAGE")
  [[ -z "$next" ]] && break
  URL="$next"
done

# If nothing returned, bail gracefully
if [[ ! -s "$TMP_JSONL" ]]; then
  echo "No items returned." >&2
  rm -f "$TMP_JSONL"
  exit 0
fi

# ===== Build current snapshot array =====
CUR=$(jq -c -s '
  map({
    rpi: (.name // ""),
    friendly: (.properties.friendlyName // ""),
    health: (.properties.replicationHealth // "Unknown"),
    status: (.properties.protectionStateDescription // .properties.protectionState // "Unknown"),
    rpo: (.properties.providerSpecificDetails.lastRpoInSeconds // "null")
  })
' "$TMP_JSONL")

# Load previous snapshot
PREV='[]'
[[ -f "$LAST_JSON" ]] && PREV=$(cat "$LAST_JSON")

# ===== Precompute counts per status for headers =====
STATUS_COUNTS_JSON=$(jq -c '
  group_by(.status) | map({key: .[0].status, value: length}) | from_entries
' <<<"$CUR")

# ===== Prepare ordered rows (status, health-group, rpo) and diff flags =====
# Output tab-separated lines: status \t rpi \t friendly \t health \t rpo \t changedFlag
ROWS_TSV=$(jq -r --argjson prev "$PREV" '
  def to_map(a): a | map({key:.rpi, value:.}) | from_entries;
  (to_map($prev)) as $pm
  | map(. + {
      group: (if .health == "Normal" then 1 else 0 end),
      rpo_num: (try (.rpo|tonumber) catch 999999999),
      changed: (
        if ($pm[.rpi] // null) == null then "new"
        else (
          ((.health != $pm[.rpi].health) or
           (.status != $pm[.rpi].status) or
           (.rpo != $pm[.rpi].rpo)) | if . then "changed" else "" end
        )
        end
      )
    })
  | sort_by(.status, .group, .rpo_num, .friendly)
  | .[]
  | [.status, .rpi, .friendly, .health, (.rpo|tostring), .changed]
  | @tsv
' <<<"$CUR")

# ===== Print grouped with headers and colored rows =====
last_status=""
idx=1
while IFS=$'\t' read -r STATUS RPI FRIENDLY HEALTH RPO CHG; do
  # header?
  if [[ "$STATUS" != "$last_status" ]]; then
    [[ -n "$last_status" ]] && printf "\n"
    COUNT=$(jq -r --arg s "$STATUS" '.[$s] // 0' <<<"$STATUS_COUNTS_JSON")
    printf "%s== %s — %d item(s) ==%s\n" "$DIM" "$STATUS" "$COUNT" "$RESET"
    last_status="$STATUS"
    idx=1
  fi

  # color by health
  case "$HEALTH" in
    Normal) COLOR="$BLUE" ;;
    Warning) COLOR="$YELLOW" ;;
    Critical) COLOR="$RED" ;;
    *) COLOR="$DIM" ;;
  esac

  # RPO highlight (seconds) when Normal & not null
  RPO_DISP="$RPO"
  if [[ "$HEALTH" == "Normal" && "$RPO" != "null" ]]; then
    RPO_DISP="${BOLDY}${RPO}${RESET}"
  fi

  # change flag
  flag=""
  [[ "$CHG" == "changed" ]] && flag="${MAGENTA}★ changed${RESET}"
  [[ "$CHG" == "new"     ]] && flag="${MAGENTA}★ new${RESET}"

  printf "%s%2d) %s | %s | Health:%s%s%s | Status:%s%s%s | RPO:%s%s  %s\n" \
    "$RESET" "$idx" "$FRIENDLY" "$RPI" \
    "$COLOR" "$HEALTH" "$RESET" \
    "$DIM" "$STATUS" "$RESET" \
    "$RPO_DISP" "$RESET" \
    "$flag"

  ((idx++))
done <<< "$ROWS_TSV"

# ===== Save snapshot =====
echo "$CUR" > "$LAST_JSON"
printf "\n%sSaved snapshot to:%s %s\n" "$DIM" "$RESET" "$LAST_JSON"

# cleanup
rm -f "$TMP_JSONL"
