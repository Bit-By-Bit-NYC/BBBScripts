#!/usr/bin/env bash
# Cost estimator for archived VM VHDs
# - Handles Archive early deletion penalty (Archive minimum days; default 180; assume restored on day 2).
# - Computes per-blob: Monthly$ (Archive), Rehydrate$, CoolWindow$, Tx$, EarlyPenalty$, TotalRestore$.
# - Prompts for account/containers/rg with sensible defaults.
# - DEBUG mode shows blob listings.
# Works on macOS (bash/zsh): run with bash

set -euo pipefail

# -------------------- DEFAULTS (prompted below) --------------------
DEF_RG="rg-Spirits-1022621"
DEF_ACCT="storspirits1022621"
DEF_COLD_CONT="archive-cold"
DEF_HOT_CONT="archive"

# -------------------- PRICING (EDIT IF NEEDED) --------------------
# Storage (USD per GiB-month)
ARCH_PER_GB="0.0012"      # Archive tier $/GiB-month
COOL_PER_GB="0.0100"      # Cool tier $/GiB-month (used during rehydrate window)
HOT_PER_GB="0.0200"       # Hot tier $/GiB-month (if any BlockBlobs in 'archive')
PAGE_PER_GB="0.0500"      # PageBlob $/GiB-month (for hot 'archive' page VHDs)

# Rehydrate/read handling (one-time)
ARCH_REHYDRATE_PER_GB="0.0200"   # $/GiB data retrieval from Archive
REHYDRATE_HOURS="12"             # hours at Cool while rehydrating

# API transaction costs (rough estimates)
TX_READ_PER_10K="0.004"          # $ per 10k read ops
TX_WRITE_PER_10K="0.050"         # $ per 10k write ops
BLOCK_BLOB_BLOCK_MB="8"          # read chunk ~8 MiB (BlockBlob downloads)
PAGE_BLOB_PUT_MB="4"             # write chunk ~4 MiB (PageBlob writes on restore)

# Archive early deletion policy
ARCH_MIN_DAYS="180"              # minimum chargeable days for Archive
ASSUMED_DAYS_KEPT="2"            # restored on day 2 (so 178 days early)

# -------------------- PROMPTS --------------------
read -r -p "Resource Group [$DEF_RG]: " RG;                     RG=${RG:-$DEF_RG}
read -r -p "Storage Account [$DEF_ACCT]: " ACCT;                ACCT=${ACCT:-$DEF_ACCT}
read -r -p "Cold container (BlockBlob@Archive) [$DEF_COLD_CONT]: " COLD_CONT; COLD_CONT=${COLD_CONT:-$DEF_COLD_CONT}
read -r -p "Hot container (PageBlob) [$DEF_HOT_CONT]: " HOT_CONT; HOT_CONT=${HOT_CONT:-$DEF_HOT_CONT}
read -r -p "Assumed days kept in Archive before restore [$ASSUMED_DAYS_KEPT]: " DAYS_KEPT; DAYS_KEPT=${DAYS_KEPT:-$ASSUMED_DAYS_KEPT}
read -r -p "Show DEBUG listings? [y/N]: " DBG;                  DBG=${DBG:-N}
read -r -p "Write CSV and upload to _runs/? [y/N]: " WANTCSV;   WANTCSV=${WANTCSV:-N}

# -------------------- HELPERS --------------------
hr() { printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }
trim() { printf "%s" "$1" | tr -d '\r'; }
bytes_to_gib() { awk 'BEGIN{b='"${1:-0}"'; printf("%.2f", b/1024/1024/1024)}'; }
ceil_div() { awk 'BEGIN{a='"$1"'+0; b='"$2"'+0; printf("%d", (a/b == int(a/b))? a/b : int(a/b)+1)}'; }

list_blobs_tsv() {
  # TSV: name<TAB>bytes<TAB>blobType<TAB>blobTier
  local cont="$1"
  local out
  out="$(az storage blob list \
          --account-name "$ACCT" --auth-mode login -c "$cont" --num-results 5000 \
          --query "[].[name, properties.contentLength, properties.blobType, properties.blobTier]" \
          -o tsv 2>/dev/null || true)"
  out="$(trim "${out:-}")"
  if [ -z "${out//[[:space:]]/}" ] || echo "$out" | grep -qx 'null'; then
    return 1
  fi
  printf "%s\n" "$out"
}

