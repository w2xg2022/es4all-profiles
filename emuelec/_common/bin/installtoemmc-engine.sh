#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-or-later
#
# installtoemmc.sh --- unified eMMC dual-boot installer for adapted Amlogic
# TV boxes running EmuELEC.
#
# ONE program, ONE embedded board table. To support a new box, add a case
# entry in board_config() below -- do NOT create another per-model script.
#
# METHOD (for locked / proprietary Amlogic partition-table boxes such as the
# X98mini): the stock Android u-boot cannot repartition the eMMC and does not
# read an MBR, but its autoscript carries a "cfgloademmc" fallback that scans
# eMMC partitions 1..0x1F for a FAT partition holding a "cfgload" file; if it
# finds one it sets ce_on_emmc=yes and boots from LABEL=CE_FLASH /
# LABEL=CE_STORAGE instead of the SD/USB. So no bootloader replacement is
# needed. Rather than repartition (which the stock u-boot would ignore) we
# REUSE two existing factory Android named partitions:
#   - a mid-sized one  -> reformatted FAT32, label CE_FLASH   (boot files)
#   - the largest one  -> reformatted ext4,  label CE_STORAGE (persistent /storage)
#
# Bootloader / env / tee and every other partition are left untouched, so the
# SD/USB installation remains a working fallback. Android itself will no longer
# boot afterwards (its partitions are repurposed), which is expected on these
# boxes since they are not used as Android devices.
#
# The official CoreELEC "ceemmc" tool mis-handles these boards' Android
# partition layouts (segfaults), so this does the equivalent steps by hand.
#
# Usage:
#   installtoemmc.sh <board>      e.g.  installtoemmc.sh x98mini
#   installtoemmc.sh -<board>     e.g.  installtoemmc.sh -x98mini   (same thing)
#   installtoemmc.sh auto         auto-detect the board from the eMMC layout
#   installtoemmc.sh list         list supported boards

set -e

CE_FLASH_LABEL="CE_FLASH"
CE_STORAGE_LABEL="CE_STORAGE"
MNT_FLASH="/tmp/emmc_flash"
MNT_STORAGE="/tmp/emmc_storage"

die() { echo "ERROR: $*" >&2; exit 1; }

# Size of a block device in MiB, read from sysfs (EmuELEC's busybox has no
# blockdev/lsblk). /sys/class/block/<name>/size is in 512-byte sectors.
dev_size_mb() {
    local sect
    sect=$(cat "/sys/class/block/${1##*/}/size" 2>/dev/null)
    [ -n "$sect" ] || return 1
    echo $(( sect / 2048 ))
}

