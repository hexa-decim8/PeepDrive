#!/usr/bin/env bash
# peepdrive.sh
# Strictly read-only script to collect LVM topology and disk info
# Writes a pretty text report to a file. DOES NOT MODIFY LVM or disks.

set -euo pipefail

OUT_FILE="peepdrive.txt"
HUMAN=false
VG_FILTER=""

usage() {
  cat <<EOF
Usage: $0 [--vg VGNAME] [--output FILE]
  --vg VGNAME    Only report on the specified volume group
  --output FILE  Path to output report (default: peepdrive.txt)
  --help         Show this help

Note: This script is strictly read-only. It will not change any LVM or
device state. Some queries may require root privileges to read device
attributes; re-run with sudo if permission errors occur.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vg) VG_FILTER="$2"; shift 2;;
    --output) OUT_FILE="$2"; shift 2;;
    --human) HUMAN=true; shift 1;;
    --help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

SEP=$(printf '\x1f')

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 3
  fi
}

# Required read-only tools
for cmd in vgs pvs lvs pvdisplay vgcfgbackup lsblk readlink awk sed grep; do
  require_cmd "$cmd"
done

to_gib() {
  # Convert bytes to GiB (1024^3) with two decimals.
  # Accept empty or non-numeric as 0.
  # Strip any trailing unit suffix like "B" from LVM output.
  bytes=${1:-0}
  # Remove any non-digit characters (like "B" suffix)
  bytes=$(echo "$bytes" | sed 's/[^0-9]//g')
  # ensure numeric
  if [ -z "$bytes" ] || ! printf "%s" "$bytes" | grep -Eq '^[0-9]+$'; then
    bytes=0
  fi
  awk -v b="$bytes" 'BEGIN{printf("%.2f GiB", b/(1024*1024*1024))}'
}

echo "Generating read-only LVM report..."

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

echo "Report generated: $(timestamp)" > "$OUT_FILE"
echo "Hostname: $(hostname)" >> "$OUT_FILE"
echo "================================================================================" >> "$OUT_FILE"
echo "" >> "$OUT_FILE"

# Get VGs
VG_LINES=$(if [ -z "$VG_FILTER" ]; then
  vgs --noheadings --units b --separator "$SEP" -o vg_name,vg_uuid,vg_size || true
else
  vgs --noheadings --units b --separator "$SEP" -o vg_name,vg_uuid,vg_size --select vg_name="$VG_FILTER" || true
fi)

if [ -z "$VG_LINES" ]; then
  echo "No volume groups found or accessible." >> "$OUT_FILE"
  echo "Wrote: $OUT_FILE"
  exit 0
fi

