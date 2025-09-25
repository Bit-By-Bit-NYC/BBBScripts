#!/usr/bin/env bash
# Azure VNet Gateway Backup / Recreate / Restore with new Public IP(s)
# Compatible with Azure CLI 2.76.0

# ---------- Config (config.txt is optional) ----------
CONFIG_FILE="./config.txt"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
RG="${RG:-}"; GW="${GW:-}"; NEW_PIP="${NEW_PIP:-}"; NEW_PIP2="${NEW_PIP2:-}"

# ---------- Helpers ----------
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(timestamp)] $*"; }
warn(){ echo "[$(timestamp)] WARNING: $*" >&2; }
pretty_json(){ command -v jq >/dev/null 2>&1 && jq -r '.' || cat; }

get_psk(){ # PSK via REST (works across CLI versions)
  local rg="$1" conn="$2" id
  id=$(az network vpn-connection show -g "$rg" -n "$conn" --query id -o tsv 2>/dev/null) || return 1
  az rest --method get \
    --url "https://management.azure.com${id}/sharedKey?api-version=2023-09-01" \
    --query value -o tsv 2>/dev/null
}

create_pip_if_missing(){
  local pip="$1" loc="$2"
  if ! az network public-ip show -g "$RG" -n "$pip" >/dev/null 2>&1; then
    log "Creating Public IP $pip (Standard/Static) ..."
    az network public-ip create -g "$RG" -n "$pip" --sku Standard --allocation-method Static --location "$loc" >/dev/null || warn "Failed to create $pip"
  fi
  local ip; ip=$(az network public-ip show -g "$RG" -n "$pip" --query ipAddress -o tsv 2>/dev/null)
  log "  $pip => ${ip:-<allocating>}"
}

kb_to_bytes(){ # echo bytes for given kilobytes (int); 0 stays 0
  local kb="${1:-0}"; echo $(( kb * 1024 ))
}

# ---------- Inputs ----------
[ -z "$RG" ] && read -rp "Resource Group (RG): " RG
[ -z "$GW" ] && read -rp "Gateway Name (GW): " GW
az account show >/dev/null 2>&1 || { warn "Not logged in. Run: az login"; exit 1; }

# ---------- Snapshot current gateway (if it exists) ----------
BACKUP_DIR="gw-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR/conn-json" "$BACKUP_DIR/psk"

log "Reading gateway $GW in $RG ..."
if az network vnet-gateway show -g "$RG" -n "$GW" -o json > "$BACKUP_DIR/gateway.json" 2>/dev/null; then
  if command -v jq >/dev/null 2>&1; then
    jq '{
      name:.name, id:.id, location:.location, sku:.sku.name,
      gatewayType:.gatewayType, vpnType:.vpnType, activeActive:.activeActive,
      asn:.bgpSettings.asn,
      vnetId:(.ipConfigurations[0].subnet.id|split("/subnets/")[0]),
      subnetId:.ipConfigurations[0].subnet.id
    }' "$BACKUP_DIR/gateway.json" | tee "$BACKUP_DIR/gateway-summary.json" | pretty_json
  else
    cat "$BACKUP_DIR/gateway.json"
  fi
  GW_EXISTS=true
else
  warn "Gateway not found (may be deleted already). Restore mode will still work."
  GW_EXISTS=false
fi

if [ "$GW_EXISTS" = true ]; then
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

  # ---------- SKU guard (Basic → prompt to VpnGw1/1AZ) ----------
  TARGET_SKU="$SKU"
  if [ "$SKU" = "Basic" ]; then
    warn "Gateway SKU is 'Basic' (not compatible with Standard PIP)."
    DEF="VpnGw1"; [ "$ACTIVE_ACTIVE" = "true" ] && DEF="VpnGw1AZ"
    read -rp "Target SKU [${DEF}]: " INPUT_SKU
    TARGET_SKU="${INPUT_SKU:-$DEF}"
    log "Will recreate gateway with TARGET_SKU=$TARGET_SKU."
  else
    log "Current SKU ($SKU) is compatible with Standard PIP."
    TARGET_SKU="$SKU"
  fi
fi