# Some boxes reuse the Android "super" dynamic-partition container as CE_FLASH.
# On those, CoreELEC's opentee_linuxdriver.service (tee-loader/dovi-loader)
# assembles the super partition via device-mapper (dynpart-*) and mounts
# /android/{system,vendor,odm,oem} to run the TEE supplicant + Dolby Vision.
# Those pin the target device busy. Tear the whole stack down before formatting.
# TEE / Dolby Vision are not used for retro gaming, so losing them is fine.
teardown_android_super() {
    echo ">>> Tearing down Android TEE / Dolby-Vision stack (frees ${FLASH_DEV})..."
    systemctl stop opentee_linuxdriver 2>/dev/null || true
    # kill processes still executing out of /android (e.g. tee-supplicant)
    local p pid
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        if grep -qs '/android/' "$p/maps" 2>/dev/null \
           || readlink "$p/cwd" 2>/dev/null | grep -qs '/android/'; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    sleep 1
    # unmount the android mounts (lazy if still busy)
    local m
    for m in /android/system /android/vendor /android/odm /android/oem /android/product; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    # remove the device-mapper dynamic partitions that pin FLASH_DEV
    local d
    for d in $(dmsetup ls 2>/dev/null | awk 'NF && $1!="No"{print $1}'); do
        dmsetup remove "$d" 2>/dev/null || dmsetup remove -f "$d" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Board table. board_config <board> sets, for the selected board:
#   FLASH_DEV      factory partition to reuse for boot files (-> CE_FLASH, FAT32)
#   STORAGE_DEV    factory partition to reuse for /storage    (-> CE_STORAGE, ext4)
#   FLASH_MIN_MB / FLASH_MAX_MB   sanity range for FLASH_DEV   (anti-brick guard)
#   STORAGE_MIN_MB                minimum size for STORAGE_DEV
#   DESC           human description
#
# To add a new box: add a case entry here and append its name to BOARDS.
# ---------------------------------------------------------------------------
BOARDS="x98mini e900v22c md1000"

board_config() {
    SUPER_TEARDOWN=""   # default: boards that don't reuse Android 'super'
    # METHOD selects the install strategy:
    #   reuse       - locked Amlogic boxes: reformat two existing factory
    #                 named partitions (the stock u-boot ignores any new
    #                 partition table, so we must not repartition)
    #   repartition - boards where we control u-boot and the eMMC is plain
    #                 GPT: replace the second partition with EMUELEC+STORAGE
    METHOD="reuse"
    case "$1" in
    x98mini)
        # Reuse Android 'super' (eMMC part 28/0x1C, ~2.25GB) and 'userdata'
        # (part 29/0x1D, ~26GB). Both are surfaced by the Amlogic MMC driver
        # as named nodes /dev/super and /dev/userdata.
        FLASH_DEV="/dev/super"
        STORAGE_DEV="/dev/userdata"
        FLASH_MIN_MB=1500;  FLASH_MAX_MB=4000
        STORAGE_MIN_MB=10000
        SUPER_TEARDOWN="yes"   # FLASH_DEV is the Android 'super' dm container
        DESC="X98mini (Amlogic S905W2/S4, 32GB eMMC)"
        ;;
    e900v22c)
        # Unlike the X98mini, this 8GB eMMC has only ONE factory partition big
        # enough to be useful (data, 5.5GB). So boot and storage can't both use
        # a large partition: system (1GB FAT) -> CE_FLASH holds SYSTEM+kernel;
        # data (5.5GB ext4) -> CE_STORAGE is the large ROM partition (users want
        # room for ROMs).
        # SYSTEM must fit in the 1GB system partition. The size check below
        # refuses to install and explains why if it won't fit.
        # No Android 'super' dynamic partition on this board, so no teardown needed.
        FLASH_DEV="/dev/system"
        STORAGE_DEV="/dev/data"
        FLASH_MIN_MB=900;   FLASH_MAX_MB=1100
        STORAGE_MIN_MB=4000
        SUPER_TEARDOWN=""
        DESC="E900V22C (Amlogic S905L3A/G12A, 8GB eMMC)"
        ;;
    md1000)
        # RK3566 board with a plain GPT eMMC and OUR OWN u-boot -- nothing like
        # the locked Amlogic boxes above, so METHOD is "repartition".
        #
        # The eMMC is given THE SAME THREE-PARTITION LAYOUT AS THE USB/SD IMAGE:
        #
        #   p1 EMUELEC (FAT32, 2GiB)  KERNEL + SYSTEM + dtb + extlinux
        #   p2 STORAGE (ext4,  6GiB)  persistent /storage
        #   p3 EEROMS  (ext4,  rest)  the ROM library, mounted at /storage/roms
        #
        # ★Why the layout must be exactly this, and in this order★
        # eemount (the upstream ROM mounter) does NOT look EEROMS up by label
        # first. Its order is (src/eemount.c):
        #   1. the partition backing /storage/.update
        #   2. THE DEVICE NAME OF /flash WITH ITS LAST CHARACTER REPLACED BY '3'
        #   3. only as a "last hope": LABEL=EEROMS
        # Step 2 is plain string surgery, so with /flash on p1 it lands on p3 --
        # correct only if the ROM partition really is the third one. An earlier
        # layout kept an extra boot partition in front (p1 BOOT / p2 EMUELEC /
        # p3 STORAGE); step 2 then mounted STORAGE over /storage/roms and ES
        # showed no games at all. Adding a fourth EEROMS partition does NOT fix
        # that -- step 2 succeeds before the label is ever consulted.
        # So: keep the image layout, and the heuristic is right by construction.
        #
        # ★Boot chain★
        # No chainloading and no boot.scr: this u-boot has scan_dev_for_extlinux
        # (verified by dumping the bootloader area), it scans p1 when no
        # partition is flagged bootable, and the EmuELEC image already ships
        # /flash/extlinux/extlinux.conf. The installer only has to rewrite the
        # UUIDs in that file to point at the freshly created partitions.
        # Using UUIDs (not labels) also removes the old ambiguity of having the
        # USB stick and the eMMC both carrying the labels EMUELEC/STORAGE.
        #
        # ★What survives, and what does not★
        # Untouched: the reserved area holding the vendor u-boot (its DRAM
        # timings are calibrated for this board -- replacing it is high risk).
        # Erased: EVERYTHING from the first partition on, i.e. the whole Armbian
        # install INCLUDING its /boot, which is what has been chainloading us.
        #
        # ★Do NOT repeat the old claim that "this u-boot cannot read USB"★
        # -- that is wrong, and it is still written in older notes. Reading the
        # bootloader out of the eMMC gives:
        #     boot_targets = nvme mmc1 mmc0 usb0 pxe dhcp
        # bootcmd_usb0 IS compiled in. USB simply comes AFTER mmc0, so once the
        # eMMC carries something bootable it always wins and the stick never
        # gets a turn. Same outcome, different reason -- and the reason matters,
        # because it also points at the way out:
        #   mmc1 (the SD/TF slot, fe2b0000.mmc) is scanned BEFORE mmc0 (eMMC),
        #   so a bootable TF card overrides an installed eMMC. That is the cheap
        #   recovery path IF this box physically has a card slot (the controller
        #   is probed by the kernel, but that does not prove there is a hole in
        #   the case). MASKROM is the one that always works.
        METHOD="repartition"
        EMMC_DEV="/dev/mmcblk0"
        COMPAT="rockchip,rk3566-md1000"
        EE_SIZE_GIB=2          # p1 EMUELEC, same as the USB image
        ST_SIZE_GIB=6          # p2 STORAGE, same as the USB image
                               # p3 EEROMS takes whatever is left
        DESC="MD1000 (Rockchip RK3566 TV box, 32GB eMMC)"
        ;;
    *)
        return 1
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# METHOD=repartition  (boards where we control u-boot; plain GPT eMMC)
# ---------------------------------------------------------------------------
install_repartition() {
    local EMMC="$EMMC_DEV"
    local FLASH_SRC DISKSZ LAST_USABLE P1_START EE_SIZE_S EE_END part
    local ST_START ST_SIZE_S ST_END RO_START RO_GIB
    local BK n it e DTB EE_UUID ST_UUID

    [ -b "$EMMC" ] || die "${EMMC} not found."

    # Refuse if we are already running from the eMMC (the target would be
    # the running system itself).
    FLASH_SRC=$(awk '$2=="/flash"{print $1}' /proc/mounts)
    case "$FLASH_SRC" in
        ${EMMC}*) die "Already booted from eMMC (/flash=${FLASH_SRC}) - nothing to install." ;;
        /dev/sd*) : ;;
        *) die "Unexpected /flash source: ${FLASH_SRC} (expected a USB device /dev/sd*)." ;;
    esac
    [ -f /flash/SYSTEM ] || die "/flash/SYSTEM does not exist - is this a running EmuELEC?"
    # EmuELEC's automounter mounts the Armbian partitions it finds under
    # /var/media (e.g. /var/media/BOOT, /var/media/ROOTFS). Since we are about
    # to erase them anyway, unmount them ourselves instead of dead-ending the
    # user with "unmount it first" for something they never mounted.
    # Anything mounted OUTSIDE /var/media is not ours to touch -> refuse.
    # p1 is included now: unlike the old chainload layout, it is erased too.
    local mp
    for part in "${EMMC}p1" "${EMMC}p2" "${EMMC}p3" "${EMMC}p4"; do
        while :; do
            mp=$(awk -v d="$part" '$1==d{print $2; exit}' /proc/mounts)
            [ -n "$mp" ] || break
            case "$mp" in
                /var/media/*)
                    echo ">>> ${part} is automounted at ${mp} - unmounting"
                    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || \
                        die "${part} is mounted at ${mp} and could not be unmounted."
                    ;;
                *)
                    die "${part} is mounted at ${mp} - unmount it first (refusing: not an automount)."
                    ;;
            esac
        done
    done

    # ---- geometry -------------------------------------------------------
    # NOTE: EmuELEC's busybox has NO 'blockdev', so read the size from sysfs
    # (512-byte sectors). Using blockdev here is exactly why an earlier
    # version of this installer never actually ran on real hardware.
    DISKSZ=$(cat "/sys/class/block/$(basename "$EMMC")/size" 2>/dev/null)
    [ -n "$DISKSZ" ] || die "Cannot read the size of ${EMMC} from sysfs."
    LAST_USABLE=$(( DISKSZ - 34 ))          # leave room for the secondary GPT

    # Start the new p1 exactly where the existing first partition starts, so the
    # bootloader reserved area in front of it is never touched. Do NOT hardcode
    # a sector here: read it back from the disk we are actually looking at.
    P1_START=$(parted -s "$EMMC" unit s print 2>/dev/null | \
               awk '/^[[:space:]]*1[[:space:]]/{gsub(/s/,"",$2); print $2}')
    [ -n "${P1_START:-}" ] || die "Could not read the start sector of p1."
    # Anti-brick sanity: the vendor u-boot lives in the first few MiB. If p1
    # started suspiciously early, creating a partition there would eat it.
    [ "$P1_START" -ge 32768 ] || die "p1 starts at ${P1_START}s, too close to the bootloader area. Refusing."

    EE_SIZE_S=$(( EE_SIZE_GIB * 1024 * 1024 * 1024 / 512 ))
    ST_SIZE_S=$(( ST_SIZE_GIB * 1024 * 1024 * 1024 / 512 ))
    EE_END=$(( P1_START + EE_SIZE_S - 1 ))
    ST_START=$(( EE_END + 1 ))
    ST_END=$(( ST_START + ST_SIZE_S - 1 ))
    RO_START=$(( ST_END + 1 ))
    [ "$RO_START" -lt "$LAST_USABLE" ] || die "Not enough room left for EEROMS."
    RO_GIB=$(( (LAST_USABLE - RO_START) / 2048 / 1024 ))

    cat <<EOF
================================================================
 EmuELEC eMMC installer   --   board: ${BOARD}
 ${DESC}
================================================================
 Target ${EMMC}  --  same three-partition layout as the USB image:

   p1  ${EE_SIZE_GIB}GiB  (${P1_START}s..${EE_END}s)  -> FAT32, label EMUELEC
   p2  ${ST_SIZE_GIB}GiB  (${ST_START}s..${ST_END}s)  -> ext4,  label STORAGE
   p3  ~${RO_GIB}GiB (${RO_START}s..${LAST_USABLE}s) -> ext4,  label EEROMS

 THE WHOLE DISK FROM SECTOR ${P1_START} ON IS ERASED.
 That is the entire Armbian install, INCLUDING its /boot.

 *** READ THIS TWICE ***
 Armbian's /boot is what currently lets this box start from a USB stick.
 Once it is gone, THE USB STICK WILL NOT BOOT THIS BOX ANY MORE: the
 bootloader tries the eMMC before USB, so an installed eMMC always wins.

 Recovery, in order of how cheap it is:
   - a bootable SD/TF card, IF this box has a card slot: the bootloader
     tries the card slot BEFORE the eMMC, so it overrides the install
   - MASKROM re-flash: always works. Only the bootloader reserved area in
     front of p1 is left alone (its DRAM timings are calibrated for this
     board), and that is exactly what keeps this path open.
 Do not run this unless at least one of those is available to you.

 Games are NOT copied: the ROM folders are created empty on p3 (EEROMS).
 Your games stay on the USB stick and you copy them over afterwards
 (Samba, or plug the stick in and copy). See the note printed at the end
 about reusing the stick as an external ROM drive - it needs one change.
================================================================
EOF

    if [ "${ASSUME_YES:-0}" != "1" ]; then
        read -r -p "Type YES to continue: " CONFIRM
        [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }
    fi

    # ---- back up the GPT ------------------------------------------------
    BK=/storage/emmc-gpt-backup
    mkdir -p "$BK"
    dd if="$EMMC" of="$BK/gpt-primary.bin"   bs=512 count=34 2>/dev/null
    dd if="$EMMC" of="$BK/gpt-secondary.bin" bs=512 skip="$(( DISKSZ - 33 ))" count=33 2>/dev/null
    echo ">>> GPT backed up to ${BK}"

    # ---- repartition ----------------------------------------------------
    # Use parted, never sgdisk: sgdisk is broken on this board (garbled argv).
    echo ">>> Repartitioning ${EMMC}..."
    for n in $(parted -s "$EMMC" print 2>/dev/null | \
               awk '/^[[:space:]]*[0-9]+[[:space:]]/{print $1}' | sort -rn); do
        parted -s "$EMMC" rm "$n"
    done
    parted -s "$EMMC" unit s mkpart primary fat32 "${P1_START}s" "${EE_END}s" || die "Could not create EMUELEC."
    parted -s "$EMMC" name 1 EMUELEC
    parted -s "$EMMC" set 1 msftdata on
    # Flag p1 bootable so u-boot's scan_dev_for_boot_part picks it explicitly
    # instead of relying on its "nothing flagged -> just try partition 1"
    # fallback. Non-fatal: if this parted build has no legacy_boot flag the
    # fallback still gets us there.
    parted -s "$EMMC" set 1 legacy_boot on 2>/dev/null || true
    parted -s "$EMMC" unit s mkpart primary ext4 "${ST_START}s" "${ST_END}s" || die "Could not create STORAGE."
    parted -s "$EMMC" name 2 STORAGE
    parted -s "$EMMC" unit s mkpart primary ext4 "${RO_START}s" "${LAST_USABLE}s" || die "Could not create EEROMS."
    parted -s "$EMMC" name 3 EEROMS
    partprobe "$EMMC"; sleep 3
    { [ -b "${EMMC}p1" ] && [ -b "${EMMC}p2" ] && [ -b "${EMMC}p3" ]; } || { sleep 3; partprobe "$EMMC"; sleep 2; }
    { [ -b "${EMMC}p1" ] && [ -b "${EMMC}p2" ] && [ -b "${EMMC}p3" ]; } || die "The new partitions did not appear."

    # ---- format ---------------------------------------------------------
    # EEROMS is ext4, not the vfat the USB image uses. Two reasons:
    #   1) no 4GiB file size limit (PS2/DC/PSP images run past it)
    #   2) the planned internal+external ROM aggregation stacks an overlay on
    #      top of the ROM tree, and an overlayfs upperdir needs xattr support.
    #      External sticks are usually FAT and can therefore only ever be the
    #      read-only lower layer, so the writable layer has to be this one.
    # mount_romfs.sh reads /flash/ee_fstype to know the type (eemount probes it
    # itself); it is written further down after the partition exists.
    echo ">>> Formatting..."
    mkfs.vfat -F 32 -n EMUELEC "${EMMC}p1" >/dev/null || die "mkfs.vfat failed."
    mkfs.ext4 -F -q -L STORAGE -m 0 "${EMMC}p2" >/dev/null || die "mkfs.ext4 (STORAGE) failed."
    mkfs.ext4 -F -q -L EEROMS  -m 0 "${EMMC}p3" >/dev/null || die "mkfs.ext4 (EEROMS) failed."

    mkdir -p /tmp/ee_flash /tmp/ee_storage /tmp/ee_roms
    mount "${EMMC}p1" /tmp/ee_flash   || die "Could not mount the new EMUELEC partition."
    mount "${EMMC}p2" /tmp/ee_storage || die "Could not mount the new STORAGE partition."
    mount "${EMMC}p3" /tmp/ee_roms    || die "Could not mount the new EEROMS partition."

    # ---- will the system even fit? --------------------------------------
    # Check BEFORE copying: running out of room halfway through leaves a
    # half-written SYSTEM on a disk that is now the only bootable one.
    FLASH_USED_KB=$(du -sk /flash 2>/dev/null | awk '{print $1}')
    EE_FREE_KB=$(df -k /tmp/ee_flash 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$FLASH_USED_KB" ] && [ -n "$EE_FREE_KB" ]; then
        if [ "$FLASH_USED_KB" -gt "$EE_FREE_KB" ]; then
            umount /tmp/ee_flash /tmp/ee_storage /tmp/ee_roms 2>/dev/null || true
            die "/flash needs $(( FLASH_USED_KB / 1024 ))MB but the new EMUELEC partition only has $(( EE_FREE_KB / 1024 ))MB free. Raise EE_SIZE_GIB for this board."
        fi
    fi

    # ---- copy the OS ----------------------------------------------------
    echo ">>> Copying the system to EMUELEC..."
    for it in KERNEL KERNEL.md5 SYSTEM SYSTEM.md5 extlinux oemsplash-1080.png; do
        [ -e "/flash/$it" ] && cp -a "/flash/$it" /tmp/ee_flash/
    done
    for it in /flash/*.dtb; do
        [ -e "$it" ] && cp -a "$it" /tmp/ee_flash/
    done
    echo "ext4" > /tmp/ee_flash/ee_fstype
    sync

    # ---- point extlinux.conf at the new partitions -----------------------
    # This is the whole boot chain: this u-boot has scan_dev_for_extlinux and
    # scans p1, so the extlinux.conf we just copied is what boots the box.
    # It still carries the UUIDs of the USB stick it was generated for, which
    # would send init looking for a disk that is no longer there.
    #
    # UUIDs, not labels, on purpose: after the install the stick may well be
    # plugged back in as an external ROM drive, and then BOTH disks carry the
    # labels EMUELEC and STORAGE. A label would be a coin toss; a UUID is not.
    # ★-c /dev/null is not cosmetic★: blkid keeps a cache (/run/blkid/blkid.tab)
    # and we have just re-made the filesystems on these very device nodes. A
    # cached hit would hand back the UUID of the partition that existed a minute
    # ago, and we would happily write it into the only boot config on the disk.
    EE_UUID=$(blkid -c /dev/null -s UUID -o value "${EMMC}p1") || true
    ST_UUID=$(blkid -c /dev/null -s UUID -o value "${EMMC}p2") || true
    [ -n "$EE_UUID" ] && [ -n "$ST_UUID" ] || die "Could not read the UUIDs of the new partitions."
    if [ -f /tmp/ee_flash/extlinux/extlinux.conf ]; then
        echo ">>> Pointing extlinux.conf at the eMMC (boot=${EE_UUID} disk=${ST_UUID})..."
        sed -i -e "s#boot=[^ ]*#boot=UUID=${EE_UUID}#" \
               -e "s#disk=[^ ]*#disk=UUID=${ST_UUID}#" \
               /tmp/ee_flash/extlinux/extlinux.conf || die "Could not rewrite extlinux.conf."
        grep -q "boot=UUID=${EE_UUID}" /tmp/ee_flash/extlinux/extlinux.conf || \
            die "extlinux.conf does not carry the new boot UUID - refusing to leave an unbootable install."
    else
        die "/flash/extlinux/extlinux.conf is missing - this image cannot boot from extlinux."
    fi
    # Any per-dtb variant next to it needs the same treatment.
    for it in /tmp/ee_flash/extlinux/*.conf; do
        [ "$it" = "/tmp/ee_flash/extlinux/extlinux.conf" ] && continue
        [ -e "$it" ] || continue
        sed -i -e "s#boot=[^ ]*#boot=UUID=${EE_UUID}#" \
               -e "s#disk=[^ ]*#disk=UUID=${ST_UUID}#" "$it"
    done
    sync

    # ---- copy settings, excluding games and rebuildable caches ----------
    # /storage/roms and /storage/.update are separate mount points (the ROM
    # partition). They are handled separately below, not copied wholesale.
    echo ">>> Copying settings to STORAGE (games and caches excluded)..."
    cd /storage || die "Cannot enter /storage."
    for e in * .[!.]*; do
        [ -e "$e" ] || continue
        case "$e" in
            roms|.update|.tmp|lost+found|emmc-gpt-backup|installtoemmc.log) continue ;;
            audio-backup-*) continue ;;
        esac
        cp -a "/storage/$e" /tmp/ee_storage/ 2>/dev/null || echo "  warning: could not copy $e"
    done
    rm -rf /tmp/ee_storage/.cache/cores 2>/dev/null
    # /storage/roms is only a mount point for EEROMS; it must exist and be empty.
    mkdir -p /tmp/ee_storage/roms
    sync

    # ---- seed the ROM partition -----------------------------------------
    # Copy the FOLDER TREE only, no games: the system folders are what ES needs
    # to stop logging "System <x> path does not exist" and to show its platform
    # list. Copying the games themselves could be tens of GB and is the user's
    # call, not ours.
    echo ">>> Creating the ROM folders on EEROMS (games are not copied)..."
    # Plain loop, not find -exec: busybox's find does not reliably substitute
    # {} when it is embedded in a longer argument.
    if [ -d /storage/roms ]; then
        for e in /storage/roms/*/; do
            [ -d "$e" ] || continue
            mkdir -p "/tmp/ee_roms/$(basename "$e")"
        done
    fi
    mkdir -p /tmp/ee_roms/.update
    sync

    # ★|| true★: the script runs under `set -e`, and a umount that fails (busy
    # for a moment) would abort here -- AFTER a fully successful install, with
    # a non-zero exit code. The caller (the es4all wrapper) would then print
    # "FAILED" over a box that is actually installed correctly, which is the
    # worst possible thing to tell someone about a disk-erasing operation.
    sync
    umount /tmp/ee_flash /tmp/ee_storage /tmp/ee_roms 2>/dev/null || true

    echo
    parted -s "$EMMC" print
    cat <<EOF

