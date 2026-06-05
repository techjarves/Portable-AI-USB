#!/usr/bin/env bash
# ================================================================
# PORTABLE AI USB - Pre-Flight Requirements Check
# ================================================================
# Detects the actual mounted USB drive, checks free space and
# read/write speed, then optionally launches the installer.
#
# Important:
# - SCRIPT_DIR  = where this script lives
# - TARGET_MOUNT = the mounted USB path being tested
# ================================================================

set -uo pipefail

# ── Colour codes ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DGRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ── Minimum Requirements ──────────────────────────────────────
MIN_SPACE_GB=16
REC_SPACE_GB=32
MIN_WRITE_MBPS=10
REC_WRITE_MBPS=25
MIN_READ_MBPS=20
REC_READ_MBPS=50
BENCH_SIZE_MB=128
MIN_RAM_GB=4
REC_RAM_GB=8

# ── Paths ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_MOUNT=""
CURRENT_DEVICE=""
DEVICE_BASE=""
DEVICE_NAME=""
REQUESTED_MOUNT="${1:-}"
MOUNT_OPTS=""
MOUNT_IS_READONLY=false

# ── Result tracking ───────────────────────────────────────────
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
declare -a FAIL_MSGS=() WARN_MSGS=()
declare -a MOUNTED_USB_CHOICES=() USB_CHOICES=()

AUTO_USB_COUNT=0

