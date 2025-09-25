#!/usr/bin/env bash
# Azure VNet Gateway Backup & (optional) Recreate with new Public IP
# Works with az CLI 2.76.0+ ; uses REST for PSK reads to avoid CLI quirks.

############################################
# Config: load from ./config.txt if present
# (Lines like: RG=rg-spirits-coldconvert, GW=vng-datto-lab, NEW_PIP=pip-vng-new, NEW_PIP2=pip-vng-new-b if active-active)
############################################
CONFIG_FILE="./config.txt"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Fallback prompts if not set in config.txt
RG="${RG:-}"
GW="${GW:-}"
NEW_PIP="${NEW_PIP:-}"
NEW_PIP2="${NEW_PIP2:-}"  # only needed for active-active

############################################
# Helpers
############################################
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log()  { echo "[$(timestamp)] $*"; }
warn() { echo "[$(timestamp)] WARNING: $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { warn "Missing dependency: $1"; return 1; }; }

pretty_json() {
  if command -v jq >/dev/null 2>&1; then jq -r '.'; else cat; fi
}

get_psk() {
  local rg="$1" conn="$2"
  local id
  id=$(az network vpn-connection show -g "$rg" -n "$conn" --query id -o tsv 2>/dev/null) || return 1
  az rest --method get \
    --url "https://management.azure.com${id}/sharedKey?api-version=2023-09-01" \
    --query value -o tsv 2>/dev/null
}

############################################
# Input sanity (prompt if needed)
############################################
if [ -z "$RG" ];  then read -rp "Resource Group (RG): " RG; fi
if [ -z "$GW" ];  then read -rp "Gateway Name (GW): " GW; fi

log "Validating Azure context..."
az account show >/dev/null 2>&1 || { warn "Not logged in. Run: az login"; exit 1; }

############################################
# Pull gateway snapshot & properties
############################################
BACKUP_DIR="gw-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR/conn-json" "$BACKUP_DIR/psk"

log "Reading gateway $GW in $RG ..."
if ! az network vnet-gateway show -g "$RG" -n "$GW" -o json > "$BACKUP_DIR/gateway.json"; then
  warn "Cannot read gateway. Check RG/GW names and az account set."
  exit 1
fi

# Summarize key props
if command -v jq >/dev/null 2>&1; then
  jq '{
    name: .name,
    id: .id,
    location: .location,
    sku: .sku.name,
    gatewayType: .gatewayType,
    vpnType: .vpnType,
    activeActive: .activeActive,
    asn: .bgpSettings.asn,
    vnetId: (.ipConfigurations[0].subnet.id | split("/subnets/")[0]),
    subnetId: .ipConfigurations[0].subnet.id
  }' "$BACKUP_DIR/gateway.json" | tee "$BACKUP_DIR/gateway-summary.json" | pretty_json
else
  cat "$BACKUP_DIR/gateway.json"
fi

GW_ID=$(az network vnet-gateway show -g "$RG" -n "$GW" --query id -o tsv)
LOC=$(az network vnet-gateway show -g "$RG" -n "$GW" --query location -o tsv)
SKU=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "sku.name" -o tsv)
GTYPE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query gatewayType -o tsv)
VTYPE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query vpnType -o tsv)
ACTIVE_ACTIVE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query activeActive -o tsv)
ASN=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "bgpSettings.asn" -o tsv 2>/dev/null)
SUBNET_ID=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "ipConfigurations[0].subnet.id" -o tsv)
VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/subnets/' '{print $1}')

ENABLE_BGP=false; [ -n "$ASN" ] && [ "$ASN" != "None" ] && ENABLE_BGP=true

############################################
# Discover all connections referencing this gateway
############################################
log "Discovering vpn-connections that reference this gateway..."
CONNS=$({
  az network vpn-connection list -g "$RG" \
    --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${GW_ID}'].name" -o tsv
  az network vpn-connection list -g "$RG" \
    --query "[?virtualNetworkGateway2 && virtualNetworkGateway2.id=='${GW_ID}'].name" -o tsv
} | sort -u)

if [ -z "$CONNS" ]; then
  warn "No connections found that reference $GW."
else
  log "Connections:"
  printf ' - %s\n' $CONNS
fi
printf "%s\n" $CONNS > "$BACKUP_DIR/connections.txt"

############################################
# Menu
############################################
echo
echo "Choose an action:"
echo "  1) Backup only"
echo "  2) Backup and recreate gateway with new Public IP(s)"
read -rp "Enter 1 or 2: " CHOICE
echo