================================================================
 Done.
 Power off, UNPLUG THE USB STICK, then power on -> EmuELEC boots
 from the internal eMMC.

 The ROM folders on the internal disk are empty. Copy your games over,
 e.g. over Samba, or by plugging the stick in and copying from
 /var/media.

 NOTE about reusing the old stick AS AN EXTERNAL ROM DRIVE:
 its ROM partition is still labelled EEROMS, and both ROM mounters skip
 anything called EEROMS when they look for external drives (that name is
 reserved for the internal one). To use it as an external library:
   - give that partition a different label, e.g.  fatlabel /dev/sda3 GAMES
   - put the game folders under a top-level  roms/  folder on it
     (on the stick they currently sit at the root, which is the layout
     used for the INTERNAL drive - the external scan looks for */roms/)
   - and drop an empty file named  emuelecroms  inside that roms/ folder
 Otherwise just copy the games off it and reformat it.

 If it does not boot, the USB stick will NOT save you any more: the
 bootloader tries the eMMC before USB. Recovery is a bootable SD/TF card
 if this box has a card slot (the card slot is tried BEFORE the eMMC),
 otherwise a MASKROM re-flash. The bootloader area was never touched.
================================================================
EOF
    exit 0
}

list_boards() {
    echo "Supported boards:"
    for b in $BOARDS; do
        board_config "$b" && printf "  %-12s %s\n" "$b" "$DESC"
    done
}

