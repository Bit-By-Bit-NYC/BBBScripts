#!/usr/bin/env bash
# vng-rebuild.sh
# Azure VNet Gateway Backup / Recreate / Restore with new Public IP(s) + P2S
# - Prints SKU menu (1–7)
# - Prompts GW name + connection renames up-front
# - Optional subscription switching + context dump
# - Reuse existing PIPs (1/2/3) or create new; AZ/non-AZ zone guard
# - Backs up S2S/VNet2VNet + PSKs; restores policies
# - Backs up & restores P2S vpnClientConfiguration (+ optional client package)
# Tested with Azure CLI 2.76.0

# ---------------- Config (config.txt optional) ----------------
CONFIG_FILE="./config.txt"; [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
RG="${RG:-}"; GW="${GW:-}"
NEW_PIP="${NEW_PIP:-}"; NEW_PIP2="${NEW_PIP2:-}"; NEW_PIP3="${NEW_PIP3:-}"

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
FORCE_SUBSCRIPTION="${FORCE_SUBSCRIPTION:-false}"

SKIP_SKU_PROMPT="${SKIP_SKU_PROMPT:-false}"
SKIP_AA_PROMPT="${SKIP_AA_PROMPT:-false}"
REUSE_EXISTING_PIPS="${REUSE_EXISTING_PIPS:-true}"

BACKUP_P2S="${BACKUP_P2S:-true}"
BACKUP_P2S_CLIENT_PACKAGE="${BACKUP_P2S_CLIENT_PACKAGE:-false}"
RESTORE_P2S="${RESTORE_P2S:-true}"

API="2023-09-01"

# ---------------- Helpers ----------------
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(timestamp)] $*"; }
warn(){ echo "[$(timestamp)] WARNING: $*" >&2; }
pretty_json(){ command -v jq >/dev/null 2>&1 && jq -r '.' || cat; }
kb_to_bytes(){ local kb="${1:-0}"; echo $(( kb * 1024 )); }

read_default(){ # usage: read_default VAR "Prompt" "default"
  local __var="$1"; shift
  local __prompt="$1"; shift
  local __def="${1:-}"
  local __ans
  if [ -n "$__def" ]; then
    read -rp "$__prompt [$__def]: " __ans
    eval "$__var=\"\${__ans:-$__def}\""
  else
    read -rp "$__prompt: " __ans
    eval "$__var=\"\${__ans}\""
  fi
}

show_context(){
  echo
  log "=== Azure CLI Context ==="
  az account show -o jsonc 2>/dev/null || warn "az account show failed"
  echo
  log "Available subscriptions (abbrev):"
  az account list --query "[].{name:name,id:id,isDefault:isDefault,tenant:tenantId}" -o table 2>/dev/null || true
  echo
}

show_sku_menu(){
  echo
  echo "Select target gateway SKU:"
  echo "  1) VpnGw1"
  echo "  2) VpnGw2"
  echo "  3) VpnGw3"
  echo "  4) VpnGw1AZ (zone-redundant)"
  echo "  5) VpnGw2AZ (zone-redundant)"
  echo "  6) VpnGw3AZ (zone-redundant)"
  echo "  7) Basic (not recommended; no BGP, Basic PIP)"
}

get_psk(){ # PSK via REST (works across CLI versions)
  local rg="$1" conn="$2" id
  id=$(az network vpn-connection show -g "$rg" -n "$conn" --query id -o tsv 2>/dev/null) || return 1
  az rest --method get \
    --url "https://management.azure.com${id}/sharedKey?api-version=${API}" \
    --query value -o tsv 2>/dev/null
}

# Create NON-ZONAL Public IP of a given SKU (Basic|Standard)
create_pip_if_missing(){
  local pip="$1" loc="$2" sku="$3"
  if ! az network public-ip show -g "$RG" -n "$pip" >/dev/null 2>&1; then
    log "Creating Public IP $pip ($sku/Static) ..."
    az network public-ip create -g "$RG" -n "$pip" --sku "$sku" --allocation-method Static --location "$loc" >/dev/null || warn "Failed to create $pip"
  fi
  local ip; ip=$(az network public-ip show -g "$RG" -n "$pip" --query ipAddress -o tsv 2>/dev/null)
  log "  $pip => ${ip:-<allocating>}"
}

# PIP SKU from target gateway SKU
pip_sku_for_target(){ local tsku="$1"; [[ "$tsku" == "Basic" ]] && echo "Basic" || echo "Standard"; }

