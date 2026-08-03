#!/bin/bash
# installtoemmc - install a USB-booted ROCKNIX onto the internal eMMC
#                 (parameterised: one script, built-in board table)
#
# Modelled on EmuELEC's installtoemmc.sh: a single program plus a board table
# (board_config case). Adding a machine = adding one case, instead of one
# script per model.
#
# Usage:
#   installtoemmc list                 list supported boards
#   installtoemmc auto   [--yes]       detect this board and install
#   installtoemmc <board>[--yes]       install for a given board (-<board> also accepted)
#   (--yes skips the YES prompt, for one-click invocation from the ES menu)
#
# Single-boot: wipes the Armbian rootfs and hands the eMMC to ROCKNIX.
# Kept (mechanically required + the basis for MASKROM rescue):
#   1) the reserved area holding the vendor u-boot (its DRAM timings are calibrated)
#   2) p1 BOOT, which hosts boot.scr and the rocknix/Image chainload
#      (u-boot cannot read USB, so the kernel must live on the eMMC)
# Layout: p1 BOOT (untouched) | p2 ROCKNIX (SYSTEM) | p3 STORAGE (rest: games/saves).
# Only the OS and settings are moved -- games and rebuildable caches are not.
# When it is done, unplug the USB stick and the box boots purely from eMMC.
# If it will not boot: reflash Armbian over MASKROM. The partition table and the
# bootloader reserved area are never touched, so recovery is always possible.
set -uo pipefail

# ============================ board table ============================
# To add a board: add one case here and append its name to BOARDS. Fields:
#   DESC        human-readable description (shown by `list`)
#   COMPAT      a unique string from /proc/device-tree/compatible (used by `auto`)
#   EMMC_DEV    target internal eMMC block device
#   RK_SIZE_GIB size of the ROCKNIX (SYSTEM) partition; the rest goes to STORAGE
board_config() {
  case "$1" in
    md1000)
      DESC="MD1000 (RK3566 TV box)"
      COMPAT="rockchip,rk3566-md1000"
      EMMC_DEV="/dev/mmcblk0"
      RK_SIZE_GIB=2
      ;;
    # ---- copy one of these for a future board ----
    # e900v22c)
    #   DESC="..."; COMPAT="rockchip,rk35xx-..."; EMMC_DEV="/dev/mmcblk?"; RK_SIZE_GIB=2 ;;
    *) return 1 ;;
  esac
  return 0
}
BOARDS="md1000"
# =====================================================================

FLASH=/flash
STORAGE=/storage
LOG=/storage/installtoemmc.log

fail(){ echo "!! Aborted: $*" >&2; exit 1; }

do_list() {
  echo "Supported boards:"
  for b in $BOARDS; do board_config "$b"; printf "  %-12s %s\n" "$b" "$DESC"; done
}

detect_board() {
  local compat b
  compat=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null)
  for b in $BOARDS; do
    board_config "$b"
    if echo "$compat" | grep -qF "$COMPAT"; then echo "$b"; return 0; fi
  done
  return 1
}

# ------------------------- parse arguments -------------------------
BOARD=""
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    list|--list) do_list; exit 0 ;;
    auto|-auto|--auto) BOARD="auto" ;;
    -*) BOARD="${a#-}" ;;   # -md1000 -> md1000
    *) BOARD="$a" ;;
  esac
done
# es4all: 没给板名就读 profile 下发的机型配方(与 EmuELEC 侧同一个契约)。
#
# ★为什么不直接 auto-detect 就好★: 那个 conf 的存在与否同时是【选单可见性】的依据
# —— ES 用 hasFile("storage-config/es4all/emmc-layout.conf") 决定要不要显示
# 「写入 eMMC」。流程脚本每台都有, 配方才代表这台真的验证过。
# 让脚本【真的去读它】, 那个档才不会退化成一个没人看的旗标。
if [ -z "$BOARD" ] && [ -f /storage/.config/es4all/emmc-layout.conf ]; then
  BOARD=$(sed -n 's/^[[:space:]]*BOARD[[:space:]]*=[[:space:]]*//p' /storage/.config/es4all/emmc-layout.conf | head -1)
  [ -n "$BOARD" ] && echo "board from profile: $BOARD"
fi
[ -n "$BOARD" ] || { echo "Usage: installtoemmc list|auto|<board> [--yes]"; do_list; exit 1; }

if [ "$BOARD" = "auto" ]; then
  BOARD=$(detect_board) || fail "auto-detect failed: this board's compatible string is not in the board table (run 'installtoemmc list')"
  echo "auto-detected board: $BOARD"
fi
board_config "$BOARD" || fail "unknown board '$BOARD' (run 'installtoemmc list')"

EMMC="$EMMC_DEV"
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date) installtoemmc $BOARD ($DESC) ====="

# ------------------------- pre-flight checks -------------------------
[ -b "$EMMC" ] || fail "$EMMC not found"
FLASH_DEV=$(awk '$2=="/flash"{print $1}' /proc/mounts)
case "$FLASH_DEV" in
  ${EMMC}*) fail "already booted from eMMC (/flash=$FLASH_DEV), nothing to install";;
  /dev/sd*) : ;;
  *) fail "unexpected /flash source: $FLASH_DEV (expected a USB device /dev/sd*)";;
esac
[ -f "$FLASH/SYSTEM" ] || fail "$FLASH/SYSTEM does not exist"
grep -q "${EMMC}p2 " /proc/mounts && fail "${EMMC}p2 is mounted, unmount it first"
grep -q "${EMMC}p3 " /proc/mounts && fail "${EMMC}p3 is mounted, unmount it first"