auto_detect() {
    local b f s compat
    compat=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null)
    for b in $BOARDS; do
        board_config "$b" || continue
        # repartition boards have no factory partitions to size-match against,
        # so identify them by the device-tree compatible string instead.
        if [ "$METHOD" = "repartition" ]; then
            if [ -n "$compat" ] && echo "$compat" | grep -qF "$COMPAT"; then
                echo "$b"; return 0
            fi
            continue
        fi
        [ -b "$FLASH_DEV" ] && [ -b "$STORAGE_DEV" ] || continue
        f=$(dev_size_mb "$FLASH_DEV") || continue
        s=$(dev_size_mb "$STORAGE_DEV") || continue
        if [ "$f" -ge "$FLASH_MIN_MB" ] && [ "$f" -le "$FLASH_MAX_MB" ] \
           && [ "$s" -ge "$STORAGE_MIN_MB" ]; then
            echo "$b"; return 0
        fi
    done
    return 1
}

# ---- argument handling ----
ARG="${1:-}"
case "$ARG" in
    ""|-h|--help|help)
        echo "Usage: $(basename "$0") <board>|auto|list"
        list_boards
        exit 0 ;;
    list|--list)
        list_boards; exit 0 ;;
    auto|--auto)
        BOARD=$(auto_detect) || die "Could not auto-detect a supported board from the eMMC layout."
        echo ">>> Auto-detected board: ${BOARD}" ;;
    -*)
        BOARD="${ARG#-}" ;;   # allow -x98mini
    *)
        BOARD="$ARG" ;;
