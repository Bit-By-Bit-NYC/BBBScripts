#!/usr/bin/env bash
#
# Clone all custom rules from one NSG to another region.
# Requires: az cli + jq in Cloud Shell or any Linux/WSL.

set -euo pipefail

SRC_RG="rg-3bexam-network"          # EAST RG with the source NSG
SRC_NSG="nsg-3bexam-servers"        # EAST NSG name

DST_RG="RG-3BEXAM-SERVERS-asr"      # WEST RG (must already exist)
DST_NSG="nsg-3bexam-servers-west"   # WEST NSG name
DST_LOC="westus"

echo "== Creating destination NSG =="
az network nsg create -g "$DST_RG" -n "$DST_NSG" -l "$DST_LOC" -o none

echo "== Copying any tags =="
SRC_TAGS_JSON=$(az network nsg show -g "$SRC_RG" -n "$SRC_NSG" --query tags -o json)
if [ "$SRC_TAGS_JSON" != "null" ]; then
  TAGS=$(echo "$SRC_TAGS_JSON" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(" ")')
  [ -n "$TAGS" ] && az network nsg update -g "$DST_RG" -n "$DST_NSG" --tags $TAGS -o none
fi

echo "== Cloning custom rules =="
az network nsg show -g "$SRC_RG" -n "$SRC_NSG" --query "securityRules" -o json |
jq -c '.[]' | while read -r r; do
  NAME=$(echo "$r" | jq -r '.name')
  PRIORITY=$(echo "$r" | jq -r '.priority')
  DIRECTION=$(echo "$r" | jq -r '.direction')
  ACCESS=$(echo "$r" | jq -r '.access')
  PROTOCOL=$(echo "$r" | jq -r '.protocol')
  DESCRIPTION=$(echo "$r" | jq -r '.description // empty')

  SRC_ADDRS=$(echo "$r" | jq -r '(.sourceAddressPrefixes // empty) | join(" ")')
  DST_ADDRS=$(echo "$r" | jq -r '(.destinationAddressPrefixes // empty) | join(" ")')
  [ -z "$SRC_ADDRS" ] && SRC_ADDRS=$(echo "$r" | jq -r '.sourceAddressPrefix // empty')
  [ -z "$DST_ADDRS" ] && DST_ADDRS=$(echo "$r" | jq -r '.destinationAddressPrefix // empty')

  SRC_PORTS=$(echo "$r" | jq -r '(.sourcePortRanges // empty) | join(" ")')
  DST_PORTS=$(echo "$r" | jq -r '(.destinationPortRanges // empty) | join(" ")')
  [ -z "$SRC_PORTS" ] && SRC_PORTS=$(echo "$r" | jq -r '.sourcePortRange // empty')
  [ -z "$DST_PORTS" ] && DST_PORTS=$(echo "$r" | jq -r '.destinationPortRange // empty')

  # skip flags when value is "*" or empty
  SA_ARG=(); [ -n "$SRC_ADDRS" ] && [ "$SRC_ADDRS" != "*" ] && SA_ARG=(--source-address-prefixes $SRC_ADDRS)
  DA_ARG=(); [ -n "$DST_ADDRS" ] && [ "$DST_ADDRS" != "*" ] && DA_ARG=(--destination-address-prefixes $DST_ADDRS)
  SP_ARG=(); [ -n "$SRC_PORTS" ] && [ "$SRC_PORTS" != "*" ] && SP_ARG=(--source-port-ranges $SRC_PORTS)
  DP_ARG=(); [ -n "$DST_PORTS" ] && [ "$DST_PORTS" != "*" ] && DP_ARG=(--destination-port-ranges $DST_PORTS)
  DESC_ARG=(); [ -n "$DESCRIPTION" ] && DESC_ARG=(--description "$DESCRIPTION")

  echo "Cloning rule: $NAME"
  az network nsg rule create \
    -g "$DST_RG" --nsg-name "$DST_NSG" -n "$NAME" \
    --priority "$PRIORITY" --direction "$DIRECTION" --access "$ACCESS" --protocol "$PROTOCOL" \
    "${SA_ARG[@]}" "${DA_ARG[@]}" "${SP_ARG[@]}" "${DP_ARG[@]}" "${DESC_ARG[@]}" -o none
done

echo "== Finished. Rules on $DST_NSG =="
az network nsg rule list -g "$DST_RG" --nsg-name "$DST_NSG" -o table