#!/bin/sh
# Lay out UBI 2.0 on the Gemtek XR1710G and install OpenWrt into it.
#
# Runs inside xr1710g-backup-initramfs.itb (RAM only, the "ubi" partition is
# not attached by the kernel there). xr1710g-flash.ps1 uploads this script
# with the images and starts it after the stock flash has been backed up.
#
#   install-ubi.sh FACTORY.bin RECOVERY.itb SYSUPGRADE.itb
#
# Volumes, in the order and with the sizes of hurrian's w1700k-ubi-installer
# (files/installer/install.sh, GPL-3.0):
#   0 ubootenv   1 LEB      U-Boot environment
#   1 ubootenv2  1 LEB      redundant copy
#   2 factory    static     Wi-Fi EEPROM + MACs, built on the PC from vendor DSD
#   3 recovery   dynamic    OpenWrt initramfs, "Boot recovery system from flash"
#   4 fit        dynamic    the sysupgrade FIT, written by OpenWrt's nand.sh
#     rootfs_data           the rest, created by nand_upgrade_fit

# busybox ash on OpenWrt has "local"
# shellcheck disable=SC3043
set -e

# Root prefix for tests/test-install-ubi.sh; empty on the router.
R=${XR_ROOT:-}

FACTORY=$1
RECOVERY=$2
SYSUPGRADE=$3

# "ubi" of the UBI 2.0 layout: 0x00700000 + 0x1b700000, end 0x1be00000
UBI_SIZE=$((0x1b700000))
LEB=126976

log() { echo "[xr1710g] $*"; }
die() { echo "[xr1710g] ERROR: $*" >&2; exit 1; }

for f in "$FACTORY" "$RECOVERY" "$SYSUPGRADE"; do
	[ -s "$f" ] || die "missing file: $f"
done

grep -q 'gemtek,xr1710g' "$R/tmp/sysinfo/board_name" 2>/dev/null \
	|| die "not an XR1710G initramfs: $(cat "$R/tmp/sysinfo/board_name" 2>/dev/null)"

mtd=$(grep '"ubi"$' "$R/proc/mtd" | cut -d: -f1)
[ -n "$mtd" ] || die "no \"ubi\" partition in $R/proc/mtd"
mtdnum=${mtd#mtd}
size=$(cat "$R/sys/class/mtd/$mtd/size")
[ "$size" = "$UBI_SIZE" ] \
	|| die "ubi partition is $size bytes, UBI 2.0 needs $UBI_SIZE"

ubi_mknod() {
	local dev="${1##*/}"
	[ -e "$R/dev/$dev" ] && return 0
	[ -e "$R/sys/class/ubi/$dev/uevent" ] || return 1
	# shellcheck disable=SC1090
	. "$R/sys/class/ubi/$dev/uevent"
	mknod "$R/dev/$dev" c "$MAJOR" "$MINOR"
}

# Detach whatever is attached to this partition (a re-run after a failure).
for d in "$R"/sys/class/ubi/ubi[0-9]*; do
	[ -e "$d/mtd_num" ] || continue
	if [ "$(cat "$d/mtd_num")" = "$mtdnum" ]; then
		ubidetach -m "$mtdnum"
	fi
done

log "ubiformat /dev/$mtd ($((size / 1048576)) MiB)"
ubiformat "$R/dev/$mtd" -y
ubiattach -m "$mtdnum" -d 0
sleep 1
ubi_mknod ubi0

mkvol() {
	# mkvol ID NAME TYPE SIZE [FILE]
	ubimkvol /dev/ubi0 -n "$1" -N "$2" -t "$3" -s "$4"
	ubi_mknod "ubi0_$1"
	if [ -n "$5" ]; then
		ubiupdatevol "$R/dev/ubi0_$1" "$5"
	fi
}

log "volumes ubootenv, ubootenv2"
mkvol 0 ubootenv dynamic $LEB
mkvol 1 ubootenv2 dynamic $LEB
log "volume factory ($(wc -c < "$FACTORY") bytes)"
mkvol 2 factory static "$(wc -c < "$FACTORY")" "$FACTORY"
log "volume recovery ($(wc -c < "$RECOVERY") bytes)"
mkvol 3 recovery dynamic "$(wc -c < "$RECOVERY")" "$RECOVERY"
sync

log "volume fit + rootfs_data (nand_upgrade_fit)"
# shellcheck disable=SC1091
. "$R/lib/functions.sh"
# shellcheck disable=SC1091
. "$R/lib/upgrade/common.sh"
# shellcheck disable=SC1091
. "$R/lib/upgrade/nand.sh"
export CI_KERNPART=fit CI_UBIPART=ubi
nand_upgrade_fit "$SYSUPGRADE" cat
sync

vol_id() {
	local v
	for v in "$R"/sys/class/ubi/ubi0_*; do
		if [ "$(cat "$v/name")" = "$1" ]; then
			basename "$v"
		fi
	done
}

# Read every volume back and compare it with its source.
check() {
	# check NAME FILE
	local id len want got
	id=$(vol_id "$1")
	[ -n "$id" ] || die "volume $1 is missing"
	ubi_mknod "$id"
	len=$(wc -c < "$2")
	want=$(sha256sum < "$2" | cut -d' ' -f1)
	got=$(head -c "$len" "$R/dev/$id" | sha256sum | cut -d' ' -f1)
	[ "$want" = "$got" ] || die "volume $1 does not read back as $2"
	log "  $1 ok ($id, $len bytes)"
}
log "read-back check"
check factory "$FACTORY"
check recovery "$RECOVERY"
check fit "$SYSUPGRADE"
[ -n "$(vol_id rootfs_data)" ] || die "volume rootfs_data is missing"

ubinfo /dev/ubi0 -a | grep -E '^(Volume ID|Name|Size|Type):' | sed 's/^/  /'
ubidetach -m "$mtdnum"
sync
echo XR_INSTALL_OK