esac

board_config "$BOARD" || { echo "Unknown board: ${BOARD}" >&2; echo; list_boards; exit 1; }

# ---- safety checks ----
[ "$(id -u)" = "0" ] || die "Must run as root."

# Boards that need a real repartition take a completely different path from
# the "reuse two factory partitions" flow below.
if [ "${METHOD}" = "repartition" ]; then
    install_repartition
fi
[ -b "$FLASH_DEV" ]   || die "${FLASH_DEV} not found - board '${BOARD}' expects this factory partition. Wrong board/device?"
[ -b "$STORAGE_DEV" ] || die "${STORAGE_DEV} not found - wrong board/device?"

# Refuse if we are already booted from eMMC (/flash would be the target itself).
FLASH_SRC=$(awk '$2=="/flash"{print $1}' /proc/mounts)
case "$FLASH_SRC" in
    "$FLASH_DEV"|"$STORAGE_DEV") die "Already running from eMMC - nothing to do." ;;
esac

FLASH_SIZE_MB=$(dev_size_mb "$FLASH_DEV")   || die "Cannot read size of ${FLASH_DEV}."
STORAGE_SIZE_MB=$(dev_size_mb "$STORAGE_DEV") || die "Cannot read size of ${STORAGE_DEV}."

# Anti-brick sanity: refuse if the partition sizes are wildly off what this
# board expects - could mean it is not really this board or the layout changed.
if [ "$FLASH_SIZE_MB" -lt "$FLASH_MIN_MB" ] || [ "$FLASH_SIZE_MB" -gt "$FLASH_MAX_MB" ]; then
    die "Unexpected size for ${FLASH_DEV}: ${FLASH_SIZE_MB}MB (expected ${FLASH_MIN_MB}-${FLASH_MAX_MB}MB). Refusing - wrong device?"