# ---------- Discover connections (if gateway exists) ----------
if [ "$GW_EXISTS" = true ]; then
  log "Discovering vpn-connections that reference this gateway..."
  CONNS=$({
    az network vpn-connection list -g "$RG" \
      --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${GW_ID}'].name" -o tsv
    az network vpn-connection list -g "$RG" \
      --query "[?virtualNetworkGateway2 && virtualNetworkGateway2.id=='${GW_ID}'].name" -o tsv
  } | sort -u)

  if [ -z "$CONNS" ]; then
    warn "No connections reference $GW."
  else
    log "Connections:"; printf ' - %s\n' $CONNS
  fi
  printf "%s\n" $CONNS > "$BACKUP_DIR/connections.txt"
fi

# ---------- Menu ----------
echo
echo "Choose an action:"
echo "  1) Backup only"
echo "  2) Backup and recreate gateway with new Public IP(s)"
echo "  3) Restore from a previous backup (recreate gateway + connections)"
read -rp "Enter 1, 2, or 3: " CHOICE
echo

# ---------- Option 1 & common backup ----------
backup_now(){
  log "Backing up connection JSON + PSKs to $BACKUP_DIR ..."
  for C in $CONNS; do
    log "  * $C"
    az network vpn-connection show -g "$RG" -n "$C" -o json > "$BACKUP_DIR/conn-json/$C.json" || warn "    - JSON export failed"
    PSK=$(get_psk "$RG" "$C"); if [ -n "$PSK" ]; then echo "$PSK" > "$BACKUP_DIR/psk/$C.psk"; else warn "    - PSK read failed (need Microsoft.Network/connections/sharedKeys/read)"; fi
  done

  if command -v jq >/dev/null 2>&1 && ls "$BACKUP_DIR"/conn-json/*.json >/dev/null 2>&1; then
    log "Connection summaries:"
    jq -s 'map({
      name:.name, connectionType:.connectionType, status:.connectionStatus,
      enableBgp:(.enableBgp // false), usePolicyBasedTrafficSelectors:(.usePolicyBasedTrafficSelectors // false),
      remote:(if .localNetworkGateway2? then {type:"LocalNetworkGateway",id:.localNetworkGateway2.id,peerAddress:.localNetworkGateway2.gatewayIpAddress} else {type:"VirtualNetworkGateway",id:.virtualNetworkGateway2.id} end),
      ipsecPolicies:(.ipsecPolicies // [])
    })' "$BACKUP_DIR"/conn-json/*.json | tee "$BACKUP_DIR/connections-summary.json" | pretty_json
  fi
}

if [ "$CHOICE" = "1" ]; then
  if [ "$GW_EXISTS" = true ]; then backup_now; fi
  log "Backup complete. No changes made."; exit 0
fi

# ---------- Option 2: Backup + Recreate from current ----------
if [ "$CHOICE" = "2" ]; then
  if [ "$GW_EXISTS" != true ]; then warn "Gateway not found; use option 3 (Restore)."; exit 1; fi
  backup_now

  # target PIPs
  if [ "$ACTIVE_ACTIVE" = "true" ]; then
    log "Active-Active detected: requires TWO Public IPs."
    [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (IP #1 name): " NEW_PIP
    [ -z "$NEW_PIP2" ] && read -rp "Enter NEW_PIP2 (IP #2 name): " NEW_PIP2
  else
    [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (Public IP name): " NEW_PIP
  fi

  log "Ensuring target Public IP resource(s) exist (Standard, Static):"
  create_pip_if_missing "$NEW_PIP"  "$LOC"
  [ "$ACTIVE_ACTIVE" = "true" ] && create_pip_if_missing "$NEW_PIP2" "$LOC"

  echo; log "!!! DESTRUCTIVE STEP WARNING !!!"
  echo "This will:"
  echo "  - Delete the vpn-connection objects listed above"
  echo "  - Delete the VNet gateway $GW"
  echo "  - Recreate it with new PIP(s) and SKU=$TARGET_SKU"
  echo "  - Recreate the connections (same names, PSKs, policies)"
  read -rp "Type RECREATE to proceed: " CONFIRM
  [ "$CONFIRM" != "RECREATE" ] && { warn "Aborted by user."; exit 1; }

  # delete connections (no --yes in 2.76.0)
  if [ -n "$CONNS" ]; then
    log "Deleting existing connections ..."
    for C in $CONNS; do
      log "  - $C"
      az network vpn-connection delete -g "$RG" -n "$C" || warn "    - delete failed"
    done
  fi

  # delete gateway
  log "Deleting gateway $GW ..."
  az network vnet-gateway delete -g "$RG" -n "$GW" || warn "Gateway delete returned error (continuing)"

  # recreate gateway (BGP: use --asn instead of --enable-bgp)
  log "Recreating gateway $GW with new PIP(s) and SKU=$TARGET_SKU ..."
  if [ "$ACTIVE_ACTIVE" = "true" ]; then
    if [ -n "$ASN" ] && [ "$ASN" != "None" ]; then
      az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
        --public-ip-addresses "$NEW_PIP" "$NEW_PIP2" --vnet "$VNET_NAME" \
        --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
        --asn "$ASN" || warn "Gateway create failed"
    else
      az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
        --public-ip-addresses "$NEW_PIP" "$NEW_PIP2" --vnet "$VNET_NAME" \
        --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
        || warn "Gateway create failed"
    fi
  else
    if [ -n "$ASN" ] && [ "$ASN" != "None" ]; then
      az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
        --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
        --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
        --asn "$ASN" || warn "Gateway create failed"
    else
      az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
        --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
        --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
        || warn "Gateway create failed"
    fi
  fi

  # poll until Succeeded
  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"

  # recreate connections (from current backup)
  RESTORE_SRC="$BACKUP_DIR"
fi

# ---------- Option 3: Restore from a previous backup ----------
if [ "$CHOICE" = "3" ]; then
  # list backups newest→oldest
  echo "Available backups (newest first):"
  mapfile -t BKLIST < <(ls -1d gw-backup-* 2>/dev/null | sort -r)
  if [ "${#BKLIST[@]}" -eq 0 ]; then
    warn "No gw-backup-* folders found in current directory."; exit 1
  fi
  i=1
  for b in "${BKLIST[@]}"; do echo "  [$i] $b"; i=$((i+1)); done
  read -rp "Select a backup by number: " pick
  RESTORE_SRC="${BKLIST[$((pick-1))]}"
  if [ -z "$RESTORE_SRC" ] || [ ! -d "$RESTORE_SRC" ]; then warn "Invalid selection."; exit 1; fi

  # load restore details
  if [ ! -f "$RESTORE_SRC/gateway-summary.json" ]; then warn "Missing gateway-summary.json in $RESTORE_SRC"; exit 1; fi
  if [ ! -d "$RESTORE_SRC/conn-json" ]; then warn "Missing conn-json folder in $RESTORE_SRC"; exit 1; fi

  LOC=$(jq -r '.location' "$RESTORE_SRC/gateway-summary.json")
  TARGET_SKU=$(jq -r '.sku' "$RESTORE_SRC/gateway-summary.json")
  GTYPE=$(jq -r '.gatewayType' "$RESTORE_SRC/gateway-summary.json")
  VTYPE=$(jq -r '.vpnType' "$RESTORE_SRC/gateway-summary.json")
  SUBNET_ID=$(jq -r '.subnetId' "$RESTORE_SRC/gateway-summary.json")
  VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/subnets/' '{print $1}')
  ASN=$(jq -r '.asn // empty' "$RESTORE_SRC/gateway-summary.json")
  ACTIVE_ACTIVE=false # summary doesn’t capture AA reliably; adapt if you store it
  [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (Public IP name): " NEW_PIP
  log "Ensuring Public IP $NEW_PIP exists..."; create_pip_if_missing "$NEW_PIP" "$LOC"
  # (if you had active-active backups, extend here to prompt for NEW_PIP2)

  echo; log "This will recreate gateway $GW using backup $RESTORE_SRC and NEW_PIP=$NEW_PIP"
  read -rp "Type RESTORE to proceed: " CONFIRM
  [ "$CONFIRM" != "RESTORE" ] && { warn "Aborted by user."; exit 1; }

  # attempt delete existing GW (if any)
  az network vnet-gateway show -g "$RG" -n "$GW" >/dev/null 2>&1 && {
    log "Deleting existing gateway $GW (if present) ..."
    # must delete any blocking connections first
    mapfile -t EXISTING_CONNS < <(az network vpn-connection list -g "$RG" --query "[?contains(id,'/virtualNetworkGateways/${GW}')].name" -o tsv 2>/dev/null)
    if [ "${#EXISTING_CONNS[@]}" -gt 0 ]; then
      for C in "${EXISTING_CONNS[@]}"; do log "  - deleting $C"; az network vpn-connection delete -g "$RG" -n "$C" || true; done
    fi
    az network vnet-gateway delete -g "$RG" -n "$GW" || true
  }

  # recreate GW from backup values (BGP: use --asn when present)
  log "Recreating gateway $GW from backup with SKU=$TARGET_SKU ..."
  if [ -n "$ASN" ] && [ "$ASN" != "None" ]; then
    az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
      --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
      --asn "$ASN" || warn "Gateway create failed"
  else
    az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
      --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$TARGET_SKU" \
      || warn "Gateway create failed"
  fi

  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"
fi

# ---------- Recreate connections from RESTORE_SRC (used by 2 and 3) ----------
if [ -n "$RESTORE_SRC" ]; then
  log "Recreating connections from $RESTORE_SRC ..."
  for CJ in "$RESTORE_SRC"/conn-json/*.json; do
    [ -s "$CJ" ] || continue
    C=$(jq -r '.name' "$CJ")
    EN_BGP=$(jq -r '.enableBgp // false' "$CJ" 2>/dev/null)
    USE_POLICY=$(jq -r '.usePolicyBasedTrafficSelectors // false' "$CJ" 2>/dev/null)
    LNG_ID=$(jq -r '.localNetworkGateway2.id // empty' "$CJ" 2>/dev/null)
    VNG2_ID=$(jq -r '.virtualNetworkGateway2.id // empty' "$CJ" 2>/dev/null)
    PSK_FILE="$RESTORE_SRC/psk/$C.psk"
    PSK=""; [ -s "$PSK_FILE" ] && PSK=$(cat "$PSK_FILE")

    if [ -n "$LNG_ID" ]; then
      log "  + $C (S2S to LocalNetworkGateway)"
      az network vpn-connection create \
        -g "$RG" -n "$C" \
        --vnet-gateway1 "$GW" \
        --local-gateway2 "$LNG_ID" \
        ${PSK:+--shared-key "$PSK"} \
        $( [ "$EN_BGP" = "true" ] && echo --enable-bgp ) \
        $( [ "$USE_POLICY" = "true" ] && echo --use-policy-based-traffic-selectors ) \
        >/dev/null || warn "    - create failed"
    elif [ -n "$VNG2_ID" ]; then
      log "  + $C (VNet-to-VNet)"
      az network vpn-connection create \
        -g "$RG" -n "$C" \
        --vnet-gateway1 "$GW" \
        --vnet-gateway2 "$VNG2_ID" \
        ${PSK:+--shared-key "$PSK"} \
        $( [ "$EN_BGP" = "true" ] && echo --enable-bgp ) \
        >/dev/null || warn "    - create failed"
    else
      warn "  ! Could not determine remote side for $C — inspect $CJ"
      continue
    fi

    # Apply IPsec policies
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
        SAKB=$(jq -r ".ipsecPolicies[$idx].saDataSizeKilobytes // 0" "$CJ")
        SABYTES=$(kb_to_bytes "$SAKB")

        log "    - Applying IPsec policy #$((idx+1)) to $C"
        if [ "$SABYTES" -gt 0 ]; then
          az network vpn-connection ipsec-policy add \
            --resource-group "$RG" \
            --connection-name "$C" \
            --dh-group "$DHG" \
            --ike-encryption "$IKE" --ike-integrity "$IKI" \
            --ipsec-encryption "$SAe" --ipsec-integrity "$SAi" \
            --pfs-group "$PFS" \
            --sa-lifetime "$LIF" \
            --sa-max-size "$SABYTES" >/dev/null || warn "      * policy add failed"
        else
          az network vpn-connection ipsec-policy add \
            --resource-group "$RG" \
            --connection-name "$C" \
            --dh-group "$DHG" \
            --ike-encryption "$IKE" --ike-integrity "$IKI" \
            --ipsec-encryption "$SAe" --ipsec-integrity "$SAi" \
            --pfs-group "$PFS" \
            --sa-lifetime "$LIF" >/dev/null || warn "      * policy add failed"
        fi
      done
    fi
  done

  log "Restore/recreate complete. Current connection status:"
  az network vpn-connection list -g "$RG" --query "[].{name:name,status:connectionStatus}" -o table
  echo; log "Backups live at: $RESTORE_SRC and $BACKUP_DIR"
fi