calc_tx_costs() {
  # echo: READ_OPS WRITE_OPS READ_$ WRITE_$ TOTAL_$
  local BYTES="$1"
  local blk_bytes=$(( BLOCK_BLOB_BLOCK_MB * 1024 * 1024 ))
  local page_bytes=$(( PAGE_BLOB_PUT_MB  * 1024 * 1024 ))
  local READ_OPS WRITE_OPS READ_D WRITE_D TOTAL

  READ_OPS="$(ceil_div "$BYTES" "$blk_bytes")"
  WRITE_OPS="$(ceil_div "$BYTES" "$page_bytes")"

  READ_D=$(awk -v ops="$READ_OPS"  -v rate="$TX_READ_PER_10K"  'BEGIN{printf("%.4f", (ops/10000.0)*rate)}')
  WRITE_D=$(awk -v ops="$WRITE_OPS" -v rate="$TX_WRITE_PER_10K" 'BEGIN{printf("%.4f", (ops/10000.0)*rate)}')
  TOTAL=$(awk -v r="$READ_D" -v w="$WRITE_D" 'BEGIN{printf("%.4f", r+w)}')

  echo "$READ_OPS $WRITE_OPS $READ_D $WRITE_D $TOTAL"
}

calc_early_penalty() {
  # early penalty = Archive rate * GiB * max(0, MIN_DAYS - DAYS_KEPT) / 30
  local GIB="$1"
  awk -v g="$GIB" -v rate="$ARCH_PER_GB" -v min="$ARCH_MIN_DAYS" -v kept="$DAYS_KEPT" \
      'BEGIN{rem = (min>kept? (min-kept):0); printf("%.2f", g*rate*(rem/30.0))}'
}

timestamp_utc() { date -u '+%Y%m%dT%H%M%SZ'; }

# -------------------- DEBUG LISTINGS --------------------
if [[ "$DBG" =~ ^[Yy]$ ]]; then
  echo
  echo "=== Diagnostics: Listing first few blob names ==="
  for CONT in "$COLD_CONT" "$HOT_CONT"; do
    echo
    echo "Container: $ACCT/$CONT"
    if LIST=$(list_blobs_tsv "$CONT"); then
      COUNT=$(printf "%s\n" "$LIST" | wc -l | tr -d ' ')
      echo "Total blobs returned (up to 5000): $COUNT"
      echo "First 20 names:"
      printf "%s\n" "$LIST" | cut -f1 | head -20
    else
      echo "Total blobs returned: 0"
      echo "(none)"
    fi
  done
fi

echo
echo "=== Cost tables (RG=$RG, SA=$ACCT) ==="

# -------------------- ARCHIVE-COLD TABLE --------------------
echo "ARCHIVE-COLD (all *.vhd; Archive monthly + Rehydrate + CoolWindow + Tx + EarlyPenalty)"
hr 190
printf "%-85s  %6s  %-9s  %-9s  %10s  %10s  %11s  %9s  %9s  %8s  %12s  %13s\n" \
  "Blob Name" "GiB" "BlobType" "Tier" "Monthly$" "Rehydrate$" "CoolWindow$" "RdOps" "WrOps" "Tx$" "EarlyPenalty$" "TotalRestore$"
hr 190

TOTAL_BYTES_ARCH=0
SUM_MONTHLY_ARCH=0
SUM_REHYD_ARCH=0
SUM_COOLWIN_ARCH=0
SUM_TX_ARCH=0
SUM_EARLY_ARCH=0
SUM_TOTALRESTORE_ARCH=0

CSV_PATH=""
if [[ "$WANTCSV" =~ ^[Yy]$ ]]; then
  RUN_TS="$(timestamp_utc)"
  CSV_PATH="./costs_${ACCT}_${RUN_TS}.csv"
  echo "name,bytes,GiB,blobType,blobTier,Monthly$,Rehydrate$,CoolWindow$,ReadOps,WriteOps,Tx$,EarlyPenalty$,TotalRestore$" > "$CSV_PATH"