fi
if [ "$STORAGE_SIZE_MB" -lt "$STORAGE_MIN_MB" ]; then
    die "Unexpected size for ${STORAGE_DEV}: ${STORAGE_SIZE_MB}MB (expected >=${STORAGE_MIN_MB}MB). Refusing - wrong device?"
fi

# The contents of /flash (SYSTEM squashfs + kernel.img) must fit on FLASH_DEV.
# This matters most for boards like the E900V22C with a small boot partition
# (system, 1GB). Check this up front so we refuse before touching any
# partition, instead of failing with no-space-left mid-copy after Android has
# already been erased.
FLASH_NEED_MB=$(du -sm /flash 2>/dev/null | cut -f1)
FLASH_AVAIL_MB=$(( FLASH_SIZE_MB - 16 ))   # reserve for the FAT32 table/overhead
if [ -n "$FLASH_NEED_MB" ] && [ "$FLASH_NEED_MB" -gt "$FLASH_AVAIL_MB" ]; then
    die "/flash needs ${FLASH_NEED_MB}MB, but ${FLASH_DEV} only has about ${FLASH_AVAIL_MB}MB available.
Refusing to install (no partition has been touched).

The firmware currently running is too large to fit on this board's boot
partition. Re-flash your SD/USB with a current build and try again."
fi

