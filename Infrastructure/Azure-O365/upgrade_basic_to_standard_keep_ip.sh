#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Upgrade Azure Public IPs from Basic -> Standard IN-PLACE (keeps the same IP if Static).

REQUIREMENTS:
  - Azure CLI
  - 'az account set' permissions for the subscription
  - CSV with headers NAME, LOCATION (others ignored)
  - Each IP must be Static before upgrade (script can switch Dynamic->Static if requested)

USAGE:
  ./upgrade_basic_to_standard_keep_ip.sh -s <subscription-id> -g <resource-group> -f <csv> [-n] [--force-static]

OPTIONS:
  -s  Subscription ID (e.g., 5a8f2111-71ad-42fb-a6e1-58d3676ca6ad)
  -g  Resource group containing the Public IPs (e.g., rg-appdev2)
  -f  Path to CSV exported list of public IPs
  -n  Dry-run (no changes, just print the plan)
  --force-static  If a Basic PIP is Dynamic, set it to Static BEFORE upgrade

WHAT IT DOES:
  1) Detect association (NIC / LB / Application Gateway / Bastion) and disassociate temporarily
  2) Ensure allocation method is Static (optional auto-fix with --force-static)
  3) Run 'az network public-ip update --sku Standard' to upgrade IN PLACE (IP retained)
  4) Reassociate to the original target

LIMITS / NOTES:
  - Public IP must be disassociated during the upgrade per Microsoft docs.
  - If the PIP is Dynamic and --force-static not provided, the script will skip it.
  - Upgrading is NOT reversible.
  - Most upgraded PIPs remain non-zonal (cannot attach to zonal/zone-redundant resources).
USAGE
}

DRY_RUN=0
FORCE_STATIC=0
SUB_ID=""
RG=""
CSV=""

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SUB_ID="$2"; shift 2;;
    -g) RG="$2"; shift 2;;
    -f) CSV="$2"; shift 2;;
    -n) DRY_RUN=1; shift;;
    --force-static) FORCE_STATIC=1; shift;;
    -h|--help) usage; exit 0;;
    *) args+=("$1"); shift;;
  esac
done

if [[ -z "${SUB_ID}" || -z "${RG}" || -z "${CSV}" ]]; then
  usage; exit 1
fi

echo "==> Setting subscription: ${SUB_ID}"
az account set --subscription "${SUB_ID}"

trim() { awk '{$1=$1;print}'; }

header="$(head -n1 "${CSV}")"
IFS=',' read -r -a cols <<< "${header}"
name_idx=-1
location_idx=-1
for i in "${!cols[@]}"; do
  col="${cols[$i]}"
  col_clean="$(echo "${col}" | tr -d '\r' | sed 's/^ *//; s/ *$//')"
  case "${col_clean}" in
    NAME) name_idx=$i ;;
    LOCATION) location_idx=$i ;;
  esac
done
if [[ $name_idx -lt 0 || $location_idx -lt 0 ]]; then
  echo "ERROR: CSV must contain NAME and LOCATION headers."; exit 2
fi