# Return 0 (true) if PIP has zones configured; 1 (false) otherwise
pip_has_zones(){
  local pip="$1" cnt
  cnt=$(az network public-ip show -g "$RG" -n "$pip" --query "length(zones || [])" -o tsv 2>/dev/null)
  [ -n "$cnt" ] && [ "$cnt" -gt 0 ]
}

# Ensure selected PIP matches gateway SKU zoning rules; may propose -nozone PIP
# ECHO ONLY the final pip name
ensure_pip_zone_compat(){
  local final_sku="$1" pip="$2" loc="$3"
  if [[ "$final_sku" == *AZ ]]; then
    if pip_has_zones "$pip"; then
      warn "Public IP $pip has zones; AZ gateways typically use zone-redundant (non-zonal) PIPs."
      local alt="${pip}-nozone" ans
      read_default ans "Create non-zonal PIP $alt and use it" "Y"
      if [[ "${ans^^}" == "Y" ]]; then
        create_pip_if_missing "$alt" "$loc" "Standard"; echo "$alt"; return
      fi
    fi
    echo "$pip"
  else
    if pip_has_zones "$pip"; then
      warn "PIP $pip is zonal; NON-AZ gateway ($final_sku) requires NON-ZONAL PIP."
      local alt="${pip}-nozone" ans
      read_default ans "Create non-zonal PIP $alt and use it" "Y"
      if [[ "${ans^^}" == "Y" ]]; then
        create_pip_if_missing "$alt" "$loc" "Standard"; echo "$alt"; return
      fi
    fi
    echo "$pip"
  fi
}

# Pull current gateway PIP names from live gateway.json
get_current_gateway_pip_names(){
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.properties.ipConfigurations[]
         | select(.properties.publicIPAddress?.id)
         | .properties.publicIPAddress.id
         | split("/publicIPAddresses/")[1]' "$BACKUP_DIR/gateway.json" 2>/dev/null | sed '/^null$/d'
}

