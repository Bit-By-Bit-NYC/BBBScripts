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

secs_human(){  # pretty-print seconds
  local s=${1:-0}
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "$s"; return; }
  local d=$(( s/86400 )); s=$(( s%86400 ))
  local h=$(( s/3600 ));  s=$(( s%3600  ))
  local m=$(( s/60   ));  s=$(( s%60     ))
  local out=""
  (( d>0 )) && out+="${d}d"
  (( h>0 )) && out+="${h}h"
  (( m>0 )) && out+="${m}m"
  out+="${s}s"
  echo "$out"
}

# ===== Config =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${1:-$SCRIPT_DIR/config.txt}"

[[ -f "$CFG" ]] || {
  cat >&2 <<'EOT'
Missing config file.
Usage: ./check_asr-status.sh [optional-path-to-config.txt]
Example config:
SUBSCRIPTION_ID=<subId>
RESOURCE_GROUP=<rg>
VAULT_NAME=<vault>
API_VERSION=2025-02-01
# Optional for VMware:
FABRIC_NAME=<fabric>
PROTECTION_CONTAINER_NAME=<container>
EOT
  exit 1
}

# shellcheck disable=SC1090
source "$CFG"

: "${SUBSCRIPTION_ID:?}"; : "${RESOURCE_GROUP:?}"; : "${VAULT_NAME:?}"
: "${API_VERSION:?}"

az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

STATE_DIR="$SCRIPT_DIR/state"
mkdir -p "$STATE_DIR"
BASE_CFG="$(basename "$CFG")"
LAST_JSON="$STATE_DIR/last_status_${BASE_CFG}.json"

log "Fetching protected items…"
TMP_JSONL="$(mktemp)"

# Choose API URL
if [[ -n "${FABRIC_NAME:-}" && -n "${PROTECTION_CONTAINER_NAME:-}" ]]; then
  URL="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.RecoveryServices/vaults/$VAULT_NAME/replicationFabrics/$FABRIC_NAME/replicationProtectionContainers/$PROTECTION_CONTAINER_NAME/replicationProtectedItems?api-version=$API_VERSION"
else
  URL="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.RecoveryServices/vaults/$VAULT_NAME/replicationProtectedItems?api-version=$API_VERSION"
fi

while : ; do
  PAGE=$(az rest --method get --url "$URL")
  jq -c '.value[]? // empty' <<<"$PAGE" >> "$TMP_JSONL"
  next=$(jq -r '.nextLink // empty' <<<"$PAGE")
  [[ -z "$next" ]] && break
  URL="$next"
done

if [[ ! -s "$TMP_JSONL" ]]; then
  echo "No items returned." >&2
  rm -f "$TMP_JSONL"; exit 0
fi

