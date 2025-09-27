#!/usr/bin/env bash
set -euo pipefail

# Colors (TTY-only)
if [[ -t 1 ]]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; DIM=$'\033[2m'; RESET=$'\033[0m'; BOLDY=$'\033[1;33m'
else
  RED=""; YELLOW=""; BLUE=""; DIM=""; RESET=""; BOLDY=""
fi

log(){ printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need az; need jq

# Load config
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

# Fetch inventory
log "Fetching protected items (inventory)…"
JS=$(az rest --method get --url "$BASE_RPI?api-version=$API_VERSION")

# Build ordered list: unhealthy first (Critical/Warning/Unknown), Normal last.
# Within groups, sort by numeric RPO (ascending; "null" last), then friendly name.
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
' <<<"$JS")

# Print with colors
idx=1
for LINE in "${ORDERED[@]}"; do
  IFS='|' read -r _ FRIENDLY NAME HEALTH RPO <<<"$LINE"

  case "$HEALTH" in
    Normal) COLOR="$BLUE" ;;
    Warning) COLOR="$YELLOW" ;;
    Critical) COLOR="$RED" ;;
    *) COLOR="$DIM" ;;
  esac

  # Highlight RPO if Normal + not null (RPO is in seconds)
  RPO_DISP="$RPO"
  if [[ "$HEALTH" == "Normal" && "$RPO" != "null" ]]; then
    RPO_DISP="${BOLDY}${RPO}${RESET}"
  fi

  printf "%s%d) %s | %s | Health:%s%s%s | RPO:%s%s\n" \
    "$RESET" "$idx" "$FRIENDLY" "$NAME" "$COLOR" "$HEALTH" "$RESET" "$RPO_DISP" "$RESET"

  ((idx++))
done