fi

if LIST=$(list_blobs_tsv "$COLD_CONT"); then
  while IFS=$'\t' read -r NAME BYTES BTYPE BTIER; do
    case "$NAME" in *.vhd) ;; *) continue ;; esac
    BYTES="${BYTES:-0}"
    GIB=$(bytes_to_gib "$BYTES")

    MONTHLY=$(awk -v g="$GIB" -v r="$ARCH_PER_GB" 'BEGIN{printf("%.2f", g*r)}')
    REHYD=$(awk -v g="$GIB" -v r="$ARCH_REHYDRATE_PER_GB" 'BEGIN{printf("%.2f", g*r)}')
    COOLWIN=$(awk -v g="$GIB" -v r="$COOL_PER_GB" -v h="$REHYDRATE_HOURS" 'BEGIN{printf("%.2f", g*r*(h/720.0))}')
    read READ_OPS WRITE_OPS READ_D WRITE_D TX_D <<<"$(calc_tx_costs "$BYTES")"
    EARLY=$(calc_early_penalty "$GIB")
    TOTAL_RESTORE=$(awk -v a="$REHYD" -v b="$COOLWIN" -v c="$TX_D" -v d="$EARLY" 'BEGIN{printf("%.2f", a+b+c+d)}')

    printf "%-85s  %6.2f  %-9s  %-9s  $%9s  $%9s  $%10s  %9s  %9s  $%7s  $%11s  $%12s\n" \
      "$NAME" "$GIB" "${BTYPE:-}" "${BTIER:-}" "$MONTHLY" "$REHYD" "$COOLWIN" "$READ_OPS" "$WRITE_OPS" "$TX_D" "$EARLY" "$TOTAL_RESTORE"

    TOTAL_BYTES_ARCH=$((TOTAL_BYTES_ARCH + BYTES))
    SUM_MONTHLY_ARCH=$(awk -v a="$SUM_MONTHLY_ARCH" -v b="$MONTHLY" 'BEGIN{printf("%.2f", a+b)}')
    SUM_REHYD_ARCH=$(awk -v a="$SUM_REHYD_ARCH" -v b="$REHYD" 'BEGIN{printf("%.2f", a+b)}')
    SUM_COOLWIN_ARCH=$(awk -v a="$SUM_COOLWIN_ARCH" -v b="$COOLWIN" 'BEGIN{printf("%.2f", a+b)}')
    SUM_TX_ARCH=$(awk -v a="$SUM_TX_ARCH" -v b="$TX_D" 'BEGIN{printf("%.2f", a+b)}')
    SUM_EARLY_ARCH=$(awk -v a="$SUM_EARLY_ARCH" -v b="$EARLY" 'BEGIN{printf("%.2f", a+b)}')
    SUM_TOTALRESTORE_ARCH=$(awk -v a="$SUM_TOTALRESTORE_ARCH" -v b="$TOTAL_RESTORE" 'BEGIN{printf("%.2f", a+b)}')

    if [[ "$WANTCSV" =~ ^[Yy]$ ]]; then
      echo "\"$NAME\",$BYTES,$GIB,\"$BTYPE\",\"$BTIER\",$MONTHLY,$REHYD,$COOLWIN,$READ_OPS,$WRITE_OPS,$TX_D,$EARLY,$TOTAL_RESTORE" >> "$CSV_PATH"
    fi
  done <<< "$LIST"
fi

TOTAL_GIB_ARCH=$(bytes_to_gib "$TOTAL_BYTES_ARCH")
hr 190
printf "%-85s  %6.2f  %-9s  %-9s  $%10s  $%10s  $%11s  %9s  %9s  $%8s  $%12s  $%13s\n" \
  "TOTAL" "$TOTAL_GIB_ARCH" "" "" "$SUM_MONTHLY_ARCH" "$SUM_REHYD_ARCH" "$SUM_COOLWIN_ARCH" "" "" "$SUM_TX_ARCH" "$SUM_EARLY_ARCH" "$SUM_TOTALRESTORE_ARCH"

