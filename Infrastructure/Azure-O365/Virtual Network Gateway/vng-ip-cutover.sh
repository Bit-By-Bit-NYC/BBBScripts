#!/usr/bin/env bash
# Azure VNet Gateway Backup / Recreate / Restore with new Public IP(s)
# Tested with Azure CLI 2.76.0

# -------- Config (config.txt optional) --------
CONFIG_FILE="./config.txt"; [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
RG="${RG:-}"; GW="${GW:-}"; NEW_PIP="${NEW_PIP:-}"; NEW_PIP2="${NEW_PIP2:-}"

# -------- Helpers --------
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(timestamp)] $*"; }
warn(){ echo "[$(timestamp)] WARNING: $*" >&2; }
pretty_json(){ command -v jq >/dev/null 2>&1 && jq -r '.' || cat; }
kb_to_bytes(){ local kb="${1:-0}"; echo $(( kb * 1024 )); }

get_psk(){ # PSK via REST (works across CLI versions)
  local rg="$1" conn="$2" id
  id=$(az network vpn-connection show -g "$rg" -n "$conn" --query id -o tsv 2>/dev/null) || return 1
  az rest --method get \
    --url "https://management.azure.com${id}/sharedKey?api-version=2023-09-01" \
    --query value -o tsv 2>/dev/null
}

# Create Public IP of a given SKU (Basic|Standard)
create_pip_if_missing(){
  local pip="$1" loc="$2" sku="$3"
  if ! az network public-ip show -g "$RG" -n "$pip" >/dev/null 2>&1; then
    log "Creating Public IP $pip ($sku/Static) ..."
    az network public-ip create -g "$RG" -n "$pip" --sku "$sku" --allocation-method Static --location "$loc" >/dev/null || warn "Failed to create $pip"
  fi
  local ip; ip=$(az network public-ip show -g "$RG" -n "$pip" --query ipAddress -o tsv 2>/dev/null)
  log "  $pip => ${ip:-<allocating>}"
}

# For a target gateway SKU, return proper Public IP SKU
pip_sku_for_target(){
  local tsku="$1"
  if [[ "$tsku" == "Basic" ]]; then echo "Basic"; else echo "Standard"; fi
}

# Build list of valid backup folders (skip current)
build_valid_backup_list(){
  BKLIST=()
  while IFS= read -r d; do
    [ "$d" = "$BACKUP_DIR" ] && continue
    [ -d "$d" ] || continue
    [ -f "$d/gateway-summary.json" ] || continue
    [ -d "$d/conn-json" ] || continue
    BKLIST+=("$d")
  done < <(ls -1d gw-backup-* 2>/dev/null | sort -r)
}

