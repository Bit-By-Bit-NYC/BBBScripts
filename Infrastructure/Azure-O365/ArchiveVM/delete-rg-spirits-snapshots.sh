#!/usr/bin/env bash
# delete-rg-spirits-snapshots.sh
# Default: DRY RUN. Use --apply to actually revoke SAS & delete.
# Extras:
#   --debug      bash -x + 'az --debug'
#   --verbose    more progress
#   --retries N  delete retries (default 2)
#   --unlock     remove resource locks on snapshots before delete

set -o pipefail

SUBSCRIPTION_ID="5a8f2111-71ad-42fb-a6e1-58d3676ca6ad"
RESOURCE_GROUP="rg-spirits"

APPLY=0
DEBUG=0
VERBOSE=0
RETRIES=2
UNLOCK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --debug) DEBUG=1; shift;;
    --verbose|-v) VERBOSE=1; shift;;
    --retries) RETRIES="${2:-2}"; shift 2;;
    --unlock) UNLOCK=1; shift;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ $DEBUG -eq 1 ]] && set -x

TS="$(date '+%Y%m%d_%H%M%S')"
LOGFILE="snapshot_delete_${RESOURCE_GROUP}_${TS}.log"
CSVFILE="snapshot_delete_${RESOURCE_GROUP}_${TS}.csv"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOGFILE" >&2; }
vlog() { [[ $VERBOSE -eq 1 ]] && log "$@"; }

echo "timestamp,snapshot,action,result,details" > "$CSVFILE"

run_az() {
  local cmd=("$@")
  local out rc
  if [[ $DEBUG -eq 1 ]]; then
    [[ " ${cmd[*]} " != *" --debug "* ]] && cmd+=("--debug")
  else
    cmd+=("--only-show-errors")
  fi
  out="$({ "${cmd[@]}" 2> >(tee -a "$LOGFILE" >&2); rc=$?; cat; exit $rc; } < /dev/null)"
  rc=$?
  printf '%s' "$out"
  return $rc
}

log "==> Subscription: $SUBSCRIPTION_ID"
log "==> Resource Group: $RESOURCE_GROUP"
log "==> Mode: $([[ $APPLY -eq 1 ]] && echo 'APPLY' || echo 'DRY RUN')"
log "==> Retries: $RETRIES   Unlock: $UNLOCK"
log "Logs: $LOGFILE"
log "CSV : $CSVFILE"
echo >> "$LOGFILE"

if ! run_az az account set --subscription "$SUBSCRIPTION_ID" >/dev/null; then
  log "ERROR: Unable to set subscription."
  exit 1
fi

log "Fetching snapshots..."
SNAP_JSON="$(run_az az snapshot list -g "$RESOURCE_GROUP" --query '[].{name:name, sizeGb:diskSizeGb, time:timeCreated, id:id}' -o json)" || {
  log "ERROR: Could not list snapshots."
  exit 1
}
COUNT="$(printf '%s' "$SNAP_JSON" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  log "No snapshots found in '$RESOURCE_GROUP'."
  exit 0
fi
log "Found $COUNT snapshot(s):"
printf '%s' "$SNAP_JSON" | jq -r '.[] | "- \(.name) | Size: \(.sizeGb) GiB | Created: \(.time)"' | tee -a "$LOGFILE"
echo

if [[ $APPLY -eq 0 ]]; then
  log "DRY RUN COMPLETE. Re-run with --apply to proceed."
  exit 0
fi

read -r -p "Type the resource group name ('$RESOURCE_GROUP') to confirm deletion: " CONFIRM_RG
[[ "$CONFIRM_RG" == "$RESOURCE_GROUP" ]] || { log "Confirmation mismatch. Aborting."; exit 1; }

FAILED=0
SUCCEEDED=0

maybe_unlock() {
  local snap="$1"
  [[ $UNLOCK -eq 0 ]] && return 0
  # Find locks scoped to the snapshot
  local locks
  locks="$(run_az az lock list -g "$RESOURCE_GROUP" --query "[?contains(scope, '${snap}')]" -o json)" || return 0
  local lcount; lcount="$(printf '%s' "$locks" | jq 'length')"
  if (( lcount > 0 )); then
    log "Found $lcount lock(s) on $snap; removing…"
    printf '%s' "$locks" | jq -r '.[].name' | while read -r lname; do
      [[ -z "$lname" ]] && continue
      run_az az lock delete -g "$RESOURCE_GROUP" -n "$lname" || log "WARN: Failed to delete lock $lname on $snap"
    done
  fi
}

delete_with_verify() {
  local snap="$1"
  local attempt=0
  local sleep_s=3

  vlog "Revoking SAS for $snap…"
  if run_az az snapshot revoke-access -g "$RESOURCE_GROUP" -n "$snap" >/dev/null; then
    log "SAS revoke OK for $snap"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$snap,revoke-access,success," >> "$CSVFILE"
  else
    log "WARN: revoke-access failed or no SAS for $snap (see log)."
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$snap,revoke-access,warn,see_log" >> "$CSVFILE"
  fi

  maybe_unlock "$snap"

  while (( attempt <= RETRIES )); do
    vlog "Deleting $snap (attempt $((attempt+1)) of $((RETRIES+1)))…"
    # NOTE: no --yes here (not supported by az snapshot delete)
    if run_az az snapshot delete -g "$RESOURCE_GROUP" -n "$snap" >/dev/null; then
      vlog "Delete command returned success for $snap; verifying…"
    else
      log "WARN: az delete returned non-zero for $snap; verifying anyway…"
    fi

    # If show succeeds, it still exists. If show fails (non-zero), it's gone.
    if run_az az snapshot show -g "$RESOURCE_GROUP" -n "$snap" -o none >/dev/null 2>&1; then
      log "Verify: $snap still exists."
      (( attempt++ ))
      if (( attempt <= RETRIES )); then
        log "Retrying $snap after ${sleep_s}s…"
        sleep "$sleep_s"
        sleep_s=$((sleep_s*2))
        continue
      else
        log "ERROR: $snap still present after retries."
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$snap,delete,failed,still_present_after_retries" >> "$CSVFILE"
        return 1
      fi
    else
      log "Deleted & verified: $snap"
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$snap,delete,success,verified_not_found" >> "$CSVFILE"
      return 0
    fi
  done
}

log "Starting revoke + (optional unlock) + delete + verify…"
printf '%s' "$SNAP_JSON" | jq -r '.[].name' | while read -r SNAPNAME; do
  [[ -z "$SNAPNAME" ]] && continue
  log "---- Snapshot: $SNAPNAME ----"
  if delete_with_verify "$SNAPNAME"; then
    ((SUCCEEDED++))
  else
    ((FAILED++))
  fi
done

log "---- Summary ----"
log "Succeeded: $SUCCEEDED"
log "Failed   : $FAILED"
log "Log file : $LOGFILE"
log "CSV file : $CSVFILE"

[[ $FAILED -gt 0 ]] && exit 2 || exit 0