echo "$VG_LINES" | awk -v RS="\n" -v FS="$SEP" '{gsub(/^ +| +$/,"",$1); print $1 "|" $2 "|" $3}' | while IFS='|' read -r VG VGUUID VGSIZE; do
  echo "" >> "$OUT_FILE"
  echo "################################################################################" >> "$OUT_FILE"
  echo "VG: $VG" >> "$OUT_FILE"
  echo "################################################################################" >> "$OUT_FILE"
  echo "  UUID: $VGUUID" >> "$OUT_FILE"
  echo "  Size: $(to_gib "$VGSIZE")" >> "$OUT_FILE"
  echo "  Report time (UTC): $(timestamp)" >> "$OUT_FILE"
  echo "" >> "$OUT_FILE"

  # Determine PV order via vgcfgbackup
  PV_ORDER=()
  if vgcfgbackup -f - "$VG" >/dev/null 2>&1; then
    # capture devices in order
    while IFS= read -r line; do
      case "$line" in
        *"device = "*) dev=$(echo "$line" | sed -n "s/.*device = \"\(.*\)\".*/\1/p"); PV_ORDER+=("$dev") ;;
      esac
    done < <(vgcfgbackup -f - "$VG")
  fi
  
  # If still empty, try pvs without --select (more compatible)
  if [ ${#PV_ORDER[@]} -eq 0 ]; then
    while IFS= read -r pvline; do
      # Parse: pv_name|vg_name
      pv_name=$(echo "$pvline" | awk -v FS="$SEP" '{print $1}')
      pv_vg=$(echo "$pvline" | awk -v FS="$SEP" '{print $2}')
      # Filter by VG name manually
      if [ "$pv_vg" = "$VG" ] || echo "$pv_vg" | grep -q "^[[:space:]]*$VG[[:space:]]*$"; then
        pv_name_trim=$(echo "$pv_name" | sed 's/^ *//;s/ *$//')
        PV_ORDER+=("$pv_name_trim")
      fi
    done < <(pvs --noheadings --units b --separator "$SEP" -o pv_name,vg_name 2>/dev/null)
  fi

  if [ ${#PV_ORDER[@]} -eq 0 ]; then
    echo "  Warning: could not determine PV order for $VG" >> "$OUT_FILE"
    echo "  (This may indicate no PVs are associated with this VG or a permissions issue)" >> "$OUT_FILE"
  else
    echo "  Physical volumes (in VG metadata order):" >> "$OUT_FILE"
    idx=1
    for pv in "${PV_ORDER[@]}"; do
      pv_trim=$(echo "$pv" | sed 's/^ *//;s/ *$//')
      pvcanon=$(readlink -f "$pv_trim" 2>/dev/null || printf "%s" "$pv_trim")
      pv_uuid=$(pvs --noheadings --units b --separator "$SEP" -o pv_uuid --select pv_name="$pv_trim" 2>/dev/null | awk -v FS="$SEP" '{gsub(/^ +| +$/,"",$1); print $1}')
      pv_size=$(lsblk -b -ndo SIZE --paths "$pvcanon" 2>/dev/null || echo "0")
      echo "    $idx) $pv_trim" >> "$OUT_FILE"
      echo "       Canonical: $pvcanon" >> "$OUT_FILE"
      echo "       UUID: ${pv_uuid:-unknown}" >> "$OUT_FILE"
      echo "       Size: $(to_gib "$pv_size")" >> "$OUT_FILE"

      # Which LVs use this PV? (read-only)
      echo -n "       LVs: " >> "$OUT_FILE"
      # Query all LVs with their PV associations, then filter for this PV
      lvlist=$(lvs --noheadings --units b --separator "$SEP" -o lv_name,vg_name,devices 2>/dev/null | while IFS= read -r lvline; do
        lv_name=$(echo "$lvline" | awk -v FS="$SEP" '{print $1}' | sed 's/^ *//;s/ *$//')
        lv_vg=$(echo "$lvline" | awk -v FS="$SEP" '{print $2}' | sed 's/^ *//;s/ *$//')
        lv_devs=$(echo "$lvline" | awk -v FS="$SEP" '{print $3}' | sed 's/^ *//;s/ *$//')
        # Check if this LV is in current VG and uses current PV
        if [ "$lv_vg" = "$VG" ] && echo "$lv_devs" | grep -q "$pv_trim"; then
          echo "$lv_name"
        fi
      done | tr '\n' ',' | sed 's/,$//')
      if [ -z "$lvlist" ]; then lvlist="(none)"; fi
      echo "$lvlist" >> "$OUT_FILE"

      idx=$((idx+1))
    done

    # Also present a concise order summary and a simple flow representation
    order_line=""
    flow_line="$VG"
    for i in "${!PV_ORDER[@]}"; do
      p=${PV_ORDER[$i]}
      p_trim=$(echo "$p" | sed 's/^ *//;s/ *$//')
      if [ -n "$order_line" ]; then order_line="$order_line, "; fi
      order_line="$order_line$((i+1)): $p_trim"
      flow_line="$flow_line -> $p_trim"
    done
    echo "" >> "$OUT_FILE"
    echo "  ────────────────────────────────────────────────────────────────────────────────" >> "$OUT_FILE"
    echo "  PV order summary: $order_line" >> "$OUT_FILE"
    echo "  Flow: $flow_line" >> "$OUT_FILE"
    echo "  ────────────────────────────────────────────────────────────────────────────────" >> "$OUT_FILE"
  fi

  echo "" >> "$OUT_FILE"
  echo "" >> "$OUT_FILE"
  echo "  ───────────────────────────────────────────────────────────────────────────────" >> "$OUT_FILE"
  echo "  Logical volumes in $VG:" >> "$OUT_FILE"
  echo "  ───────────────────────────────────────────────────────────────────────────────" >> "$OUT_FILE"
  lvs --noheadings --units b --separator "$SEP" -o lv_name,lv_uuid,lv_size,vg_name 2>/dev/null | while IFS= read -r lvline; do
    lv_name=$(echo "$lvline" | awk -v FS="$SEP" '{print $1}' | sed 's/^ *//;s/ *$//')
    lv_uuid=$(echo "$lvline" | awk -v FS="$SEP" '{print $2}' | sed 's/^ *//;s/ *$//')
    lv_size=$(echo "$lvline" | awk -v FS="$SEP" '{print $3}' | sed 's/^ *//;s/ *$//')
    lv_vg=$(echo "$lvline" | awk -v FS="$SEP" '{print $4}' | sed 's/^ *//;s/ *$//')
    # Only process LVs that belong to current VG
    if [ "$lv_vg" = "$VG" ]; then
      echo "    - $lv_name" >> "$OUT_FILE"
      echo "       UUID: ${lv_uuid:-unknown}" >> "$OUT_FILE"
      echo "       Size: $(to_gib "${lv_size:-0}")" >> "$OUT_FILE"
      echo "" >> "$OUT_FILE"
    fi
  done

  echo "" >> "$OUT_FILE"
done

echo "Wrote read-only LVM report to: $OUT_FILE"