# ── Output helpers ────────────────────────────────────────────
result_pass() { echo -e "  ${GREEN}✔${NC}  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
result_warn() { echo -e "  ${YELLOW}⚠${NC}  ${YELLOW}$1${NC}"; WARN_COUNT=$((WARN_COUNT + 1)); WARN_MSGS+=("$1"); }
result_fail() { echo -e "  ${RED}✘${NC}  ${RED}$1${NC}"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_MSGS+=("$1"); }
result_info() { echo -e "     ${DGRAY}$1${NC}"; }
section()     { echo ""; echo -e "${BOLD}${CYAN}  ── $1${NC}"; echo "  $(printf '─%.0s' {1..54})"; }

# ── Device helpers ────────────────────────────────────────────
get_base_device() {
  local dev="$1"
  local pk

  pk=$(lsblk -ndo PKNAME "$dev" 2>/dev/null | head -1)
  if [[ -z "$pk" ]]; then
    pk=$(lsblk -P -p -o NAME,PKNAME 2>/dev/null | awk -v dev="$dev" '
      {
        name=""; pkname=""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^NAME=/)   { name=$i; sub(/^NAME="/, "", name); sub(/"$/, "", name) }
          if ($i ~ /^PKNAME=/) { pkname=$i; sub(/^PKNAME="/, "", pkname); sub(/"$/, "", pkname) }
        }
        if (name == dev && pkname != "") { print pkname; exit }
      }')
  fi

  if [[ -n "$pk" ]]; then
    [[ "$pk" == /dev/* ]] && echo "$pk" || echo "/dev/$pk"
  else
    echo "$dev"
  fi
}

lsblk_value() {
  local dev="$1"
  local column="$2"
  local value=""

  value=$(lsblk -no "$column" "$dev" 2>/dev/null | head -1 | xargs 2>/dev/null || true)
  if [[ -n "$value" ]]; then
    echo "$value"
    return 0
  fi

  lsblk -P -p -o NAME,"$column" 2>/dev/null | awk -v dev="$dev" -v key="$column" '
    {
      name=""; value=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^NAME=/) {
          name=$i
          sub(/^NAME="/, "", name)
          sub(/"$/, "", name)
        } else if ($i ~ ("^" key "=")) {
          value=$i
          sub("^" key "=\"", "", value)
          sub(/"$/, "", value)
        }
      }
      if (name == dev) {
        print value
        exit
      }
    }'
}

device_visible() {
  local dev="$1"

  [[ -n "$dev" ]] || return 1
  [[ -b "$dev" ]] && return 0

  lsblk -P -p -o NAME 2>/dev/null | grep -Fq "NAME=\"$dev\""
}

is_removable_or_usb() {
  local dev="$1"
  local base name removable_path removable_flag tran bus

  [[ -n "$dev" ]] || return 1
  device_visible "$dev" || return 1

  base=$(get_base_device "$dev")
  name=$(basename "$base")

  removable_path="/sys/block/${name}/removable"
  if [[ -f "$removable_path" ]]; then
    removable_flag=$(cat "$removable_path" 2>/dev/null || echo "0")
    if [[ "$removable_flag" == "1" ]]; then
      return 0
    fi
  fi

  tran=$(lsblk_value "$base" TRAN | tr '[:upper:]' '[:lower:]')
  if [[ "$tran" == "usb" ]]; then
    return 0
  fi

  if command -v udevadm &>/dev/null; then
    bus=$(udevadm info --query=property --name="$dev" 2>/dev/null | awk -F= '/^ID_BUS=/{print tolower($2)}' | head -1)
    if [[ "$bus" == "usb" ]]; then
      return 0
    fi
  fi

  return 1
}

resolve_mount_source() {
  local mnt="$1"
  local source=""

  if command -v findmnt &>/dev/null; then
    source=$(findmnt -n -o SOURCE --target "$mnt" 2>/dev/null | head -1)
  fi

  if [[ -z "$source" ]]; then
    source=$(mount | awk -v target="$mnt" '$3 == "on" && $5 == target {print $1; exit}')
  fi

  echo "$source"
}

resolve_mount_options() {
  local mnt="$1"
  local opts=""

  if command -v findmnt &>/dev/null; then
    opts=$(findmnt -n -o OPTIONS --target "$mnt" 2>/dev/null | head -1)
  fi

  if [[ -z "$opts" ]]; then
    opts=$(mount | awk -v target="$mnt" '$3 == "on" && $5 == target {gsub(/^\(|\)$/, "", $6); print $6; exit}')
  fi

  echo "$opts"
}

use_requested_mount() {
  [[ -n "$REQUESTED_MOUNT" ]] || return 1
  [[ -d "$REQUESTED_MOUNT" ]] || return 1

  TARGET_MOUNT="$REQUESTED_MOUNT"
  CURRENT_DEVICE=$(resolve_mount_source "$TARGET_MOUNT")

  [[ -n "$CURRENT_DEVICE" ]] || return 1
  device_visible "$CURRENT_DEVICE" || return 1
  is_removable_or_usb "$CURRENT_DEVICE" || return 1
  return 0
}

collect_mounted_usb_partitions() {
  local SOURCE TARGET

  MOUNTED_USB_CHOICES=()

  while read -r SOURCE TARGET; do
    [[ -n "${SOURCE:-}" ]] || continue
    [[ -n "${TARGET:-}" ]] || continue
    device_visible "$SOURCE" || continue

    if is_removable_or_usb "$SOURCE"; then
      MOUNTED_USB_CHOICES+=("$SOURCE|$TARGET")
    fi
  done < <(findmnt -l -n -o SOURCE,TARGET 2>/dev/null)
}

choose_from_mounted_usbs() {
  local i choice dev mnt

  collect_mounted_usb_partitions
  AUTO_USB_COUNT=${#MOUNTED_USB_CHOICES[@]}

  if (( AUTO_USB_COUNT == 0 )); then
    return 1
  fi

  if (( AUTO_USB_COUNT == 1 )); then
    IFS='|' read -r CURRENT_DEVICE TARGET_MOUNT <<< "${MOUNTED_USB_CHOICES[0]}"
    return 0
  fi

  echo -e "  ${YELLOW}Multiple mounted removable USB drives detected.${NC}"
  echo ""
  for i in "${!MOUNTED_USB_CHOICES[@]}"; do
    IFS='|' read -r dev mnt <<< "${MOUNTED_USB_CHOICES[$i]}"
    printf "  %d) %s  ->  %s\n" "$((i + 1))" "$dev" "$mnt"
  done
  echo ""

  read -rp "  Choose the USB mount to test (1-${AUTO_USB_COUNT}): " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > AUTO_USB_COUNT )); then
    return 1
  fi

  IFS='|' read -r CURRENT_DEVICE TARGET_MOUNT <<< "${MOUNTED_USB_CHOICES[$((choice - 1))]}"
  return 0
}

choose_from_all_removable_devices() {
  local line
  local NAME SIZE TRAN MODEL
  local i choice dev size tran model mnt part

  USB_CHOICES=()

  while IFS= read -r line; do
    unset NAME SIZE TRAN MODEL
    eval "$line"

    [[ -n "${NAME:-}" ]] || continue
    device_visible "$NAME" || continue

    if is_removable_or_usb "$NAME"; then
      mnt=$(lsblk -n -o MOUNTPOINT "$NAME" 2>/dev/null | awk 'NF {print; exit}')
      [[ -z "$mnt" ]] && mnt="(not mounted)"
      USB_CHOICES+=("$NAME|${SIZE:-unknown}|${TRAN:-unknown}|${MODEL:-unknown}|$mnt")
    fi
  done < <(lsblk -P -d -p -o NAME,SIZE,TRAN,MODEL 2>/dev/null)

  if (( ${#USB_CHOICES[@]} == 0 )); then
    return 1
  fi

  echo -e "  ${CYAN}Removable / USB devices:${NC}"
  echo ""
  for i in "${!USB_CHOICES[@]}"; do
    IFS='|' read -r dev size tran model mnt <<< "${USB_CHOICES[$i]}"
    printf "  %d) %s  %s  %s  %s  %s\n" \
      "$((i + 1))" \
      "$dev" \
      "$size" \
      "${tran:-unknown}" \
      "${model:-unknown}" \
      "$mnt"
  done
  echo ""

  read -rp "  Choose the USB device number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#USB_CHOICES[@]} )); then
    return 1
  fi

  IFS='|' read -r dev size tran model mnt <<< "${USB_CHOICES[$((choice - 1))]}"

  if [[ "$mnt" == "(not mounted)" ]]; then
    echo -e "  ${YELLOW}Selected USB device is not mounted.${NC}"
    read -rp "  Enter the mounted path manually (or leave blank to cancel): " mnt
  fi

  [[ -n "$mnt" ]] || return 1
  [[ -d "$mnt" ]] || return 1

  part=$(resolve_mount_source "$mnt")
  [[ -z "$part" ]] && part="$dev"

  CURRENT_DEVICE="$part"
  TARGET_MOUNT="$mnt"
  return 0
}

# ── Visual bars ───────────────────────────────────────────────
speed_bar() {
  local actual=$1 min=$2 rec=$3 max=${4:-200}
  local bar_width=40 filled=0 empty=0
  local color="${RED}"

  (( max > 0 )) && filled=$(awk "BEGIN{v=int($bar_width*$actual/$max); print (v>$bar_width)?$bar_width:(v<0?0:v)}")
  empty=$(( bar_width - filled ))

  (( actual >= min )) && color="${YELLOW}"
  (( actual >= rec )) && color="${GREEN}"

  printf "     ["
  if (( filled > 0 )); then
    printf "${color}%0.s█${NC}" $(seq 1 "$filled")
  fi
  if (( empty > 0 )); then
    printf "${DGRAY}%0.s░${NC}" $(seq 1 "$empty")
  fi
  printf "] ${BOLD}%.1f MB/s${NC}\n" "$actual"
}

space_bar() {
  local used=$1 total=$2
  local bar_width=40 filled=0 empty=0 pct=0

  (( total > 0 )) && filled=$(awk "BEGIN{v=int($bar_width*$used/$total); print (v>$bar_width)?$bar_width:v}")
  empty=$(( bar_width - filled ))
  (( total > 0 )) && pct=$(awk "BEGIN{printf \"%.0f\",$used/$total*100}")

  printf "     ["
  if (( filled > 0 )); then
    printf "${CYAN}%0.s█${NC}" $(seq 1 "$filled")
  fi
  if (( empty > 0 )); then
    printf "${DGRAY}%0.s░${NC}" $(seq 1 "$empty")
  fi
  printf "] ${DGRAY}%d%% used${NC}\n" "$pct"
}

# ================================================================
# HEADER
# ================================================================
clear
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║   🔍  Portable AI USB — Pre-Flight Check            ║${NC}"
echo -e "${CYAN}  ║       Verifying drive before installation...        ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DGRAY}Script Dir   : $SCRIPT_DIR${NC}"
echo -e "  ${DGRAY}Minimum      : ${MIN_SPACE_GB} GB free  |  Write ≥ ${MIN_WRITE_MBPS} MB/s  |  Read ≥ ${MIN_READ_MBPS} MB/s  |  RAM ≥ ${MIN_RAM_GB} GB${NC}"
echo -e "  ${DGRAY}Recommended  : ${REC_SPACE_GB} GB free  |  Write ≥ ${REC_WRITE_MBPS} MB/s  |  Read ≥ ${REC_READ_MBPS} MB/s  |  RAM ≥ ${REC_RAM_GB} GB${NC}"

# ================================================================
# STEP 1 — DEPENDENCY CHECK
# ================================================================
section "Step 1 / 5 — Required Tools"
echo ""

MISSING_DEPS=()
for cmd in curl tar zstd dd df lsblk awk findmnt; do
  if command -v "$cmd" &>/dev/null; then
    result_pass "'$cmd' is available"
  else
    result_fail "'$cmd' not found — required for installation"
    MISSING_DEPS+=("$cmd")
  fi
done

if (( ${#MISSING_DEPS[@]} > 0 )); then
  echo ""
  echo -e "  ${YELLOW}Install missing tools:${NC}"
  echo -e "  ${DGRAY}sudo apt install ${MISSING_DEPS[*]}${NC}"
fi

# ================================================================
# STEP 2 — USB DRIVE DETECTION
# ================================================================
section "Step 2 / 5 — USB Drive Detection"
echo ""

if choose_from_mounted_usbs; then
  if use_requested_mount; then
    result_pass "Using user-specified mount path"
  elif (( AUTO_USB_COUNT <= 1 )); then
    result_pass "Detected mounted removable USB drive automatically"
  else
    result_pass "Selected mounted removable USB drive"
  fi
else
  if use_requested_mount; then
    result_pass "Using user-specified mount path"
  elif choose_from_all_removable_devices; then
    result_warn "Could not auto-detect a mounted removable USB drive"
    result_pass "Selected USB device manually"
  else
    result_warn "Could not auto-detect a mounted removable USB drive"
    result_fail "No usable USB drive selected"
    echo ""
    echo -e "  ${RED}Tip:${NC} Make sure the USB is mounted, then re-run this script."
    exit 1
  fi
fi

if [[ -z "$TARGET_MOUNT" || ! -d "$TARGET_MOUNT" ]]; then
  result_fail "USB mount path is missing or invalid: ${TARGET_MOUNT:-<empty>}"
  exit 1
fi

DEVICE_BASE=$(get_base_device "$CURRENT_DEVICE")
DEVICE_NAME=$(basename "$DEVICE_BASE")

result_info "USB Mount : $TARGET_MOUNT"
result_info "Partition : $CURRENT_DEVICE"
result_info "Base Dev  : $DEVICE_BASE"

DRIVE_LABEL=$(lsblk_value "$CURRENT_DEVICE" LABEL)
DRIVE_FS=$(lsblk_value "$CURRENT_DEVICE" FSTYPE)
DRIVE_MODEL=$(lsblk_value "$DEVICE_BASE" MODEL)
DRIVE_TRAN=$(lsblk_value "$DEVICE_BASE" TRAN)
DRIVE_SIZE=$(lsblk_value "$DEVICE_BASE" SIZE)
[[ -n "$DRIVE_LABEL" ]] || DRIVE_LABEL="—"
[[ -n "$DRIVE_FS" ]] || DRIVE_FS="unknown"
[[ -n "$DRIVE_MODEL" ]] || DRIVE_MODEL="—"
[[ -n "$DRIVE_TRAN" ]] || DRIVE_TRAN="—"
[[ -n "$DRIVE_SIZE" ]] || DRIVE_SIZE="—"
DRIVE_VENDOR=$(cat "/sys/block/${DEVICE_NAME}/device/vendor" 2>/dev/null | xargs 2>/dev/null || echo "—")
MOUNT_OPTS=$(resolve_mount_options "$TARGET_MOUNT")
if [[ ",${MOUNT_OPTS}," == *,ro,* ]]; then
  MOUNT_IS_READONLY=true
fi

echo ""
echo -e "  ${DGRAY}┌─ Drive Info ──────────────────────────────────────────┐${NC}"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Model:"       "$DRIVE_MODEL"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Vendor:"      "$DRIVE_VENDOR"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Label:"       "$DRIVE_LABEL"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Total Size:"  "$DRIVE_SIZE"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "File System:" "$DRIVE_FS"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Interface:"   "${DRIVE_TRAN^^}"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Mount Path:"  "$TARGET_MOUNT"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%s${NC}\n" "Mount Opts:"  "${MOUNT_OPTS:-unknown}"
echo -e "  ${DGRAY}└───────────────────────────────────────────────────────┘${NC}"
echo ""

case "${DRIVE_TRAN,,}" in
  usb)
    result_pass "USB interface detected"
    ;;
  sata|nvme|mmc)
    result_warn "Interface shows as '${DRIVE_TRAN^^}' — may not be a USB bridge"
    ;;
  *)
    result_warn "Interface '${DRIVE_TRAN}' unrecognized — verify this is your USB drive"
    ;;
esac

echo ""
case "${DRIVE_FS,,}" in
  vfat|fat32|fat16)
    result_fail "FAT32 filesystem detected — 4 GB per-file limit will block large GGUF models!"
    result_info "Reformat the drive as exFAT or ext4 to support files up to 7 GB"
    ;;
  exfat)
    result_pass "exFAT filesystem — supports large files (>4 GB) ✔"
    ;;
  ntfs)
    result_pass "NTFS filesystem — supports large files (>4 GB) ✔"
    ;;
  ext4|btrfs|xfs|f2fs)
    result_pass "${DRIVE_FS^^} filesystem — supports large files (>4 GB) ✔"
    ;;
  ""|unknown)
    result_warn "Could not detect filesystem type — manually verify it supports files > 4 GB"
    ;;
  *)
    result_warn "Filesystem '${DRIVE_FS}' — manually verify it supports files larger than 4 GB"
    ;;
esac

if $MOUNT_IS_READONLY; then
  result_fail "Mount is read-only — remount with write access before installation or benchmarking"
fi

# ================================================================
# STEP 3 — DISK SPACE CHECK
# ================================================================
section "Step 3 / 5 — Available Disk Space"
echo ""

if [[ -z "$TARGET_MOUNT" || ! -d "$TARGET_MOUNT" ]]; then
  result_fail "USB mount path is missing or invalid"
  exit 1
fi

SPACE_RAW=$(df -BG "$TARGET_MOUNT" 2>/dev/null | tail -1)
TOTAL_GB=$( echo "$SPACE_RAW" | awk '{gsub(/G/,"",$2); print int($2)}')
USED_GB=$(  echo "$SPACE_RAW" | awk '{gsub(/G/,"",$3); print int($3)}')
FREE_GB=$(  echo "$SPACE_RAW" | awk '{gsub(/G/,"",$4); print int($4)}')
USE_PCT=$(  echo "$SPACE_RAW" | awk '{print $5}')

echo -e "  ${DGRAY}┌─ Storage ─────────────────────────────────────────────┐${NC}"
printf  "  ${DGRAY}│${NC}  %-14s %d GB\n"                "Total:"  "$TOTAL_GB"
printf  "  ${DGRAY}│${NC}  %-14s %d GB (%s)\n"           "Used:"   "$USED_GB"  "$USE_PCT"
printf  "  ${DGRAY}│${NC}  %-14s ${BOLD}%d GB${NC}\n"    "Free:"   "$FREE_GB"
echo -e "  ${DGRAY}└───────────────────────────────────────────────────────┘${NC}"
echo ""
space_bar "$USED_GB" "$TOTAL_GB"
echo ""

if   (( FREE_GB >= REC_SPACE_GB )); then
  result_pass "Free space: ${FREE_GB} GB — excellent! (recommended: ${REC_SPACE_GB} GB)"
elif (( FREE_GB >= MIN_SPACE_GB )); then
  result_warn "Free space: ${FREE_GB} GB — sufficient but tight (${REC_SPACE_GB} GB recommended)"
  result_info "You may only fit 1–2 smaller models on this drive"
else
  result_fail "Free space: ${FREE_GB} GB — insufficient (minimum: ${MIN_SPACE_GB} GB)"
  result_info "Free up space or use a larger USB drive before running the installer"
fi

echo ""
echo -e "  ${DGRAY}┌─ Model Footprint Guide ───────────────────────────────┐${NC}"
echo -e "  ${DGRAY}│${NC}  ${GREEN}Llama 3.2 3B Instruct${NC}      ~2.0 GB   LIGHTWEIGHT"
echo -e "  ${DGRAY}│${NC}  ${GREEN}Phi-3.5 Mini 3.8B${NC}          ~2.2 GB   LIGHTWEIGHT"
echo -e "  ${DGRAY}│${NC}  ${CYAN}Mistral 7B Instruct v0.3${NC}   ~4.1 GB   STANDARD"
echo -e "  ${DGRAY}│${NC}  ${CYAN}Qwen 2.5 7B Instruct${NC}       ~4.7 GB   STANDARD"
echo -e "  ${DGRAY}│${NC}  ${CYAN}Dolphin 2.9 Llama 3 8B${NC}     ~4.9 GB   STANDARD"
echo -e "  ${DGRAY}│${NC}  ${MAGENTA}NemoMix Unleashed 12B${NC}      ~7.0 GB   LARGE"
echo -e "  ${DGRAY}│${NC}  ${DGRAY}Ollama engine + AppImage   ~1.0 GB   REQUIRED${NC}"
echo -e "  ${DGRAY}└───────────────────────────────────────────────────────┘${NC}"

# ================================================================
# STEP 4 — SYSTEM RAM
# ================================================================
section "Step 4 / 5 — System RAM"
echo ""

TOTAL_RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
AVAIL_RAM_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))

echo -e "  ${DGRAY}┌─ Memory ──────────────────────────────────────────────┐${NC}"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%d GB${NC}\n" "Total RAM:"  "$TOTAL_RAM_GB"
printf  "  ${DGRAY}│${NC}  %-16s ${BOLD}%d GB${NC}\n" "Available:"  "$AVAIL_RAM_GB"
echo -e "  ${DGRAY}└───────────────────────────────────────────────────────┘${NC}"
echo ""

if (( TOTAL_RAM_GB == 0 )); then
  result_warn "Could not read system RAM from /proc/meminfo"
elif (( TOTAL_RAM_GB >= REC_RAM_GB )); then
  result_pass "RAM: ${TOTAL_RAM_GB} GB — sufficient for all preset models"
elif (( TOTAL_RAM_GB >= 6 )); then
  result_warn "RAM: ${TOTAL_RAM_GB} GB — enough for 7B models; NemoMix 12B requires ${REC_RAM_GB} GB"
elif (( TOTAL_RAM_GB >= MIN_RAM_GB )); then
  result_warn "RAM: ${TOTAL_RAM_GB} GB — only 3B lightweight models recommended"
  result_info "7B models need ≥ 6 GB; NemoMix 12B needs ≥ ${REC_RAM_GB} GB"
else
  result_fail "RAM: ${TOTAL_RAM_GB} GB — insufficient (minimum ${MIN_RAM_GB} GB required)"
  result_info "This system may not have enough RAM to run any AI model reliably"
fi

echo ""
echo -e "  ${DGRAY}┌─ Model RAM Guide ─────────────────────────────────────┐${NC}"
echo -e "  ${DGRAY}│${NC}  ${GREEN}Llama 3.2 3B / Phi-3.5 Mini${NC}      ≥ 4 GB RAM"
echo -e "  ${DGRAY}│${NC}  ${CYAN}Mistral / Qwen / Dolphin 7-8B${NC}     ≥ 6 GB RAM"
echo -e "  ${DGRAY}│${NC}  ${MAGENTA}NemoMix Unleashed 12B${NC}             ≥ 8 GB RAM"
echo -e "  ${DGRAY}└───────────────────────────────────────────────────────┘${NC}"

# ================================================================
# STEP 5 — DRIVE SPEED BENCHMARK
# ================================================================
section "Step 5 / 5 — Drive Speed Benchmark"
echo ""
echo -e "  ${DGRAY}Using a ${BENCH_SIZE_MB} MB temporary test file on:${NC}"
echo -e "  ${DGRAY}${TARGET_MOUNT}${NC}"

TMPFILE="$TARGET_MOUNT/.preflight_bench_$$.tmp"

if $MOUNT_IS_READONLY; then
  echo ""
  result_warn "Skipping write/read benchmark because the mount is read-only"
  WRITE_MBPS=0
  READ_MBPS=0
  WRITE_INT=0
  READ_INT=0
else

# ── Write Speed ───────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}[1/2]${NC} Write test (${BENCH_SIZE_MB} MB)..."

WRITE_MBPS=0
WRITE_OK=false

if command -v dd &>/dev/null; then
  T_START=$(date +%s%N 2>/dev/null || echo 0)
  dd if=/dev/urandom of="$TMPFILE" bs=1M count="$BENCH_SIZE_MB" conv=fsync 2>/dev/null
  T_END=$(date +%s%N 2>/dev/null || echo 0)
  T_NS=$(( T_END - T_START ))
  if (( T_NS > 0 )); then
    WRITE_MBPS=$(awk "BEGIN{printf \"%.1f\",($BENCH_SIZE_MB*1000000000)/$T_NS}")
    WRITE_OK=true
  fi
fi

echo ""
speed_bar "${WRITE_MBPS%.*}" "$MIN_WRITE_MBPS" "$REC_WRITE_MBPS" 150
echo ""

WRITE_INT="${WRITE_MBPS%.*}"
if ! $WRITE_OK; then
  result_warn "Write benchmark could not be measured"
elif (( WRITE_INT >= REC_WRITE_MBPS )); then
  result_pass "Write speed: ${WRITE_MBPS} MB/s — great! Model downloads will be fast."
elif (( WRITE_INT >= MIN_WRITE_MBPS )); then
  result_warn "Write speed: ${WRITE_MBPS} MB/s — acceptable, but downloads may take longer"
  result_info "A USB 3.0 drive in a USB 3.0 port is recommended"
else
  result_fail "Write speed: ${WRITE_MBPS} MB/s — too slow (minimum: ${MIN_WRITE_MBPS} MB/s)"
  result_info "Use a USB 3.0+ drive and ensure it is in a USB 3.0+ port"
fi

echo ""

# ── Read Speed ────────────────────────────────────────────────
echo -e "  ${CYAN}[2/2]${NC} Read test (${BENCH_SIZE_MB} MB)..."

READ_MBPS=0
READ_OK=false

if [[ -f "$TMPFILE" ]]; then
  sync
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi

  T_START=$(date +%s%N 2>/dev/null || echo 0)
  dd if="$TMPFILE" of=/dev/null bs=1M 2>/dev/null
  T_END=$(date +%s%N 2>/dev/null || echo 0)
  T_NS=$(( T_END - T_START ))
  if (( T_NS > 0 )); then
    READ_MBPS=$(awk "BEGIN{printf \"%.1f\",($BENCH_SIZE_MB*1000000000)/$T_NS}")
    READ_OK=true
  fi
fi

rm -f "$TMPFILE" 2>/dev/null || true

echo ""
speed_bar "${READ_MBPS%.*}" "$MIN_READ_MBPS" "$REC_READ_MBPS" 200
echo ""

READ_INT="${READ_MBPS%.*}"
if ! $READ_OK; then
  result_warn "Read benchmark could not be measured — test file not found"
elif (( READ_INT >= REC_READ_MBPS )); then
  result_pass "Read speed: ${READ_MBPS} MB/s — great! AI models will load quickly."
elif (( READ_INT >= MIN_READ_MBPS )); then
  result_warn "Read speed: ${READ_MBPS} MB/s — acceptable (model loading may take 15–30 sec)"
elif (( READ_INT > 0 )); then
  result_fail "Read speed: ${READ_MBPS} MB/s — too slow (minimum: ${MIN_READ_MBPS} MB/s)"
  result_info "Slow reads directly impact AI response generation speed"
fi

# ── USB generation hint ───────────────────────────────────────
echo ""
if   (( READ_INT >= 150 )); then
  echo -e "  ${CYAN}ℹ${NC}  ${DGRAY}Performance indicates: USB 3.1/3.2 Gen 2 (10+ Gbps) — excellent${NC}"
elif (( READ_INT >= 80  )); then
  echo -e "  ${CYAN}ℹ${NC}  ${DGRAY}Performance indicates: USB 3.0/3.1 Gen 1 (5 Gbps) — good${NC}"
elif (( READ_INT >= 25  )); then
  echo -e "  ${CYAN}ℹ${NC}  ${DGRAY}Performance indicates: USB 3.0 (low-end or congested port)${NC}"
elif (( READ_INT >  0   )); then
  echo -e "  ${YELLOW}ℹ${NC}  ${YELLOW}Performance indicates: USB 2.0 — upgrade strongly recommended${NC}"
fi
fi

# ================================================================
# FINAL VERDICT
# ================================================================
echo ""
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║                Pre-Flight Summary                   ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}✔ Passed   : ${PASS_COUNT}${NC}"
echo -e "  ${YELLOW}⚠ Warnings : ${WARN_COUNT}${NC}"
echo -e "  ${RED}✘ Failed   : ${FAIL_COUNT}${NC}"

echo ""
echo -e "  ${DGRAY}Target USB  : ${CURRENT_DEVICE}${NC}"
echo -e "  ${DGRAY}Mount Path  : ${TARGET_MOUNT}${NC}"

if (( ${#WARN_MSGS[@]} > 0 )); then
  echo ""
  echo -e "  ${YELLOW}Warnings:${NC}"
  for msg in "${WARN_MSGS[@]}"; do
    echo -e "  ${YELLOW}  ·${NC} $msg"
  done
fi

if (( ${#FAIL_MSGS[@]} > 0 )); then
  echo ""
  echo -e "  ${RED}Failed checks:${NC}"
  for msg in "${FAIL_MSGS[@]}"; do
    echo -e "  ${RED}  ·${NC} $msg"
  done
fi

echo ""

# ── Decision gate ─────────────────────────────────────────────
if (( FAIL_COUNT > 0 )); then
  echo -e "${RED}  ✘  REQUIREMENTS NOT MET — Installation blocked.${NC}"
  echo -e "     Resolve the failed checks above, then re-run this script."
  echo ""
  echo -e "  ${DGRAY}Press Enter to exit...${NC}"
  read -r
  exit 1

elif (( WARN_COUNT > 0 )); then
  echo -e "${YELLOW}  ⚠  REQUIREMENTS MET WITH WARNINGS${NC}"
  echo -e "     Installation can proceed — but review warnings above first."
  echo ""
  read -rp "  Proceed to installation anyway? (yes/no): " CONFIRM
  if [[ "${CONFIRM,,}" == "yes" || "${CONFIRM,,}" == "y" ]]; then
    echo ""
    if [[ "$TARGET_MOUNT" != "$SCRIPT_DIR" ]]; then
        echo -e "  ${YELLOW}Copying setup scripts to USB drive...${NC}"
        cp "$SCRIPT_DIR/install.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/install-core.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/preflight-check.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/start-linux.sh" "$TARGET_MOUNT/"
        chmod +x "$TARGET_MOUNT/"*.sh 2>/dev/null || true
    fi
    echo -e "  ${GREEN}Launching installer on: ${TARGET_MOUNT}...${NC}"
    sleep 1
    bash "$TARGET_MOUNT/install-core.sh" "$TARGET_MOUNT"
  else
    echo ""
    echo -e "  ${YELLOW}Cancelled. Re-run preflight-check.sh when ready.${NC}"
    exit 0
  fi

else
  echo -e "${GREEN}  ✔  ALL CHECKS PASSED — Your drive is ready!${NC}"
  echo ""
  read -rp "  Proceed to installation? (yes/no): " CONFIRM
  if [[ "${CONFIRM,,}" == "yes" || "${CONFIRM,,}" == "y" ]]; then
    echo ""
    if [[ "$TARGET_MOUNT" != "$SCRIPT_DIR" ]]; then
        echo -e "  ${YELLOW}Copying setup scripts to USB drive...${NC}"
        cp "$SCRIPT_DIR/install.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/install-core.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/preflight-check.sh" "$TARGET_MOUNT/"
        cp "$SCRIPT_DIR/start-linux.sh" "$TARGET_MOUNT/"
        chmod +x "$TARGET_MOUNT/"*.sh 2>/dev/null || true
    fi
    echo -e "  ${GREEN}Launching installer on: ${TARGET_MOUNT}...${NC}"
    sleep 1
    bash "$TARGET_MOUNT/install-core.sh" "$TARGET_MOUNT"
  else
    echo ""
    echo -e "  ${DGRAY}No problem — run install-core.sh whenever you're ready.${NC}"
    exit 0
  fi
fi