# Pull PIP names from backup gateway.json
get_backup_pip_names(){
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.properties.ipConfigurations[]
         | select(.properties.publicIPAddress?.id)
         | .properties.publicIPAddress.id
         | split("/publicIPAddresses/")[1]' "$RESTORE_SRC/gateway.json" 2>/dev/null | sed '/^null$/d'
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

# ------------ P2S BACKUP / RESTORE ------------
backup_p2s(){
  local outdir="$1"
  mkdir -p "$outdir/p2s"
  if command -v jq >/dev/null 2>&1; then
    jq '.vpnClientConfiguration // {}' "$outdir/gateway.json" > "$outdir/p2s/p2s-config.json"
  else
    cp "$outdir/gateway.json" "$outdir/p2s/p2s-config.json"
  fi
  log "P2S config saved to $outdir/p2s/p2s-config.json"

  if [ "${BACKUP_P2S_CLIENT_PACKAGE,,}" = "true" ]; then
    local url zip
    url=$(az network vnet-gateway vpn-client show-url -g "$RG" -n "$GW" -o tsv 2>/dev/null || true)
    if [ -z "$url" ]; then
      url=$(az network vnet-gateway vpn-client generate -g "$RG" -n "$GW" --processor-architecture Amd64 -o tsv 2>/dev/null || true)
    fi
    if [ -n "$url" ]; then
      zip="$outdir/p2s/vpn-client-package.zip"
      if command -v curl >/dev/null 2>&1; then
        log "Downloading P2S client package..."
        curl -fSL "$url" -o "$zip" && log "P2S client package saved to $zip" || warn "Failed to download P2S client package"
      else
        warn "curl not found; skipping P2S client package download"
      fi
    else
      warn "Could not obtain P2S client package URL."
    fi
  fi
}

restore_p2s(){
  local gw_name="$1" rg="$2" src_dir="$3" gw_id tmp body_file
  [ "${RESTORE_P2S,,}" = "true" ] || { log "RESTORE_P2S=false; skipping P2S restore."; return 0; }
  [ -s "$src_dir/p2s/p2s-config.json" ] || { log "No P2S config found in backup; skipping."; return 0; }

  gw_id=$(az network vnet-gateway show -g "$rg" -n "$gw_name" --query id -o tsv)
  tmp="$(mktemp)"; cp "$src_dir/p2s/p2s-config.json" "$tmp"

  # Prompt for missing RADIUS secrets (Azure never returns them)
  if command -v jq >/dev/null 2>&1; then
    local has_radius secret secret2
    has_radius=$(jq -r 'has("radiusServerAddress") or has("radiusServers") or has("radiusServersSecondary") or has("radiusServerSecondaryAddress")' "$tmp")
    if [ "$has_radius" = "true" ]; then
      read -rp "Enter RADIUS shared secret (leave blank to skip): " -s secret || true; echo
      if [ -n "$secret" ]; then
        if jq -e '.radiusServers' "$tmp" >/dev/null 2>&1; then
          jq --arg s "$secret" '(.radiusServers // []) |= map(. + {"secret": ($s)})' "$tmp" > "$tmp.p" && mv "$tmp.p" "$tmp"
        else
          jq --arg s "$secret" '. + {"radiusServerSecret": $s}' "$tmp" > "$tmp.p" && mv "$tmp.p" "$tmp"
        fi
      fi
      if jq -e '.radiusServersSecondary or .radiusServerSecondaryAddress' "$tmp" >/dev/null 2>&1; then
        read -rp "Enter SECONDARY RADIUS shared secret (leave blank to skip): " -s secret2 || true; echo
        if [ -n "$secret2" ]; then
          if jq -e '.radiusServersSecondary' "$tmp" >/dev/null 2>&1; then
            jq --arg s "$secret2" '(.radiusServersSecondary // []) |= map(. + {"secret": ($s)})' "$tmp" > "$tmp.p" && mv "$tmp.p" "$tmp"
          else
            jq --arg s "$secret2" '. + {"radiusServerSecondarySecret": $s}' "$tmp" > "$tmp.p" && mv "$tmp.p" "$tmp"
          fi
        fi
      fi
    fi
  fi

  body_file="$(mktemp)"
  if command -v jq >/dev/null 2>&1; then
    jq -n --argjson vcc "$(cat "$tmp" 2>/dev/null || echo '{}')" '{properties:{vpnClientConfiguration:$vcc}}' > "$body_file"
  else
    echo "{\"properties\":{\"vpnClientConfiguration\":$(cat "$tmp")}}" > "$body_file"
  fi

  log "Applying P2S configuration to gateway $gw_name ..."
  az rest --method patch \
    --url "https://management.azure.com${gw_id}?api-version=${API}" \
    --body @"$body_file" >/dev/null || warn "P2S restore PATCH failed"

  rm -f "$tmp" "$body_file"
  log "P2S restore step complete."
}

# ---- Connection rename plan (up-front prompts) ----
collect_connection_rename_plan_from_live(){
  local plan="$1"; : > "$plan"
  [ -z "${CONNS:-}" ] && return 0
  echo; log "Rename connections (press Enter to keep same):"
  while read -r C; do
    [ -z "$C" ] && continue
    local NEWC="$C"; read_default NEWC "  New name for '$C'" "$C"
    printf "%s\t%s\n" "$C" "$NEWC" >> "$plan"
  done <<< "$CONNS"
}
collect_connection_rename_plan_from_backup(){
  local plan="$1" src="$2"; : > "$plan"
  echo; log "Rename connections from backup (press Enter to keep same):"
  for CJ in "$src"/conn-json/*.json; do
    [ -s "$CJ" ] || continue
    local C; C=$(jq -r '.name' "$CJ")
    local NEWC="$C"; read_default NEWC "  New name for '$C'" "$C"
    printf "%s\t%s\n" "$C" "$NEWC" >> "$plan"
  done
}
lookup_new_conn_name(){ local plan="$1" old="$2" line new; line=$(grep -F "$old"$'\t' "$plan" 2>/dev/null | head -n1 || true); [ -n "$line" ] && { new="${line#*$'\t'}"; echo "$new"; } || echo "$old"; }

# ---------------- Start ----------------
[ -z "${RG:-}" ] && read -rp "Resource Group (RG): " RG
[ -z "${GW:-}" ] && read -rp "Gateway Name (GW): " GW

az account show >/dev/null 2>&1 || { warn "Not logged in. Run: az login"; exit 1; }
if [[ -n "${SUBSCRIPTION_ID:-}" && "${FORCE_SUBSCRIPTION,,}" == "true" ]]; then
  log "Setting subscription to ${SUBSCRIPTION_ID} ..."
  az account set --subscription "${SUBSCRIPTION_ID}" || warn "az account set failed"
fi
show_context

# Snapshot current gateway (if exists)
BACKUP_DIR="gw-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR/conn-json" "$BACKUP_DIR/psk"

log "Reading gateway $GW in $RG ..."
GW_EXISTS=false
if az network vnet-gateway show -g "$RG" -n "$GW" -o json > "$BACKUP_DIR/gateway.json" 2>/dev/null; then
  GW_EXISTS=true
  if command -v jq >/dev/null 2>&1; then
    jq '{
      name:.name, id:.id, location:.location, sku:.sku.name,
      gatewayType:.gatewayType, vpnType:.vpnType, activeActive:.activeActive,
      asn:(.bgpSettings.asn // empty),
      vnetId:(.ipConfigurations[0].subnet.id|split("/subnets/")[0]),
      subnetId:.ipConfigurations[0].subnet.id
    }' "$BACKUP_DIR/gateway.json" | tee "$BACKUP_DIR/gateway-summary.json" | pretty_json
  else
    cp "$BACKUP_DIR/gateway.json" "$BACKUP_DIR/gateway-summary.json"
    cat "$BACKUP_DIR/gateway.json"
  fi
else
  warn "Gateway not found (may be deleted already). Restore modes still work."
fi

if [ "$GW_EXISTS" = true ]; then
  GW_ID=$(az network vnet-gateway show -g "$RG" -n "$GW" --query id -o tsv)
  LOC=$(az network vnet-gateway show -g "$RG" -n "$GW" --query location -o tsv)
  SKU=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "sku.name" -o tsv)
  GTYPE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query gatewayType -o tsv)
  VTYPE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query vpnType -o tsv)
  ACTIVE_ACTIVE=$(az network vnet-gateway show -g "$RG" -n "$GW" --query activeActive -o tsv)
  ASN=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "bgpSettings.asn" -o tsv 2>/dev/null || true)
  SUBNET_ID=$(az network vnet-gateway show -g "$RG" -n "$GW" --query "ipConfigurations[0].subnet.id" -o tsv)
  VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/subnets/' '{print $1}')
  [ -z "${ASN:-}" ] || [ "$ASN" = "None" ] && ASN=""
  TARGET_SKU="$SKU"

  # Discover connections
  log "Discovering vpn-connections that reference this gateway..."
  CONNS=$({
    az network vpn-connection list -g "$RG" --query "[?virtualNetworkGateway1 && virtualNetworkGateway1.id=='${GW_ID}'].name" -o tsv
    az network vpn-connection list -g "$RG" --query "[?virtualNetworkGateway2 && virtualNetworkGateway2.id=='${GW_ID}'].name" -o tsv
  } | sort -u)
  if [ -z "$CONNS" ]; then warn "No connections reference $GW."; else log "Connections:"; printf ' - %s\n' $CONNS; fi
  printf "%s\n" $CONNS > "$BACKUP_DIR/connections.txt"
fi

# ---------------- Menu ----------------
echo
echo "Choose an action:"
echo "  1) Backup only"
echo "  2) Backup and recreate gateway with new/existing Public IP(s)"
echo "  3) Restore from a previous backup (gateway + connections)"
echo "  4) Restore connections only from a previous backup (gateway already exists)"
read -rp "Enter 1, 2, 3, or 4: " CHOICE
echo

# ---------------- Backup block ----------------
backup_now(){
  if [ -n "${CONNS:-}" ]; then
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
  fi

  if [ "${BACKUP_P2S,,}" = "true" ] && [ -s "$BACKUP_DIR/gateway.json" ]; then
    backup_p2s "$BACKUP_DIR"
  fi
}

# -------- Option 1 --------
if [ "$CHOICE" = "1" ]; then
  backup_now
  log "Backup complete. No changes made."; exit 0
fi

PLAN_FILE="$BACKUP_DIR/connection-rename.map"

# Common SKU/AA selector
select_final_sku_and_aa(){
  local default_sku="$1" default_aa="$2"
  if [[ "${SKIP_SKU_PROMPT,,}" == "true" ]]; then
    FINAL_SKU="${default_sku:-VpnGw1}"
    if [[ "${SKIP_AA_PROMPT,,}" == "true" ]]; then
      ACTIVE_ACTIVE=$([ "$default_aa" = true ] && echo true || echo false)
      log "Using FINAL_SKU=$FINAL_SKU, Active-Active=$ACTIVE_ACTIVE (prompts skipped)."; return
    fi
    local aa_def=$([ "$default_aa" = true ] && echo "Y" || echo "n")
    read -rp "Enable Active-Active? [${aa_def}]: " aa_ans; aa_ans=${aa_ans:-$aa_def}
    ACTIVE_ACTIVE=$([[ "$aa_ans" =~ ^[Yy]$ ]] && echo true || echo false)
    log "Using FINAL_SKU=$FINAL_SKU, Active-Active=$ACTIVE_ACTIVE."; return
  fi

  show_sku_menu
  local def
  case "$default_sku" in
    VpnGw1) def=1;; VpnGw2) def=2;; VpnGw3) def=3;;
    VpnGw1AZ) def=4;; VpnGw2AZ) def=5;; VpnGw3AZ) def=6;;
    Basic) def=7;; *) def=1;;
  esac
  read -rp "Enter 1-7 [$def] (Enter = keep $default_sku): " pick; pick=${pick:-$def}
  case "$pick" in
    1) FINAL_SKU="VpnGw1";; 2) FINAL_SKU="VpnGw2";; 3) FINAL_SKU="VpnGw3";;
    4) FINAL_SKU="VpnGw1AZ";; 5) FINAL_SKU="VpnGw2AZ";; 6) FINAL_SKU="VpnGw3AZ";;
    7) FINAL_SKU="Basic";;  *) FINAL_SKU="${default_sku:-VpnGw1}";;
  esac
  local aa_def=$([ "$default_aa" = true ] && echo "Y" || echo "n")
  read -rp "Enable Active-Active? [${aa_def}] (Enter = keep $default_aa): " aa_ans; aa_ans=${aa_ans:-$aa_def}
  ACTIVE_ACTIVE=$([[ "$aa_ans" =~ ^[Yy]$ ]] && echo true || echo false)
  log "Using FINAL_SKU=$FINAL_SKU, Active-Active=$ACTIVE_ACTIVE."
}

# ---------------- Option 2: Backup + Recreate current ----------------
if [ "$CHOICE" = "2" ]; then
  if [ "$GW_EXISTS" != true ]; then warn "Gateway not found; use option 3 (Restore)."; exit 1; fi
  backup_now
  select_final_sku_and_aa "${TARGET_SKU:-VpnGw1}" "${ACTIVE_ACTIVE:-false}"
  read_default NEW_GW "New gateway name" "$GW"
  collect_connection_rename_plan_from_live "$PLAN_FILE"

  # Reuse existing PIPs or create new
  PIP_SKU=$(pip_sku_for_target "$FINAL_SKU")
  EXISTING_PIPS=()
  if [ "$GW_EXISTS" = true ]; then
    mapfile -t EXISTING_PIPS < <(get_current_gateway_pip_names)
  fi
  USE_REUSE_DEF=$( [[ "${REUSE_EXISTING_PIPS,,}" == "false" ]] && echo "n" || echo "Y")
  if [ ${#EXISTING_PIPS[@]} -gt 0 ]; then
    echo; log "Current gateway PIPs detected: ${EXISTING_PIPS[*]}"
    read_default USE_REUSE "Reuse existing Public IP(s)? [Y/n]" "$USE_REUSE_DEF"
  else
    USE_REUSE="n"
  fi

  if [[ "${USE_REUSE,,}" == "y" ]]; then
    NEW_PIP="${EXISTING_PIPS[0]}"
    NEW_PIP2="${EXISTING_PIPS[1]:-}"
    NEW_PIP3="${EXISTING_PIPS[2]:-}"
    log "Reusing PIPs: ${EXISTING_PIPS[*]}"
  else
    read_default NEW_PIP  "Enter NEW_PIP (Public IP name)" "$NEW_PIP"
    create_pip_if_missing "$NEW_PIP" "$LOC" "$PIP_SKU"
    NEW_PIP=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP" "$LOC")
    if [ "$ACTIVE_ACTIVE" = true ]; then
      read_default NEW_PIP2 "Enter NEW_PIP2 (2nd Public IP name)" "$NEW_PIP2"
      create_pip_if_missing "$NEW_PIP2" "$LOC" "$PIP_SKU"
      NEW_PIP2=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP2" "$LOC")
    fi
    read -rp "Provide NEW_PIP3 (3rd IP for P2S ipConfiguration) [Enter to skip]: " NEW_PIP3
    if [ -n "$NEW_PIP3" ]; then
      create_pip_if_missing "$NEW_PIP3" "$LOC" "$PIP_SKU"
      NEW_PIP3=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP3" "$LOC")
    fi
  fi

  # Summarize
  if [ -n "${NEW_PIP3:-}" ]; then
    log "Using Public IPs: $NEW_PIP, ${NEW_PIP2:-<none>}, $NEW_PIP3"
  elif [ -n "${NEW_PIP2:-}" ]; then
    log "Using Public IPs: $NEW_PIP, $NEW_PIP2"
  else
    log "Using Public IP:  $NEW_PIP"
  fi

  echo; log "!!! DESTRUCTIVE STEP WARNING !!!"
  echo "This will delete connections, delete the gateway, create $NEW_GW with SKU=$FINAL_SKU and selected PIP(s), then recreate connections."
  read -rp "Type RECREATE to proceed: " CONFIRM
  [ "$CONFIRM" != "RECREATE" ] && { warn "Aborted by user."; exit 1; }

  # Delete connections then gateway
  [ -n "${GW_ID:-}" ] && delete_conns_for_gw "$RG" "$GW_ID"
  log "Deleting gateway $GW ..."; az network vnet-gateway delete -g "$RG" -n "$GW" || warn "Gateway delete returned error (continuing)"
  wait_delete_gw "$RG" "$GW"

  # Build PIP args 1/2/3
  PIP_ARGS=("$NEW_PIP"); [ -n "${NEW_PIP2:-}" ] && PIP_ARGS+=("$NEW_PIP2"); [ -n "${NEW_PIP3:-}" ] && PIP_ARGS+=("$NEW_PIP3")

  # Recreate gateway
  log "Recreating gateway $NEW_GW with SKU=$FINAL_SKU ..."
  if [ -n "${ASN:-}" ] && [ "$FINAL_SKU" != "Basic" ]; then
    az network vnet-gateway create -g "$RG" -n "$NEW_GW" --location "$LOC" \
      --public-ip-addresses "${PIP_ARGS[@]}" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" --asn "$ASN" || warn "Gateway create failed"
  else
    az network vnet-gateway create -g "$RG" -n "$NEW_GW" --location "$LOC" \
      --public-ip-addresses "${PIP_ARGS[@]}" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" || warn "Gateway create failed"
  fi

  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$NEW_GW" --query provisioningState -o tsv 2>/dev/null || true)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"

  # P2S restore
  restore_p2s "$NEW_GW" "$RG" "$BACKUP_DIR"

  GW="$NEW_GW"
  RESTORE_SRC="$BACKUP_DIR"
fi

# ---------------- Option 3: Restore (GW + connections) from backup ----------------
if [ "$CHOICE" = "3" ]; then
  build_valid_backup_list
  if [ "${#BKLIST[@]}" -eq 0 ]; then warn "No valid gw-backup-* folders found."; exit 1; fi
  echo "Available backups (newest first):"; i=1; for b in "${BKLIST[@]}"; do echo "  [$i] $b"; i=$((i+1)); done
  read -rp "Select a backup by number: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#BKLIST[@]}" ] || { warn "Invalid selection."; exit 1; }
  RESTORE_SRC="${BKLIST[$((pick-1))]}"

  # Pull restore values
  LOC=$(jq -r '.location' "$RESTORE_SRC/gateway-summary.json")
  BACKUP_SKU=$(jq -r '.sku' "$RESTORE_SRC/gateway-summary.json")
  GTYPE=$(jq -r '.gatewayType' "$RESTORE_SRC/gateway-summary.json")
  VTYPE=$(jq -r '.vpnType' "$RESTORE_SRC/gateway-summary.json")
  SUBNET_ID=$(jq -r '.subnetId' "$RESTORE_SRC/gateway-summary.json")
  VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/virtualNetworks/' '{print $2}' | awk -F'/subnets/' '{print $1}')
  ASN=$(jq -r '.asn // empty' "$RESTORE_SRC/gateway-summary.json")
  BACKUP_GW_NAME=$(jq -r '.name' "$RESTORE_SRC/gateway-summary.json")
  BACKUP_AA=$(jq -r '.activeActive // false' "$RESTORE_SRC/gateway.json" 2>/dev/null || echo "false"); [ "$BACKUP_AA" = "true" ] || BACKUP_AA=false

  select_final_sku_and_aa "${TARGET_SKU:-$BACKUP_SKU}" "${BACKUP_AA}"
  read_default NEW_GW "New gateway name" "$BACKUP_GW_NAME"
  collect_connection_rename_plan_from_backup "$PLAN_FILE" "$RESTORE_SRC"

  # Reuse PIPs from backup or create new
  PIP_SKU=$(pip_sku_for_target "$FINAL_SKU")
  mapfile -t EXISTING_PIPS < <(get_backup_pip_names)
  if [ ${#EXISTING_PIPS[@]} -gt 0 ]; then
    echo; log "Backup shows PIPs: ${EXISTING_PIPS[*]}"
    read_default USE_REUSE "Reuse these Public IP(s)? [Y/n]" "$( [[ "${REUSE_EXISTING_PIPS,,}" == "false" ]] && echo "n" || echo "Y")"
  else
    USE_REUSE="n"
  fi

  if [[ "${USE_REUSE,,}" == "y" ]]; then
    NEW_PIP="${EXISTING_PIPS[0]}"
    NEW_PIP2="${EXISTING_PIPS[1]:-}"
    NEW_PIP3="${EXISTING_PIPS[2]:-}"
    log "Reusing PIPs: ${EXISTING_PIPS[*]}"
  else
    read_default NEW_PIP "Enter NEW_PIP (Public IP name)" "$NEW_PIP"
    create_pip_if_missing "$NEW_PIP" "$LOC" "$PIP_SKU"
    NEW_PIP=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP" "$LOC")
    if [ "$ACTIVE_ACTIVE" = true ]; then
      read_default NEW_PIP2 "Enter NEW_PIP2 (2nd Public IP name)" "$NEW_PIP2"
      create_pip_if_missing "$NEW_PIP2" "$LOC" "$PIP_SKU"
      NEW_PIP2=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP2" "$LOC")
    fi
    read -rp "Provide NEW_PIP3 (3rd IP for P2S ipConfiguration) [Enter to skip]: " NEW_PIP3
    if [ -n "$NEW_PIP3" ]; then
      create_pip_if_missing "$NEW_PIP3" "$LOC" "$PIP_SKU"
      NEW_PIP3=$(ensure_pip_zone_compat "$FINAL_SKU" "$NEW_PIP3" "$LOC")
    fi
  fi

  [ -n "${NEW_PIP3:-}" ] && log "Using Public IPs: $NEW_PIP, ${NEW_PIP2:-<none>}, $NEW_PIP3" || \
  { if [ -n "${NEW_PIP2:-}" ]; then log "Using Public IPs: $NEW_PIP, $NEW_PIP2"; else log "Using Public IP:  $NEW_PIP"; fi; }

  echo; log "This will recreate gateway $NEW_GW using backup $RESTORE_SRC with SKU=$FINAL_SKU and selected PIP(s)."
  read -rp "Type RESTORE to proceed: " CONFIRM
  [ "$CONFIRM" != "RESTORE" ] && { warn "Aborted by user."; exit 1; }

  # Delete existing gateway (NEW_GW if present, else current GW)
  TARGET_DELETE_NAME="$NEW_GW"
  if ! az network vnet-gateway show -g "$RG" -n "$TARGET_DELETE_NAME" >/dev/null 2>&1; then
    TARGET_DELETE_NAME="${GW:-}"
  fi
  if [ -n "${TARGET_DELETE_NAME:-}" ] && az network vnet-gateway show -g "$RG" -n "$TARGET_DELETE_NAME" >/dev/null 2>&1; then
    CUR_GW_ID=$(az network vnet-gateway show -g "$RG" -n "$TARGET_DELETE_NAME" --query id -o tsv)
    delete_conns_for_gw "$RG" "$CUR_GW_ID"
    log "Deleting existing gateway $TARGET_DELETE_NAME ..."; az network vnet-gateway delete -g "$RG" -n "$TARGET_DELETE_NAME" || true
    wait_delete_gw "$RG" "$TARGET_DELETE_NAME"
  fi

  # Build PIP args 1/2/3
  PIP_ARGS=("$NEW_PIP"); [ -n "${NEW_PIP2:-}" ] && PIP_ARGS+=("$NEW_PIP2"); [ -n "${NEW_PIP3:-}" ] && PIP_ARGS+=("$NEW_PIP3")

  # Recreate gateway
  PASS_ASN=false; if [ -n "${ASN:-}" ] && [ "$ASN" != "None" ] && [ "$FINAL_SKU" != "Basic" ]; then PASS_ASN=true; fi
  log "Recreating gateway $NEW_GW with SKU=$FINAL_SKU ..."
  if [ "$PASS_ASN" = true ]; then
    az network vnet-gateway create -g "$RG" -n "$NEW_GW" --location "$LOC" \
      --public-ip-addresses "${PIP_ARGS[@]}" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" --asn "$ASN" || warn "Gateway create failed"
  else
    az network vnet-gateway create -g "$RG" -n "$NEW_GW" --location "$LOC" \
      --public-ip-addresses "${PIP_ARGS[@]}" --vnet "$VNET_NAME" \
      --gateway-type "$GTYPE" --vpn-type "$VTYPE" --sku "$FINAL_SKU" || warn "Gateway create failed"
  fi

  log "Waiting for gateway provisioningState..."
  for i in {1..60}; do
    state=$(az network vnet-gateway show -g "$RG" -n "$NEW_GW" --query provisioningState -o tsv 2>/dev/null || true)
    [ "$state" = "Succeeded" ] && break
    sleep 15
  done
  log "Gateway provisioningState: ${state:-unknown}"

  restore_p2s "$NEW_GW" "$RG" "$RESTORE_SRC"
  GW="$NEW_GW"
fi

# ---------------- Option 4: Restore connections only ----------------
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

  collect_connection_rename_plan_from_backup "$PLAN_FILE" "$RESTORE_SRC"
fi

# ---------------- Recreate connections from SRC ----------------
if [ -n "${RESTORE_SRC:-}" ]; then SRC="$RESTORE_SRC"; else SRC="$BACKUP_DIR"; fi

if [ -d "$SRC/conn-json" ]; then
  log "Recreating connections from $SRC ..."
  for CJ in "$SRC"/conn-json/*.json; do
    [ -s "$CJ" ] || continue
    C=$(jq -r '.name' "$CJ")
    NEW_CONN=$(lookup_new_conn_name "$PLAN_FILE" "$C")

    EN_BGP=$(jq -r '.enableBgp // false' "$CJ" 2>/dev/null || echo "false")
    USE_POLICY=$(jq -r '.usePolicyBasedTrafficSelectors // false' "$CJ" 2>/dev/null || echo "false")
    LNG_ID=$(jq -r '.localNetworkGateway2.id // empty' "$CJ" 2>/dev/null || true)
    VNG2_ID=$(jq -r '.virtualNetworkGateway2.id // empty' "$CJ" 2>/dev/null || true)
    PSK_FILE="$SRC/psk/$C.psk"; PSK=""; [ -s "$PSK_FILE" ] && PSK=$(cat "$PSK_FILE")

    if [ -n "$LNG_ID" ]; then
      log "  + $NEW_CONN (S2S to LocalNetworkGateway)"
      az network vpn-connection create \
        -g "$RG" -n "$NEW_CONN" \
        --vnet-gateway1 "$GW" \
        --local-gateway2 "$LNG_ID" \
        ${PSK:+--shared-key "$PSK"} \
        $( [ "$EN_BGP" = "true" ] && echo --enable-bgp ) \
        $( [ "$USE_POLICY" = "true" ] && echo --use-policy-based-traffic-selectors ) \
        >/dev/null || warn "    - create failed"
    elif [ -n "$VNG2_ID" ]; then
      log "  + $NEW_CONN (VNet-to-VNet)"
      az network vpn-connection create \
        -g "$RG" -n "$NEW_CONN" \
        --vnet-gateway1 "$GW" \
        --vnet-gateway2 "$VNG2_ID" \
        ${PSK:+--shared-key "$PSK"} \
        $( [ "$EN_BGP" = "true" ] && echo --enable-bgp ) \
        >/dev/null || warn "    - create failed"
    else
      warn "  ! Could not determine remote side for $C — inspect $CJ"
      continue
    fi

    # IPsec policies — CLI 2.76.0 requires --sa-max-size; default to 100MB if backup had 0
    POLCOUNT=$(jq -r '(.ipsecPolicies | length) // 0' "$CJ" 2>/dev/null || echo 0)
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
        log "    - Applying IPsec policy #$((idx+1)) to $NEW_CONN"
        az network vpn-connection ipsec-policy add \
          --resource-group "$RG" \
          --connection-name "$NEW_CONN" \
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
  echo; log "Backups live at: $SRC and $BACKUP_DIR"
fi