tail -n +2 "${CSV}" | while IFS=',' read -r -a fields; do
  NAME="$(echo "${fields[$name_idx]}" | tr -d '\r' | trim)"
  LOCATION="$(echo "${fields[$location_idx]}" | tr -d '\r' | trim)"
  [[ -z "${NAME}" ]] && continue

  echo ""
  echo "==== ${NAME} (${LOCATION}) ===="
  pip_json="$(az network public-ip show -g "${RG}" -n "${NAME}" --only-show-errors --output json || true)"
  if [[ -z "${pip_json}" || "${pip_json}" == "null" ]]; then
    echo "WARN: Not found ${RG}/${NAME} — skipping."; continue
  fi

  SKU="$(echo "${pip_json}" | jq -r '.sku.name // "Basic"')"
  ALLOC="$(echo "${pip_json}" | jq -r '.publicIPAllocationMethod // ""')"
  OLD_IP="$(echo "${pip_json}" | jq -r '.ipAddress // ""')"
  IPCONF_ID="$(echo "${pip_json}" | jq -r '.ipConfiguration.id // ""')"

  if [[ "${SKU}" == "Standard" ]]; then
    echo "Already Standard — skipping."; continue
  fi

  # Discover association
  ASSOC_TYPE="none"
  NIC_NAME=""; NIC_IPCONF=""
  LB_NAME=""; LB_FE=""
  AGW_NAME=""; AGW_FE=""
  BAS_NAME=""; BAS_IPCONF=""
  if [[ -n "${IPCONF_ID}" && "${IPCONF_ID}" != "null" ]]; then
    if [[ "${IPCONF_ID}" == *"/networkInterfaces/"* ]]; then
      ASSOC_TYPE="nic"
      NIC_NAME="$(echo "${IPCONF_ID}" | awk -F'/networkInterfaces/|/ipConfigurations/' '{print $2}')"
      NIC_IPCONF="$(echo "${IPCONF_ID}" | awk -F'/ipConfigurations/' '{print $2}')"
    elif [[ "${IPCONF_ID}" == *"/loadBalancers/"* ]]; then
      ASSOC_TYPE="lb"
      LB_NAME="$(echo "${IPCONF_ID}" | awk -F'/loadBalancers/|/frontendIPConfigurations/' '{print $2}')"
      LB_FE="$(echo "${IPCONF_ID}" | awk -F'/frontendIPConfigurations/' '{print $2}')"
    elif [[ "${IPCONF_ID}" == *"/applicationGateways/"* ]]; then
      ASSOC_TYPE="agw"
      AGW_NAME="$(echo "${IPCONF_ID}" | awk -F'/applicationGateways/|/frontendIPConfigurations/' '{print $2}')"
      AGW_FE="$(echo "${IPCONF_ID}" | awk -F'/frontendIPConfigurations/' '{print $2}')"
    elif [[ "${IPCONF_ID}" == *"/bastionHosts/"* ]]; then
      ASSOC_TYPE="bastion"
      BAS_NAME="$(echo "${IPCONF_ID}" | awk -F'/bastionHosts/|/ipConfigurations/' '{print $2}')"
      BAS_IPCONF="$(echo "${IPCONF_ID}" | awk -F'/ipConfigurations/' '{print $2}')"
    fi
  fi

  echo "Plan:"
  echo "  - Disassociate: ${ASSORC_TYPE:-$ASSOC_TYPE}"
  if [[ "${ALLOC}" == "Dynamic" ]]; then
    if [[ ${FORCE_STATIC} -eq 1 ]]; then
      echo "  - Switch allocation to Static (required for upgrade)"
    else
      echo "  - SKIP: Allocation is Dynamic; re-run with --force-static if you want me to change it."
      continue
    fi
  fi
  echo "  - Upgrade IN PLACE to Standard (IP should remain ${OLD_IP:-N/A})"
  echo "  - Reassociate to original target"

  if [[ ${DRY_RUN} -eq 1 ]]; then
    continue
  fi

  # Disassociate
  if [[ "${ASSOC_TYPE}" == "nic" ]]; then
    echo "Disassociating NIC ${NIC_NAME}/${NIC_IPCONF} ..."
    az network nic ip-config update           --nic-name "${NIC_NAME}"           --name "${NIC_IPCONF}"           --resource-group "${RG}"           --remove publicIpAddress           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "lb" ]]; then
    echo "Disassociating LB ${LB_NAME}/${LB_FE} ..."
    az network lb frontend-ip update           --lb-name "${LB_NAME}"           --name "${LB_FE}"           --resource-group "${RG}"           --public-ip-address ""           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "agw" ]]; then
    echo "Disassociating App Gateway ${AGW_NAME}/${AGW_FE} ..."
    az network application-gateway frontend-ip update           --gateway-name "${AGW_NAME}"           --name "${AGW_FE}"           --resource-group "${RG}"           --public-ip-address ""           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "bastion" ]]; then
    echo "Disassociating Bastion ${BAS_NAME}/${BAS_IPCONF} ..."
    az network bastion ip-config update           --name "${BAS_IPCONF}"           --bastion-name "${BAS_NAME}"           --resource-group "${RG}"           --public-ip-address ""           --only-show-errors 1>/dev/null
  else
    echo "No association detected."
  fi

  # Ensure Static if requested
  if [[ "${ALLOC}" == "Dynamic" && ${FORCE_STATIC} -eq 1 ]]; then
    echo "Setting allocation method to Static ..."
    az network public-ip update           -g "${RG}" -n "${NAME}"           --allocation-method Static           --only-show-errors 1>/dev/null
  fi

  echo "Upgrading to Standard (in place) ..."
  az network public-ip update         -g "${RG}" -n "${NAME}"         --sku Standard         --only-show-errors 1>/dev/null

  NEW_IP="$(az network public-ip show -g "${RG}" -n "${NAME}" --query ipAddress -o tsv)"
  echo "Upgrade complete: ${NAME} (IP before: ${OLD_IP:-N/A}, after: ${NEW_IP:-N/A})"

  # Reassociate
  if [[ "${ASSOC_TYPE}" == "nic" ]]; then
    echo "Reassociating NIC ${NIC_NAME}/${NIC_IPCONF} ..."
    az network nic ip-config update           --nic-name "${NIC_NAME}"           --name "${NIC_IPCONF}"           --resource-group "${RG}"           --public-ip-address "${NAME}"           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "lb" ]]; then
    echo "Reassociating LB ${LB_NAME}/${LB_FE} ..."
    az network lb frontend-ip update           --lb-name "${LB_NAME}"           --name "${LB_FE}"           --resource-group "${RG}"           --public-ip-address "${NAME}"           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "agw" ]]; then
    echo "Reassociating App Gateway ${AGW_NAME}/${AGW_FE} ..."
    az network application-gateway frontend-ip update           --gateway-name "${AGW_NAME}"           --name "${AGW_FE}"           --resource-group "${RG}"           --public-ip-address "${NAME}"           --only-show-errors 1>/dev/null
  elif [[ "${ASSOC_TYPE}" == "bastion" ]]; then
    echo "Reassociating Bastion ${BAS_NAME}/${BAS_IPCONF} ..."
    az network bastion ip-config update           --name "${BAS_IPCONF}"           --bastion-name "${BAS_NAME}"           --resource-group "${RG}"           --public-ip-address "${NAME}"           --only-show-errors 1>/dev/null
  fi

  echo "DONE: ${NAME}"
done

echo ""
echo "All rows processed."