echo
# -------------------- HOT (PAGE) TABLE --------------------
echo "HOT CONTAINER (all *.vhd; PageBlob uses PAGE_PER_GB; BlockBlob priced by tier if present)"
hr 130
printf "%-85s  %6s  %-9s  %-9s  %10s\n" \
  "Blob Name" "GiB" "BlobType" "Tier" "Monthly$"
hr 130

TOTAL_BYTES_HOT=0
SUM_MONTHLY_HOT=0

if LIST=$(list_blobs_tsv "$HOT_CONT"); then
  while IFS=$'\t' read -r NAME BYTES BTYPE BTIER; do
    case "$NAME" in *.vhd) ;; *) continue ;; esac
    BYTES="${BYTES:-0}"
    GIB=$(bytes_to_gib "$BYTES")

    MONTHLY="0.00"
    if [ "${BTYPE:-}" = "PageBlob" ]; then
      MONTHLY=$(awk -v g="$GIB" -v r="$PAGE_PER_GB" 'BEGIN{printf("%.2f", g*r)}')
    else
      case "${BTIER:-}" in
        Archive|archive|ARCHIVE|Cold|cold|COLD)
          MONTHLY=$(awk -v g="$GIB" -v r="$ARCH_PER_GB" 'BEGIN{printf("%.2f", g*r)}');;
        Cool|cool|COOL)
          MONTHLY=$(awk -v g="$GIB" -v r="$COOL_PER_GB" 'BEGIN{printf("%.2f", g*r)}');;
        Hot|hot|HOT|"")
          MONTHLY=$(awk -v g="$GIB" -v r="$HOT_PER_GB"  'BEGIN{printf("%.2f", g*r)}');;
      esac
    fi

    printf "%-85s  %6.2f  %-9s  %-9s  $%9s\n" \
      "$NAME" "$GIB" "${BTYPE:-}" "${BTIER:-}" "$MONTHLY"

    TOTAL_BYTES_HOT=$((TOTAL_BYTES_HOT + BYTES))
    SUM_MONTHLY_HOT=$(awk -v a="$SUM_MONTHLY_HOT" -v b="$MONTHLY" 'BEGIN{printf("%.2f", a+b)}')
  done <<< "$LIST"
fi

TOTAL_GIB_HOT=$(bytes_to_gib "$TOTAL_BYTES_HOT")
hr 130
printf "%-85s  %6.2f  %-9s  %-9s  $%9s\n" \
  "TOTAL" "$TOTAL_GIB_HOT" "" "" "$SUM_MONTHLY_HOT"

# -------------------- OPTIONAL CSV UPLOAD --------------------
if [[ "$WANTCSV" =~ ^[Yy]$ ]]; then
  echo
  echo "CSV written: $CSV_PATH"
  read -r -p "Upload CSV to 'https://$ACCT.blob.core.windows.net/$HOT_CONT/_runs/<ts>/costs.csv'? [y/N]: " UP
  UP=${UP:-N}
  if [[ "$UP" =~ ^[Yy]$ ]]; then
    TS="$(timestamp_utc)"
    DEST="https://${ACCT}.blob.core.windows.net/${HOT_CONT}/_runs/${TS}/costs.csv"
    echo "Uploading to: $DEST"
    azcopy copy "$CSV_PATH" "$DEST" --overwrite=true >/dev/null
    echo "Upload complete."
  fi
fi

echo
echo "Notes:"
echo " - EarlyPenalty$ = Archive rate * GiB * max(0, $ARCH_MIN_DAYS - days_kept)/30. With days_kept=$DAYS_KEPT, penalty assumes early removal on day $DAYS_KEPT."
echo " - Rehydrate$ is a one-time retrieval charge; CoolWindow$ assumes $REHYDRATE_HOURS hours in Cool during rehydrate."
echo " - Tx$ ~ API ops (rough): reads ≈ ceil(size/${BLOCK_BLOB_BLOCK_MB}MiB), writes ≈ ceil(size/${PAGE_BLOB_PUT_MB}MiB)."
echo " - Adjust the PRICING variables at the top to your contracted rates and region."

