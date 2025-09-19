#!/usr/bin/env bash
# delete-rg-spirits-snapshots.sh
# Default: DRY RUN. Use --apply to actually revoke SAS and delete snapshots.

set -o pipefail

SUBSCRIPTION_ID="5a8f2111-71ad-42fb-a6e1-58d3676ca6ad"
RESOURCE_GROUP="rg-spirits"

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

echo "==> Target subscription: $SUBSCRIPTION_ID"
echo "==> Target resource group: $RESOURCE_GROUP"
echo "==> Mode: $([[ $APPLY -eq 1 ]] && echo 'APPLY (revoke SAS + delete)' || echo 'DRY RUN (no changes)')"
echo

# Ensure we’re on the correct subscription
az account set --subscription "$SUBSCRIPTION_ID" --only-show-errors

# Get snapshots list
echo "Fetching snapshots..."
SNAP_JSON=$(az snapshot list -g "$RESOURCE_GROUP" --query '[].{name:name, sizeGb:diskSizeGb, time:timeCreated, id:id}' -o json --only-show-errors)

COUNT=$(echo "$SNAP_JSON" | jq 'length')
if [[ "$COUNT" -eq 0 ]]; then
  echo "No snapshots found in resource group '$RESOURCE_GROUP'. Nothing to do."
  exit 0
fi

echo "Found $COUNT snapshot(s):"
echo "$SNAP_JSON" | jq -r '.[] | "- \(.name) | Size: \(.sizeGb) GiB | Created: \(.time)"'
echochmod

if [[ $APPLY -eq 0 ]]; then
  echo "DRY RUN COMPLETE. No changes were made."
  echo "To actually revoke any active SAS URLs and delete these snapshots, re-run with:  ./delete-rg-spirits-snapshots.sh --apply"
  exit 0
fi

# Safety prompt
read -r -p "Type the resource group name ('$RESOURCE_GROUP') to confirm deletion: " CONFIRM_RG
if [[ "$CONFIRM_RG" != "$RESOURCE_GROUP" ]]; then
  echo "Confirmation mismatch. Aborting."
  exit 1
fi

FAILED=0

# Process each snapshot
echo
echo "Starting revoke + delete process..."
echo

# Iterate using jq to safely handle names
echo "$SNAP_JSON" | jq -r '.[].name' | while read -r SNAPNAME; do
  [[ -z "$SNAPNAME" ]] && continue
  echo "----"
  echo "Snapshot: $SNAPNAME"

  # Revoke any active SAS (will no-op if none active)
  echo "  - Revoking any active SAS access (grant-access)..."
  if az snapshot revoke-access -g "$RESOURCE_GROUP" -n "$SNAPNAME" --only-show-errors >/dev/null 2>&1; then
    echo "    Revoked SAS (or none was active)."
  else
    # Most often, failure here just means no active SAS; we continue either way.
    echo "    Note: Could not confirm revoke; likely no active SAS. Continuing."
  fi

  # Delete the snapshot
  echo "  - Deleting snapshot..."
  if az snapshot delete -g "$RESOURCE_GROUP" -n "$SNAPNAME" --yes --only-show-errors >/dev/null 2>&1; then
    echo "    Deleted."
  else
    echo "    ERROR: Failed to delete snapshot '$SNAPNAME'."
    FAILED=$((FAILED+1))
  fi
done

echo "----"
if [[ $FAILED -gt 0 ]]; then
  echo "Completed with $FAILED failure(s). Check messages above for details."
  exit 2
else
  echo "All snapshots processed and deleted successfully."
fi