# Delete all connections that reference gateway ID; wait for zero
delete_conns_for_gw(){
  local rg="$1" gwid="$2"
  log "Deleting connections that reference gateway: $gwid ..."
  mapfile -t CONN1 < <(az network vpn-connection list -g "$rg" --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${gwid}'].name" -o tsv)
  mapfile -t CONN2 < <(az network vpn-connection list -g "$rg" --query "[?virtualNetworkGateway2 && virtualNetworkGateway2.id=='${gwid}'].name" -o tsv)
  local all=($(printf "%s\n" "${CONN1[@]}" "${CONN2[@]}" | sort -u))
  for C in "${all[@]}"; do
    [ -z "$C" ] && continue
    log "  - deleting vpn-connection $C"
    az network vpn-connection delete -g "$rg" -n "$C" || warn "    - delete failed (continuing)"
  done
  for i in {1..40}; do
    left=$(az network vpn-connection list -g "$rg" \
      --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${gwid}' || virtualNetworkGateway2 && virtualNetworkGateway2.id=='${gwid}'] | length(@)" -o tsv)
    [ "$left" = "0" ] && break
    sleep 6
  done
  log "All referencing connections deleted."
}

# Wait until gateway is gone
wait_delete_gw(){
  local rg="$1" name="$2"
  log "Waiting for gateway $name to be deleted..."
  for i in {1..60}; do
    if ! az network vnet-gateway show -g "$rg" -n "$name" >/dev/null 2>&1; then
      log "Gateway $name no longer present."; return 0
    fi
    sleep 10
  done
  warn "Timed out waiting for gateway delete (continuing)."
}

# Emit a flag only when value is "true"
flag_if_true(){ [ "$1" = "true" ] && echo "$2"; }

# -------- Inputs --------
[ -z "$RG" ] && read -rp "Resource Group (RG): " RG
[ -z "$GW" ] && read -rp "Gateway Name (GW): " GW
az account show >/dev/null 2>&1 || { warn "Not logged in. Run: az login"; exit 1; }

# -------- Snapshot current gateway (if exists) --------
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
  warn "Gateway not found (may be deleted already). Restore modes still work."
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

  TARGET_SKU="$SKU"
  if [ "$SKU" = "Basic" ]; then
    warn "Gateway SKU is 'Basic' (Basic PIP only)."
    echo "Choose target SKU:"
    echo "  1) Stay on Basic (use Basic Public IP)"
    echo "  2) Upgrade to VpnGw1 (use Standard Public IP)"
    read -rp "Enter 1 or 2 [2]: " s
    if [ "$s" = "1" ]; then
      TARGET_SKU="Basic"
    else
      TARGET_SKU="VpnGw1"; [ "$ACTIVE_ACTIVE" = "true" ] && TARGET_SKU="VpnGw1AZ"
    fi
    log "Will recreate with TARGET_SKU=$TARGET_SKU."
  else
    log "Current SKU ($SKU) is compatible with Standard PIP."
  fi
fi

# Discover connections (if gateway exists)
if [ "$GW_EXISTS" = true ]; then
  log "Discovering vpn-connections that reference this gateway..."
  CONNS=$({
    az network vpn-connection list -g "$RG" \
      --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${GW_ID}'].name" -o tsv
    az network vpn-connection list -g "$RG" \
      --query "[?virtualNetworkGateway2 && virtualNetworkGateway2.id=='${GW_ID}'].name" -o tsv
  } | sort -u)

  if [ -z "$CONNS" ]; then warn "No connections reference $GW."; else log "Connections:"; printf ' - %s\n' $CONNS; fi
  printf "%s\n" $CONNS > "$BACKUP_DIR/connections.txt"
fi

# -------- Menu --------
echo
echo "Choose an action:"
echo "  1) Backup only"
echo "  2) Backup and recreate gateway with new Public IP(s)"
echo "  3) Restore from a previous backup (gateway + connections)"
echo "  4) Restore connections only from a previous backup (gateway already exists)"
read -rp "Enter 1, 2, 3, or 4: " CHOICE
echo

# -------- Common backup --------
backup_now(){
  [ -z "$CONNS" ] && return 0
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

# -------- Option 1 --------
if [ "$CHOICE" = "1" ]; then
  [ "$GW_EXISTS" = true ] && backup_now
  log "Backup complete. No changes made."; exit 0
fi

# -------- Option 2: Backup + Recreate current --------
if [ "$CHOICE" = "2" ]; then
  if [ "$GW_EXISTS" != true ]; then warn "Gateway not found; use option 3 (Restore)."; exit 1; fi
  backup_now

  # Determine proper PIP SKU from TARGET_SKU (may have been changed above)
  PIP_SKU=$(pip_sku_for_target "$TARGET_SKU")

  # Collect PIPs
  if [ "$ACTIVE_ACTIVE" = "true" ]; then
    log "Active-Active detected: requires TWO Public IPs."
    [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (IP #1 name): " NEW_PIP
    [ -z "$NEW_PIP2" ] && read -rp "Enter NEW_PIP2 (IP #2 name): " NEW_PIP2
  else
    [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (Public IP name): " NEW_PIP
  fi

  log "Ensuring target Public IP resource(s) exist ($PIP_SKU, Static):"
  create_pip_if_missing "$NEW_PIP"  "$LOC" "$PIP_SKU"
  [ "$ACTIVE_ACTIVE" = "true" ] && create_pip_if_missing "$NEW_PIP2" "$LOC" "$PIP_SKU"

  echo; log "!!! DESTRUCTIVE STEP WARNING !!!"
  echo "This will delete connections, delete the gateway, create it with NEW_PIP(s) and SKU=$TARGET_SKU, then recreate connections."
  read -rp "Type RECREATE to proceed: " CONFIRM
  [ "$CONFIRM" != "RECREATE" ] && { warn "Aborted by user."; exit 1; }

  # Delete connections FIRST, then gateway
  [ -n "$GW_ID" ] && delete_conns_for_gw "$RG" "$GW_ID"
  log "Deleting gateway $GW ..."; az network vnet-gateway delete -g "$RG" -n "$GW" || warn "Gateway delete returned error (continuing)"
  wait_delete_gw "$RG" "$GW"

  # Recreate gateway with TARGET_SKU (BGP via --asn if present)
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

  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"

  RESTORE_SRC="$BACKUP_DIR"
fi

# -------- Option 3: Restore GW + connections from previous backup (HONORS TARGET_SKU) --------
# ---------- Option 3: Restore GW + connections from previous backup (HONORS/ASKS FOR NON-BASIC) ----------
if [ "$CHOICE" = "3" ]; then
  build_valid_backup_list
  if [ "${#BKLIST[@]}" -eq 0 ]; then warn "No valid gw-backup-* folders found."; exit 1; fi
  echo "Available backups (newest first):"; i=1; for b in "${BKLIST[@]}"; do echo "  [$i] $b"; i=$((i+1)); done
  read -rp "Select a backup by number: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#BKLIST[@]}" ] || { warn "Invalid selection."; exit 1; }
  RESTORE_SRC="${BKLIST[$((pick-1))]}"

  # Read values from the backup summary
  LOC=$(jq -r '.location' "$RESTORE_SRC/gateway-summary.json")
  BACKUP_SKU=$(jq -r '.sku' "$RESTORE_SRC/gateway-summary.json")
  GTYPE=$(jq -r '.gatewayType' "$RESTORE_SRC/gateway-summary.json")
  VTYPE=$(jq -r '.vpnType' "$RESTORE_SRC/gateway-summary.json")
  SUBNET_ID=$(jq -r '.subnetId' "$RESTORE_SRC/gateway-summary.json")
  VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/subnets/' '{print $1}')
  ASN=$(jq -r '.asn // empty' "$RESTORE_SRC/gateway-summary.json")

  # If TARGET_SKU is not set or is Basic, prompt for a non-Basic choice
  if [ -z "${TARGET_SKU:-}" ] || [ "$TARGET_SKU" = "Basic" ]; then
    echo "Select target gateway SKU (non-Basic):"
    echo "  1) VpnGw1"
    echo "  2) VpnGw2"
    echo "  3) VpnGw3"
    echo "  4) VpnGw1AZ"
    echo "  5) VpnGw2AZ"
    echo "  6) VpnGw3AZ"
    read -rp "Enter 1-6 [1]: " sku_pick
    case "${sku_pick:-1}" in
      1) FINAL_SKU="VpnGw1" ;;
      2) FINAL_SKU="VpnGw2" ;;
      3) FINAL_SKU="VpnGw3" ;;
      4) FINAL_SKU="VpnGw1AZ" ;;
      5) FINAL_SKU="VpnGw2AZ" ;;
      6) FINAL_SKU="VpnGw3AZ" ;;
      *) FINAL_SKU="VpnGw1" ;;
    esac
  else
    FINAL_SKU="$TARGET_SKU"
  fi
  log "Restoring with FINAL_SKU=$FINAL_SKU (backup had $BACKUP_SKU)."

  # PIP SKU from FINAL_SKU
  PIP_SKU=$(pip_sku_for_target "$FINAL_SKU")
  [ -z "$NEW_PIP" ] && read -rp "Enter NEW_PIP (Public IP name): " NEW_PIP
  log "Ensuring Public IP $NEW_PIP exists ($PIP_SKU, Static) ..."
  create_pip_if_missing "$NEW_PIP" "$LOC" "$PIP_SKU"

  echo; log "This will recreate gateway $GW using backup $RESTORE_SRC and NEW_PIP=$NEW_PIP (SKU=$FINAL_SKU)"
  read -rp "Type RESTORE to proceed: " CONFIRM
  [ "$CONFIRM" != "RESTORE" ] && { warn "Aborted by user."; exit 1; }

  # If a GW exists, cleanly remove connections then delete GW; wait until gone
  if az network vnet-gateway show -g "$RG" -n "$GW" >/dev/null 2>&1; then
    CUR_GW_ID=$(az network vnet-gateway show -g "$RG" -n "$GW" --query id -o tsv)
    delete_conns_for_gw "$RG" "$CUR_GW_ID"
    log "Deleting existing gateway $GW ..."; az network vnet-gateway delete -g "$RG" -n "$GW" || true
    wait_delete_gw "$RG" "$GW"
  fi

  # Decide whether to pass --asn (only if ASN present AND FINAL_SKU != Basic)
  PASS_ASN=false
  if [ -n "$ASN" ] && [ "$ASN" != "None" ]; then
    case "$FINAL_SKU" in
      Basic) PASS_ASN=false ;;
      *)     PASS_ASN=true  ;;
    esac
  fi

  # Recreate gateway with FINAL_SKU
  log "Recreating gateway $GW with SKU=$FINAL_SKU ..."
  if [ "$PASS_ASN" = true ]; then
    az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
      --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" \
      --asn "$ASN" || warn "Gateway create failed"
  else
    az network vnet-gateway create -g "$RG" -n "$GW" --location "$LOC" \
      --public-ip-addresses "$NEW_PIP" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" \
      || warn "Gateway create failed"
  fi

  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"

  RESTORE_SRC="$RESTORE_SRC"
