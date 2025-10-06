#!/usr/bin/env bash
set -euo pipefail

# find-active-asr-vaults.sh
# Scans Recovery Services vaults listed in a CSV and emits config JSON for those with ASR replicated items.
#
# CSV columns required (header row expected):
# NAME,TYPE,SECURITY LEVEL,RESOURCE GROUP,LOCATION,SUBSCRIPTION
#
# Usage:
#   ./find-active-asr-vaults.sh -c ./Azurevaults.csv -o ./asr-configs [--dry-run] [--api 2024-04-01] [--login-mode {default|identity}]
#
# Examples:
#   ./find-active-asr-vaults.sh -c ./Azurevaults.csv -o ./asr-configs --dry-run
#   ./find-active-asr-vaults.sh -c ./Azurevaults.csv -o ./asr-configs --login-mode identity
#
# Notes:
# - "Active" means vault has >= 1 replicationProtectedItems.
# - Uses Azure REST via `az rest` against Microsoft.RecoveryServices Site Recovery endpoints.
# - jq is required for JSON parsing: https://stedolan.github.io/jq/
# - Azure CLI context is switched per subscription found by *name* in the CSV.
#
# Output:
#   <output>/asr-config-<vault>.json   # per active vault
#   <output>/asr-vault-scan-summary.csv
#   <output>/asr-vault-scan-summary.json
#
ASR_API_DEFAULT="2024-04-01"

CSV_PATH=""
OUT_DIR="./asr-configs"
DRY_RUN="false"
ASR_API="$ASR_API_DEFAULT"
LOGIN_MODE="default"  # or "identity" for managed identity

function usage() {
  cat <<USAGE
Usage: $0 -c <csv> [-o <outdir>] [--dry-run] [--api <version>] [--login-mode <default|identity>]

Options:
  -c, --csv           Path to Azurevaults.csv (required)
  -o, --out           Output folder (default: ./asr-configs)
      --dry-run       Do not write files, just scan and print
      --api           ASR API version (default: ${ASR_API_DEFAULT})
      --login-mode    Azure login mode: default | identity  (default: default)

Env:
  You must already be logged in with 'az login' (or 'az login --identity' for managed identity).
USAGE
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--csv) CSV_PATH="$2"; shift 2;;
    -o|--out) OUT_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift 1;;
    --api) ASR_API="$2"; shift 2;;
    --login-mode) LOGIN_MODE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ -z "${CSV_PATH}" ]]; then
  echo "[ERROR] CSV path is required."
  usage
  exit 1
fi

if [[ ! -f "${CSV_PATH}" ]]; then
  echo "[ERROR] CSV not found at: ${CSV_PATH}" >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "[ERROR] Azure CLI 'az' is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] 'jq' is required." >&2
  exit 1
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  mkdir -p "${OUT_DIR}"
fi

SUMMARY_JSON="$(mktemp)"
echo "[]" > "${SUMMARY_JSON}"

function add_summary() {
  local subName="$1"
  local subId="$2"
  local rg="$3"
  local vault="$4"
  local loc="$5"
  local active="$6"
  local count="$7"
  local note="$8"

  local newitem
  newitem="$(jq -n --arg sn "$subName" --arg sid "$subId" --arg rg "$rg" --arg v "$vault" \
                  --arg loc "$loc" --argjson act "$active" --argjson cnt "$count" --arg note "$note" \
                  '{SubscriptionName:$sn, SubscriptionId:$sid, ResourceGroup:$rg, VaultName:$v, Location:$loc, Active:$act, ReplicatedItems:$cnt, Note:$note}')" || true

  jq ". + [${newitem}]" "${SUMMARY_JSON}" > "${SUMMARY_JSON}.tmp" && mv "${SUMMARY_JSON}.tmp" "${SUMMARY_JSON}"
}

function set_context_for_subscription_name() {
  local subName="$1"

  # Resolve subscription by name (include disabled to avoid warning; we'll still set context only if found)
  local sub
  sub="$(az account list --all --query "[?name=='${subName}']|[0]" -o json)"
  if [[ "${sub}" == "null" || -z "${sub}" ]]; then
    echo "[WARN] Subscription not visible: ${subName}"
    echo ""
    return 0
  fi

  local subId
  subId="$(jq -r '.id' <<<"${sub}")"

  case "${LOGIN_MODE}" in
    identity)
      az account set --subscription "${subId}" >/dev/null
      ;;
    default)
      az account set --subscription "${subId}" >/dev/null
      ;;
    *)
      echo "[WARN] Unknown login mode '${LOGIN_MODE}', defaulting to standard account set."
      az account set --subscription "${subId}" >/dev/null
      ;;
  esac

  echo "${subId}"
}