############################################
# BACKUP (common)
############################################
log "Backing up connection JSON + PSKs to $BACKUP_DIR ..."
for C in $CONNS; do
  log "  * $C"
  az network vpn-connection show -g "$RG" -n "$C" -o json > "$BACKUP_DIR/conn-json/$C.json" || warn "    - could not export JSON"
  PSK=$(get_psk "$RG" "$C")
  if [ -n "$PSK" ]; then
    echo "$PSK" > "$BACKUP_DIR/psk/$C.psk" || warn "    - could not write PSK file"
  else
    warn "    - could not read PSK (need permission Microsoft.Network/connections/sharedKeys/read)"
  fi
done

# Print a concise connection summary
if command -v jq >/dev/null 2>&1 && ls "$BACKUP_DIR"/conn-json/*.json >/dev/null 2>&1; then
  log "Connection summaries:"
  jq -s 'map({
    name: .name,
    connectionType: .connectionType,
    status: .connectionStatus,
    enableBgp: (.enableBgp // false),
    usePolicyBasedTrafficSelectors: (.usePolicyBasedTrafficSelectors // false),
    remote: (if .localNetworkGateway2? then
      { type:"LocalNetworkGateway", id:.localNetworkGateway2.id, peerAddress:.localNetworkGateway2.gatewayIpAddress }
     else
      { type:"VirtualNetworkGateway", id:.virtualNetworkGateway2.id }
     end),
    ipsecPolicies: (.ipsecPolicies // [])
  })' "$BACKUP_DIR"/conn-json/*.json | tee "$BACKUP_DIR/connections-summary.json" | pretty_json
fi

if [ "$CHOICE" != "2" ]; then
  log "Backup complete. No changes were made."
  log "Files:"
  echo "  - $BACKUP_DIR/gateway-summary.json"
  echo "  - $BACKUP_DIR/connections-summary.json"
  echo "  - $BACKUP_DIR/conn-json/*.json"
  echo "  - $BACKUP_DIR/psk/*.psk"
  exit 0
fi

############################################
# RECREATE FLOW (Option 2)
############################################

# Collect/confirm target PIP(s)
if [ "$ACTIVE_ACTIVE" = "true" ]; then
  log "Active-Active gateway detected: requires TWO Public IPs."
  if [ -z "$NEW_PIP" ];  then read -rp "Enter NEW_PIP (IP #1 name): " NEW_PIP; fi
  if [ -z "$NEW_PIP2" ]; then read -rp "Enter NEW_PIP2 (IP #2 name): " NEW_PIP2; fi
else
  if [ -z "$NEW_PIP" ];  then read -rp "Enter NEW_PIP (Public IP name): " NEW_PIP; fi
fi

# Create PIP(s) if needed
create_pip_if_missing () {
  local pip="$1"
  if ! az network public-ip show -g "$RG" -n "$pip" >/dev/null 2>&1; then
    log "Creating Public IP $pip ..."
    az network public-ip create -g "$RG" -n "$pip" --sku Standard --allocation-method Static --location "$LOC" >/dev/null || warn "Failed to create $pip"
  fi
  local ip; ip=$(az network public-ip show -g "$RG" -n "$pip" --query ipAddress -o tsv 2>/dev/null)
  log "  $pip => $ip"
}

log "Ensuring target Public IP resource(s) exist (Standard, Static):"
create_pip_if_missing "$NEW_PIP"
[ "$ACTIVE_ACTIVE" = "true" ] && create_pip_if_missing "$NEW_PIP2"

echo
log "!!! DESTRUCTIVE STEP WARNING !!!"
echo "This will:"
echo "  - Delete the vpn-connection objects listed above"
echo "  - Delete the VNet gateway $GW"
echo "  - Recreate it with the new Public IP(s)"
echo "  - Recreate the connections (same names, PSKs, policies)"
read -rp "Type RECREATE to proceed: " CONFIRM
[ "$CONFIRM" != "RECREATE" ] && { warn "Aborted by user."; exit 1; }

# Delete connections
if [ -n "$CONNS" ]; then
  log "Deleting existing connections ..."
  for C in $CONNS; do
    log "  - $C"
    az network vpn-connection delete -g "$RG" -n "$C" --yes || warn "    - delete failed (continuing)"
  done
fi

# Delete and recreate gateway
log "Deleting gateway $GW ..."
az network vnet-gateway delete -g "$RG" -n "$GW" || warn "Gateway delete returned error (continuing)"

log "Recreating gateway $GW with new PIP(s) ..."
if [ "$ACTIVE_ACTIVE" = "true" ]; then
  az network vnet-gateway create \
    -g "$RG" -n "$GW" \
    --location "$LOC" \
    --public-ip-addresses "$NEW_PIP" "$NEW_PIP2" \
    --vnet "$VNET_NAME" \
    --gateway-type "$GTYPE" \
    --vpn-type "$VTYPE" \
    --sku "$SKU" \
    --enable-bgp $ENABLE_BGP \
    || warn "Gateway create failed"
else
  az network vnet-gateway create \
    -g "$RG" -n "$GW" \
    --location "$LOC" \
    --public-ip-addresses "$NEW_PIP" \
    --vnet "$VNET_NAME" \
    --gateway-type "$GTYPE" \
    --vpn-type "$VTYPE" \
    --sku "$SKU" \
    --enable-bgp $ENABLE_BGP \
    || warn "Gateway create failed"
fi

log "Waiting for gateway provisioningState..."
for i in {1..60}; do
  state=$(az network vnet-gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null)
  [ "$state" = "Succeeded" ] && break
  sleep 15
done
log "Gateway provisioningState: ${state:-unknown}"

# Recreate connections
log "Recreating connections ..."
for C in $CONNS; do
  CJ="$BACKUP_DIR/conn-json/$C.json"
  PSK_FILE="$BACKUP_DIR/psk/$C.psk"
  [ ! -s "$CJ" ] && { warn "  ! Missing JSON for $C — skipping"; continue; }

  EN_BGP=$(jq -r '.enableBgp // false' "$CJ" 2>/dev/null)
  USE_POLICY=$(jq -r '.usePolicyBasedTrafficSelectors // false' "$CJ" 2>/dev/null)
  LNG_ID=$(jq -r '.localNetworkGateway2.id // empty' "$CJ" 2>/dev/null)
  VNG2_ID=$(jq -r '.virtualNetworkGateway2.id // empty' "$CJ" 2>/dev/null)
  CONN_TYPE=$(jq -r '.connectionType' "$CJ" 2>/dev/null)
  PSK=""
  [ -s "$PSK_FILE" ] && PSK=$(cat "$PSK_FILE")

  if [ -n "$LNG_ID" ]; then
    log "  + $C (S2S to LocalNetworkGateway)"
    az network vpn-connection create \
      -g "$RG" -n "$C" \
      --vnet-gateway1 "$GW" \
      --local-gateway2 "$LNG_ID" \
      ${PSK:+--shared-key "$PSK"} \
      --enable-bgp $EN_BGP \
      $( [ "$USE_POLICY" = "true" ] && echo --use-policy-based-traffic-selectors ) \
      >/dev/null || warn "    - create failed"
  elif [ -n "$VNG2_ID" ]; then
    log "  + $C (VNet-to-VNet)"
    az network vpn-connection create \
      -g "$RG" -n "$C" \
      --vnet-gateway1 "$GW" \
      --vnet-gateway2 "$VNG2_ID" \
      ${PSK:+--shared-key "$PSK"} \
      --enable-bgp $EN_BGP \
      >/dev/null || warn "    - create failed"
  else
    warn "  ! Could not determine remote side for $C — inspect $CJ"
    continue
  fi

  # Reapply custom IPsec policies if any
  POLCOUNT=$(jq -r '(.ipsecPolicies | length) // 0' "$CJ" 2>/dev/null)
  if [ "$POLCOUNT" -gt 0 ]; then
    for idx in $(seq 0 $((POLCOUNT-1))); do
      IKE=$(jq -r ".ipsecPolicies[$idx].ikeEncryption" "$CJ")
      IKI=$(jq -r ".ipsecPolicies[$idx].ikeIntegrity" "$CJ")
      DHG=$(jq -r ".ipsecPolicies[$idx].dhGroup" "$CJ")
      SAe=$(jq -r ".ipsecPolicies[$idx].ipsecEncryption" "$CJ")
      SAi=$(jq -r ".ipsecPolicies[$idx].ipsecIntegrity" "$CJ")
      PFS=$(jq -r ".ipsecPolicies[$idx].pfsGroup" "$CJ")
      LIF=$(jq -r ".ipsecPolicies[$idx].saLifeTimeSeconds" "$CJ")
      log "    - Applying IPsec policy #$((idx+1)) to $C"
      az network vpn-connection ipsec-policy add \
        -g "$RG" -n "$C" \
        --ike-encryption "$IKE" --ike-integrity "$IKI" --dh-group "$DHG" \
        --ipsec-encryption "$SAe" --ipsec-integrity "$SAi" --pfs-group "$PFS" \
        --sa-lifetime "$LIF" >/dev/null || warn "      * policy add failed"
    done
  fi
done

log "Recreate complete. Verify connectionStatus:"
az network vpn-connection list -g "$RG" --query "[].{name:name,status:connectionStatus}" -o table
echo
log "All done. Backups at: $BACKUP_DIR"