# ------------------------- dynamic geometry -------------------------
DISKSZ=$(blockdev --getsz "$EMMC")
LAST_USABLE=$((DISKSZ - 34))
P2_START=$(parted -s "$EMMC" unit s print 2>/dev/null | awk '/^[[:space:]]*2[[:space:]]/{gsub(/s/,"",$2); print $2}')
[ -n "${P2_START:-}" ] || fail "could not read the start sector of p2"
RK_SIZE_S=$((RK_SIZE_GIB*1024*1024*1024/512))
RK_END=$((P2_START + RK_SIZE_S - 1))
ST_START=$((RK_END + 1))
[ "$ST_START" -lt "$LAST_USABLE" ] || fail "not enough space left for STORAGE"
ST_GIB=$(( (LAST_USABLE - ST_START) / 2048 / 1024 ))
echo "eMMC=$EMMC  ROCKNIX=${RK_SIZE_GIB}GiB(${P2_START}s..${RK_END}s)  STORAGE=~${ST_GIB}GiB(${ST_START}s..${LAST_USABLE}s)"

# ------------------------- confirmation -------------------------
if [ "$ASSUME_YES" != 1 ]; then
  echo
  echo "WARNING: this erases everything on $EMMC after sector $P2_START (the Armbian system)."
  echo "The u-boot loader and the BOOT partition are kept. When it is done, unplug the"
  echo "USB stick and the box boots purely from eMMC."
  printf "Type YES (uppercase) to continue: "
  read ans
  [ "$ans" = "YES" ] || fail "YES was not entered"
fi

# ------------------------- back up the GPT -------------------------
BK="$STORAGE/emmc-gpt-backup"; mkdir -p "$BK"
dd if="$EMMC" of="$BK/gpt-primary.bin"   bs=512 count=34 2>/dev/null
dd if="$EMMC" of="$BK/gpt-secondary.bin" bs=512 skip="$((DISKSZ-33))" count=33 2>/dev/null
echo "GPT backed up to $BK"

# ------------------------- repartition -------------------------
echo "-- repartitioning --"
for n in $(parted -s "$EMMC" print 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]/{print $1}' | sort -rn); do
  [ "$n" -ge 2 ] && parted -s "$EMMC" rm "$n"
done
parted -s "$EMMC" unit s mkpart primary fat32 "${P2_START}s" "${RK_END}s" || fail "could not create ROCKNIX"
parted -s "$EMMC" name 2 ROCKNIX
parted -s "$EMMC" set 2 msftdata on
parted -s "$EMMC" unit s mkpart primary ext4 "${ST_START}s" "${LAST_USABLE}s" || fail "could not create STORAGE"
parted -s "$EMMC" name 3 STORAGE
partprobe "$EMMC"; sleep 3
{ [ -b "${EMMC}p2" ] && [ -b "${EMMC}p3" ]; } || { sleep 3; partprobe "$EMMC"; sleep 2; }
{ [ -b "${EMMC}p2" ] && [ -b "${EMMC}p3" ]; } || fail "the new partitions did not appear"

# ------------------------- format -------------------------
echo "-- formatting --"
mkfs.vfat -F 32 -n ROCKNIX "${EMMC}p2" >/dev/null || fail "mkfs.vfat failed"
mkfs.ext4 -F -q -L STORAGE -m 0 -O ^orphan_file "${EMMC}p3" >/dev/null || fail "mkfs.ext4 failed"

# ------------------------- copy the OS -> ROCKNIX -------------------------
mkdir -p /tmp/erk /tmp/est /tmp/eb
mount "${EMMC}p2" /tmp/erk || fail "could not mount ROCKNIX"
echo "-- copying the OS to ROCKNIX --"
for it in KERNEL KERNEL.md5 SYSTEM SYSTEM.md5 device_trees extlinux overlays; do
  [ -e "$FLASH/$it" ] && cp -a "$FLASH/$it" /tmp/erk/
done
sync

# ------------------------- copy settings -> STORAGE (games/caches excluded) -------------------------
mount "${EMMC}p3" /tmp/est || fail "could not mount STORAGE"
echo "-- copying settings to STORAGE (games and caches excluded) --"
cd "$STORAGE"
for e in * .[!.]*; do
  [ -e "$e" ] || continue
  case "$e" in
    roms|games-internal|games-external|lost+found|.tmp|.update|emmc-gpt-backup|installtoemmc.log) continue;;
  esac
  cp -a "$STORAGE/$e" /tmp/est/ 2>/dev/null || echo "  warning: $e"
done
rm -rf /tmp/est/.cache/cores 2>/dev/null
mkdir -p /tmp/est/roms /tmp/est/games-internal /tmp/est/games-external
sync

# ------------------------- refresh the p1 chainload kernel/dtb + TRIGGER -------------------------
echo "-- refreshing eMMC p1 rocknix/Image + dtb --"
mount "${EMMC}p1" /tmp/eb || fail "could not mount p1"
[ -d /tmp/eb/rocknix ] || mkdir -p /tmp/eb/rocknix
cp -f "$FLASH/KERNEL" /tmp/eb/rocknix/Image
DTB="$FLASH/device_trees/${COMPAT#rockchip,}.dtb"
[ -f "$DTB" ] || DTB=$(ls "$FLASH"/device_trees/*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] && [ -f "$DTB" ] && cp -f "$DTB" /tmp/eb/rocknix/"$(basename "$DTB")"
[ -e /tmp/eb/rocknix/TRIGGER ] || : > /tmp/eb/rocknix/TRIGGER
sync

umount /tmp/erk /tmp/est /tmp/eb 2>/dev/null
echo "===== done ($BOARD) ====="
parted -s "$EMMC" print
echo
echo ">> Shut down, unplug the USB stick, power on -> ROCKNIX boots from eMMC."
echo ">> If anything goes wrong: plug the USB stick back in, or reflash Armbian over MASKROM."