fi

# -------- Option 4: Restore connections only --------
if [ "$CHOICE" = "4" ]; then
  if ! az network vnet-gateway show -g "$RG" -n "$GW" >/dev/null 2>&1; then
    warn "Gateway $GW not found. Use option 2 or 3 first."; exit 1
  fi
  build_valid_backup_list
  if [ "${#BKLIST[@]}" -eq 0 ]; then warn "No valid gw-backup-* folders found."; exit 1; fi
  echo "Available backups (newest first):"; i=1; for b in "${BKLIST[@]}"; do echo "  [$i] $b"; i=$((i+1)); done
  read -rp "Select a backup by number: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#BKLIST[@]}" ] || { warn "Invalid selection."; exit 1; }
  RESTORE_SRC="${BKLIST[$((pick-1))]}"
fi

# -------- Recreate connections from RESTORE_SRC (for 2, 3, 4) --------
if [ -n "${RESTORE_SRC:-}" ]; then
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

    # Apply IPsec policies — CLI 2.76.0 requires --sa-max-size; default to 100MB if backup had 0
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
        SABYTES=$(kb_to_bytes "$SAKB"); [ "$SABYTES" -le 0 ] && SABYTES=102400000

        log "    - Applying IPsec policy #$((idx+1)) to $C"
        az network vpn-connection ipsec-policy add \
          --resource-group "$RG" \
          --connection-name "$C" \
          --dh-group "$DHG" \
          --ike-encryption "$IKE" --ike-integrity "$IKI" \
          --ipsec-encryption "$SAe" --ipsec-integrity "$SAi" \
          --pfs-group "$PFS" \
          --sa-lifetime "$LIF" \
          --sa-max-size "$SABYTES" >/dev/null || warn "      * policy add failed"
      done
    fi
  done

  log "Restore/recreate complete. Current connection status:"
  az network vpn-connection list -g "$RG" --query "[].{name:name,status:connectionStatus}" -o table
  echo; log "Backups live at: $RESTORE_SRC and $BACKUP_DIR"
fi