# --- jq transformation (robust across VMware/Hyper-V) ---
CUR=$(jq -c -s '
  def to_epoch:
    (tostring | sub("\\.[0-9]+"; "") | fromdateiso8601);

  # pick first field that is an ISO-like string (YYYY-MM-DDT…)
  def iso_ts:
    [ .properties.latestRecoveryPoint,
      .properties.providerSpecificDetails.lastRecoveryPointReceived,
      .properties.providerSpecificDetails.lastRecoveryPointInUTC,
      .properties.lastRecoveryPointReceived
    ]
    | map(select(type=="string" and test("^\\d{4}-\\d{2}-\\d{2}T")))
    | .[0];

  map({
    rpi: (.name // ""),
    friendly: (.properties.friendlyName // ""),
    health: (.properties.replicationHealth // .properties.health // "Unknown"),
    status: (.properties.protectionStateDescription // .properties.protectionState // "Unknown"),
    lastRP: (iso_ts // ""),
    rpo:
      if (.properties.providerSpecificDetails.lastRpoInSeconds? != null)
        then .properties.providerSpecificDetails.lastRpoInSeconds
      else
        (iso_ts) as $ts
        | if ($ts != null and ($ts|tostring) != "")
            then (now - ($ts | to_epoch)) | floor
            else "null"
          end
      end
  })
' "$TMP_JSONL")

PREV='[]'
[[ -f "$LAST_JSON" ]] && PREV=$(cat "$LAST_JSON")

STATUS_COUNTS_JSON=$(jq -c 'group_by(.status) | map({key: .[0].status, value: length}) | from_entries' <<<"$CUR")
TOTAL_ITEMS=$(jq 'length' <<<"$CUR")
TOTAL_PROTECTED=$(jq -r --arg s "Protected" '.[$s] // 0' <<<"$STATUS_COUNTS_JSON")

ROWS_TSV=$(jq -r --argjson prev "$PREV" '
  def to_map(a): a | map({key:.rpi, value:.}) | from_entries;
  (to_map($prev)) as $pm
  | map(. + {
      group: (if .health == "Normal" then 1 else 0 end),
      rpo_num: (try (.rpo|tonumber) catch 999999999),
      changed:
        if ($pm[.rpi] // null) == null then "new"
        else (
          (.health != $pm[.rpi].health) or
          (.status != $pm[.rpi].status) or
          (
            ((($pm[.rpi].rpo|tostring) == "null") and ((.rpo|tostring) != "null"))
            or (
              (try ($pm[.rpi].rpo|tonumber) catch 0) < 3600
              and (try (.rpo|tonumber) catch 0) >= 3600
            )
            or (
              (try ($pm[.rpi].rpo|tonumber) catch 0) >= 3600
              and (try (.rpo|tonumber) catch 0) < 3600
            )
          )
        ) | if . then "changed" else "" end
        end
    })
  | sort_by(.status, .group, .rpo_num, .friendly)
  | .[]
  | [.status, .rpi, .friendly, .health, (.rpo|tostring), .lastRP, .changed]
  | @tsv
' <<<"$CUR")

last_status=""
idx=1
while IFS=$'\t' read -r STATUS RPI FRIENDLY HEALTH RPO LASTRP CHG; do
  if [[ "$STATUS" != "$last_status" ]]; then
    [[ -n "$last_status" ]] && printf "\n"
    COUNT=$(jq -r --arg s "$STATUS" '.[$s] // 0' <<<"$STATUS_COUNTS_JSON")
    printf "%s== %s — %d item(s) ==%s\n" "$DIM" "$STATUS" "$COUNT" "$RESET"
    last_status="$STATUS"
    idx=1
  fi

  case "$HEALTH" in
    Normal) COLOR="$BLUE" ;;
    Warning) COLOR="$YELLOW" ;;
    Critical) COLOR="$RED" ;;
    *) COLOR="$DIM" ;;
  esac

  RPO_DISP="$RPO"
  if [[ "$HEALTH" == "Normal" && "$RPO" != "null" ]]; then
    RPO_DISP="${BOLDY}${RPO}${RESET}"
  fi

  flag=""
  [[ "$CHG" == "changed" ]] && flag="${MAGENTA}★ changed${RESET}"
  [[ "$CHG" == "new"     ]] && flag="${MAGENTA}★ new${RESET}"

  printf "%s%2d) %s | %s | Health:%s%s%s | Status:%s%s%s | RPO:%s%s | LastRP:%s  %s\n" \
    "$RESET" "$idx" "$FRIENDLY" "$RPI" \
    "$COLOR" "$HEALTH" "$RESET" \
    "$DIM" "$STATUS" "$RESET" \
    "$RPO_DISP" "$RESET" \
    "${LASTRP:-N/A}" \
    "$flag"
  ((idx++))
done <<< "$ROWS_TSV"

echo "$CUR" > "$LAST_JSON"
printf "\n%sSaved snapshot to:%s %s\n" "$DIM" "$RESET" "$LAST_JSON"

echo
echo "===== Summary ====="
mapfile -t ALL_STATUSES < <(jq -r 'keys[]' <<<"$STATUS_COUNTS_JSON" | sort)
for S in "${ALL_STATUSES[@]}"; do
  C=$(jq -r --arg s "$S" '.[$s] // 0' <<<"$STATUS_COUNTS_JSON")
  printf "  - %s: %d\n" "$S" "$C"
done
printf "  - Total Protected: %d\n" "$TOTAL_PROTECTED"
printf "  - Total Items: %d\n" "$TOTAL_ITEMS"

NUMERIC=$(jq -c '[ .[] | select((.rpo|tostring)!="null") | {rpi, friendly, rpo: (try (.rpo|tonumber) catch empty)} ]' <<<"$CUR")

if [[ "$(jq 'length' <<<"$NUMERIC")" -gt 0 ]]; then
  MIN_RPO=$(jq 'min_by(.rpo).rpo' <<<"$NUMERIC")
  MAX_RPO=$(jq 'max_by(.rpo).rpo' <<<"$NUMERIC")
  MIN_LINES=$(jq -r --argjson m "$MIN_RPO" '.[] | select(.rpo == $m) | "\(.friendly) [\(.rpi)]"' <<<"$NUMERIC")
  MAX_LINES=$(jq -r --argjson m "$MAX_RPO" '.[] | select(.rpo == $m) | "\(.friendly) [\(.rpi)]"' <<<"$NUMERIC")
  printf "  - Shortest RPO: %s (%s)\n" "$MIN_RPO" "$(secs_human "$MIN_RPO")"
  while IFS= read -r L; do [[ -n "$L" ]] && printf "      * %s\n" "$L"; done <<<"$MIN_LINES"
  printf "  - Longest RPO: %s (%s)\n" "$MAX_RPO" "$(secs_human "$MAX_RPO")"
  while IFS= read -r L; do [[ -n "$L" ]] && printf "      * %s\n" "$L"; done <<<"$MAX_LINES"
else
  echo "  - Shortest RPO: n/a"
  echo "  - Longest  RPO: n/a"
fi

rm -f "$TMP_JSONL"