cat <<EOF
================================================================
 EmuELEC eMMC dual-boot installer   --   board: ${BOARD}
 ${DESC}
================================================================
 This will ERASE and reformat two eMMC partitions:

   ${FLASH_DEV}    (${FLASH_SIZE_MB}MB)  -> FAT32, label ${CE_FLASH_LABEL}
   ${STORAGE_DEV}  (${STORAGE_SIZE_MB}MB)  -> ext4,  label ${CE_STORAGE_LABEL}

 These are factory Android partitions. Android will no longer boot
 after this. Bootloader / env / tee and every other partition are
 left untouched. The current SD/USB EmuELEC system + storage will be
 copied to eMMC; remove the SD/USB and reboot to boot from eMMC.

 IRREVERSIBLE without re-flashing Android separately.
================================================================
EOF

read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }

[ "${SUPER_TEARDOWN}" = "yes" ] && teardown_android_super

echo ">>> Formatting ${FLASH_DEV} as FAT32 (${CE_FLASH_LABEL})..."
umount "$FLASH_DEV" 2>/dev/null || true
mkfs.vfat -F 32 -n "$CE_FLASH_LABEL" "$FLASH_DEV"

echo ">>> Formatting ${STORAGE_DEV} as ext4 (${CE_STORAGE_LABEL})..."
umount "$STORAGE_DEV" 2>/dev/null || true
mkfs.ext4 -F -L "$CE_STORAGE_LABEL" "$STORAGE_DEV"