function list_fabrics() {
  local subId="$1" rg="$2" vault="$3"
  local url="https://management.azure.com/subscriptions/${subId}/resourceGroups/${rg}/providers/Microsoft.RecoveryServices/vaults/${vault}/replicationFabrics?api-version=${ASR_API}"
  az rest --method get --url "${url}" -o json --only-show-errors
}

function list_containers() {
  local subId="$1" rg="$2" vault="$3" fabricName="$4"
  local url="https://management.azure.com/subscriptions/${subId}/resourceGroups/${rg}/providers/Microsoft.RecoveryServices/vaults/${vault}/replicationFabrics/${fabricName}/replicationProtectionContainers?api-version=${ASR_API}"
  az rest --method get --url "${url}" -o json --only-show-errors
}

function list_rpis() {
  local subId="$1" rg="$2" vault="$3" fabricName="$4" containerName="$5"
  local url="https://management.azure.com/subscriptions/${subId}/resourceGroups/${rg}/providers/Microsoft.RecoveryServices/vaults/${vault}/replicationFabrics/${fabricName}/replicationProtectionContainers/${containerName}/replicationProtectedItems?api-version=${ASR_API}"
  az rest --method get --url "${url}" -o json --only-show-errors
}

# Validate JSON helper (returns 0 if valid JSON, non-zero otherwise)
function is_json() {
  jq -e . >/dev/null 2>&1
}

# Sanitize filename
function safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9\-]+/-/g'
}