mkdir -p "$MNT_FLASH" "$MNT_STORAGE"
mount "$FLASH_DEV" "$MNT_FLASH"
mount "$STORAGE_DEV" "$MNT_STORAGE"

echo ">>> Copying boot files from /flash to ${CE_FLASH_LABEL}..."
cp -a /flash/. "$MNT_FLASH/"

echo ">>> Copying current /storage to ${CE_STORAGE_LABEL} (this can take a while)..."
cp -a /storage/. "$MNT_STORAGE/"

sync
umount "$MNT_FLASH"
umount "$MNT_STORAGE"

cat <<EOF

================================================================
 Done. Remove the SD/USB and power-cycle the device.
 The stock Android u-boot's cfgloademmc fallback will detect
 ${CE_FLASH_LABEL} / ${CE_STORAGE_LABEL} on eMMC and boot EmuELEC from there.

 IMPORTANT: this bootloader always tries SD, then USB, before eMMC -
 on EVERY power-on, not just this first one. As long as a bootable
 SD/USB is plugged in, it will ALWAYS boot from there instead of
 eMMC. A software reboot (from the EmulationStation menu or the
 "reboot" command) does not eject it for you - you must physically
 remove the SD/USB each time you want to boot from eMMC.

 If it does not boot, re-insert the SD/USB (untouched by this
 script) to fall back to the SD/USB installation and report it.
================================================================
EOF