# Read CSV lines (skip header). Assumes no embedded commas in fields.
# Columns: NAME,TYPE,SECURITY LEVEL,RESOURCE GROUP,LOCATION,SUBSCRIPTION
tail -n +2 "${CSV_PATH}" | while IFS=, read -r NAME TYPE SECLEVEL RG LOC SUB; do
  # Trim surrounding quotes and whitespace
  NAME="${NAME%\"}"; NAME="${NAME#\"}"; NAME="${NAME#"${NAME%%[![:space:]]*}"}"; NAME="${NAME%"${NAME##*[![:space:]]}"}"
  RG="${RG%\"}"; RG="${RG#\"}"; RG="${RG#"${RG%%[![:space:]]*}"}"; RG="${RG%"${RG##*[![:space:]]}"}"
  SUB="${SUB%\"}"; SUB="${SUB#\"}"; SUB="${SUB#"${SUB%%[![:space:]]*}"}"; SUB="${SUB%"${SUB##*[![:space:]]}"}"
  LOC="${LOC%\"}"; LOC="${LOC#\"}"; LOC="${LOC#"${LOC%%[![:space:]]*}"}"; LOC="${LOC%"${LOC##*[![:space:]]}"}"
  TYPE="${TYPE%\"}"; TYPE="${TYPE#\"}"
  SECLEVEL="${SECLEVEL%\"}"; SECLEVEL="${SECLEVEL#\"}"

  [[ -z "${NAME}" || -z "${RG}" || -z "${SUB}" ]] && continue

  echo "[VAULT] ${NAME} | RG=${RG} | SUB=${SUB}"

  subId="$(set_context_for_subscription_name "${SUB}")"
  if [[ -z "${subId}" ]]; then
    add_summary "${SUB}" "" "${RG}" "${NAME}" "${LOC}" "false" "0" "Subscription not found/visible"
    continue
  fi

  # List fabrics
  fabrics_json="$(list_fabrics "${subId}" "${RG}" "${NAME}" || true)"
  if ! is_json <<<"${fabrics_json}"; then
    echo "  [WARN] Fabrics API returned non-JSON (possible 403/404)."
    add_summary "${SUB}" "${subId}" "${RG}" "${NAME}" "${LOC}" "false" "0" "Fabric list error"
    continue
  fi

  fabrics_count="$(jq '(.value // []) | length' <<<"${fabrics_json}")"
  if [[ "${fabrics_count}" -eq 0 ]]; then
    echo "  [SKIP] No fabrics."
    add_summary "${SUB}" "${subId}" "${RG}" "${NAME}" "${LOC}" "false" "0" ""
    continue
  fi

  total_rpi=0
  fabrics_obj="[]"

  for row in $(jq -r '.value[] | @base64' <<<"${fabrics_json}"); do
    _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
    fabricName="$(_jq '.name')"
    fabricFriendly="$(_jq '.properties.friendlyName // .name')"

    echo "  [FAB ] ${fabricFriendly} (${fabricName})"
    containers_json="$(list_containers "${subId}" "${RG}" "${NAME}" "${fabricName}" || true)"
    if ! is_json <<<"${containers_json}"; then
      echo "    [WARN] Containers API returned non-JSON. Skipping containers."
      containers_count=0
    else
      containers_count="$(jq '(.value // []) | length' <<<"${containers_json}")"
    fi
    container_objs="[]"

    if [[ "${containers_count}" -gt 0 ]]; then
      for crow in $(jq -r '.value[] | @base64' <<<"${containers_json}"); do
        _cjq() { echo "${crow}" | base64 --decode | jq -r "${1}"; }
        containerName="$(_cjq '.name')"
        containerFriendly="$(_cjq '.properties.friendlyName // .name')"

        rpi_json="$(list_rpis "${subId}" "${RG}" "${NAME}" "${fabricName}" "${containerName}" || true)"
        if ! is_json <<<"${rpi_json}"; then
          echo "      [WARN] RPIs API returned non-JSON. Treating as zero."
          rpi_count=0
        else
          rpi_count="$(jq '(.value // []) | length' <<<"${rpi_json}")"
        fi
        total_rpi=$(( total_rpi + rpi_count ))
        echo "    [CONT] ${containerFriendly} (${containerName}) RPIs=${rpi_count}"

        container_obj="$(jq -n --arg name "${containerFriendly}" --arg id "/${fabricName}/${containerName}" --argjson count "${rpi_count}" \
                        '{name:$name, id:$id, replicatedItemCount:$count}')"
        container_objs="$(jq ". + [${container_obj}]" <<<"${container_objs}")"
      done
    fi

    fabric_obj="$(jq -n --arg name "${fabricFriendly}" --arg id "${fabricName}" --argjson pcs "${container_objs}" \
                  '{name:$name, id:$id, protectionContainers:$pcs}')"
    fabrics_obj="$(jq ". + [${fabric_obj}]" <<<"${fabrics_obj}")"
  done

  is_active="false"
  if [[ "${total_rpi}" -gt 0 ]]; then
    is_active="true"
    echo "  [OK  ] Active vault. RPIs=${total_rpi}"
    cfg="$(jq -n \
        --arg sid "${subId}" \
        --arg sname "${SUB}" \
        --arg rg "${RG}" \
        --arg vault "${NAME}" \
        --arg loc "${LOC}" \
        --arg gen "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson total "${total_rpi}" \
        --argjson fabrics "${fabrics_obj}" \
        '{subscriptionId:$sid, subscriptionName:$sname, resourceGroup:$rg, vaultName:$vault, location:$loc, replicatedItemTotal:$total, fabrics:$fabrics, generatedAtUtc:$gen}')"

    fname="asr-config-$(safe_name "${NAME}").json"
    fpath="${OUT_DIR}/${fname}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "  [DRY] Would write ${fpath}"
    else
      printf "%s\n" "${cfg}" > "${fpath}"
      echo "  [OUT ] ${fpath}"
    fi
  else
    echo "  [SKIP] No replicated items."
  fi

  add_summary "${SUB}" "${subId}" "${RG}" "${NAME}" "${LOC}" "${is_active}" "${total_rpi}" ""

done

# Emit summary files
summary_csv="${OUT_DIR}/asr-vault-scan-summary.csv"
summary_json="${OUT_DIR}/asr-vault-scan-summary.json"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY] Would write ${summary_csv} and ${summary_json}"
else
  # JSON
  jq '.' "${SUMMARY_JSON}" > "${summary_json}"
  # CSV
  jq -r '(["SubscriptionName","SubscriptionId","ResourceGroup","VaultName","Location","Active","ReplicatedItems","Note"]),
         (.[] | [ .SubscriptionName, .SubscriptionId, .ResourceGroup, .VaultName, .Location, (.Active|tostring), (.ReplicatedItems|tostring), .Note ]) | @csv' \
      "${SUMMARY_JSON}" > "${summary_csv}"
  echo "[DONE] Summary written to:"
  echo "  ${summary_csv}"
  echo "  ${summary_json}"
fi

# Cleanup
rm -f "${SUMMARY_JSON}" || true
