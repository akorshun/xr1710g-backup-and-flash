#!/bin/sh
# Runs router/install-ubi.sh against a fake /proc, /sys and /dev under a temp
# root (XR_ROOT) with stub ubi-utils in PATH. nand_upgrade_fit is replaced by a
# stub that creates fit + rootfs_data the way OpenWrt's nand.sh does.
#
#   SH="busybox sh" tests/test-install-ubi.sh

# shellcheck disable=SC2015
set -e
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../router/install-ubi.sh"
SH=${SH:-sh}
fails=0
FAULT=
UBI_SIZE=

setup() {
	T=$(mktemp -d)
	R="$T/root"
	mkdir -p "$R/proc" "$R/sys/class/mtd/mtd2" "$R/sys/class/ubi" "$R/dev" \
		"$R/tmp/sysinfo" "$R/lib/upgrade" "$T/bin"
	echo gemtek,xr1710g-ubi > "$R/tmp/sysinfo/board_name"
	cat > "$R/proc/mtd" <<-'EOF'
	dev:    size   erasesize  name
	mtd0: 00600000 00020000 "vendor"
	mtd1: 00100000 00020000 "chainloader"
	mtd2: 1b700000 00020000 "ubi"
	mtd3: 04200000 00020000 "reserved_bmt"
	EOF
	echo "${UBI_SIZE:-460324864}" > "$R/sys/class/mtd/mtd2/size"
	: > "$R/lib/functions.sh"
	: > "$R/lib/upgrade/common.sh"
	cat > "$R/lib/upgrade/nand.sh" <<-'EOF'
	nand_upgrade_fit() {
		len=$($2 < "$1" | wc -c)
		ubimkvol /dev/ubi0 -N "$CI_KERNPART" -s "$len"
		$2 < "$1" | ubiupdatevol "/dev/ubi0_4" -s "$len" -
		ubimkvol /dev/ubi0 -N rootfs_data -m
	}
	EOF
	# stubs: all state lives under $XR_ROOT
	cat > "$T/bin/ubiformat" <<-'EOF'
	#!/bin/sh
	echo "ubiformat $*" >> "$XR_ROOT/log"
	EOF
	cat > "$T/bin/ubiattach" <<-'EOF'
	#!/bin/sh
	mkdir -p "$XR_ROOT/sys/class/ubi/ubi0"
	echo 2 > "$XR_ROOT/sys/class/ubi/ubi0/mtd_num"
	printf 'MAJOR=250\nMINOR=0\n' > "$XR_ROOT/sys/class/ubi/ubi0/uevent"
	echo "ubiattach $*" >> "$XR_ROOT/log"
	EOF
	cat > "$T/bin/ubidetach" <<-'EOF'
	#!/bin/sh
	echo "ubidetach $*" >> "$XR_ROOT/log"
	EOF
	cat > "$T/bin/ubimkvol" <<-'EOF'
	#!/bin/sh
	shift
	id=
	while [ $# -gt 0 ]; do
		case "$1" in
		-n) id=$2; shift ;;
		-N) name=$2; shift ;;
		-s|-t) shift ;;
		esac
		shift
	done
	if [ -z "$id" ]; then
		id=0
		while [ -e "$XR_ROOT/sys/class/ubi/ubi0_$id" ]; do id=$((id + 1)); done
	fi
	d="$XR_ROOT/sys/class/ubi/ubi0_$id"
	[ ! -e "$d" ] || { echo "ubimkvol: volume $id exists" >&2; exit 1; }
	mkdir -p "$d"
	echo "$name" > "$d/name"
	printf 'MAJOR=250\nMINOR=%s\n' "$((id + 1))" > "$d/uevent"
	echo "ubimkvol $id $name" >> "$XR_ROOT/log"
	EOF
	cat > "$T/bin/ubiupdatevol" <<-'EOF'
	#!/bin/sh
	dev=$XR_ROOT/dev/${1##*/}
	if [ "$2" = -s ]; then cat > "$dev"; else cat "$2" > "$dev"; fi
	# fault injection: the volume named in $FAULT reads back short
	n=$(cat "$XR_ROOT/sys/class/ubi/${1##*/}/name" 2>/dev/null)
	if [ -n "$FAULT" ] && [ "$n" = "$FAULT" ]; then
		head -c 100 "$dev" > "$dev.x" && mv "$dev.x" "$dev"
	fi
	EOF
	cat > "$T/bin/mknod" <<-'EOF'
	#!/bin/sh
	: >> "$1"
	EOF
	cat > "$T/bin/ubinfo" <<-'EOF'
	#!/bin/sh
	for v in "$XR_ROOT"/sys/class/ubi/ubi0_*; do
		echo "Volume ID:   ${v##*_}"
		echo "Name:        $(cat "$v/name")"
	done
	EOF
	chmod +x "$T"/bin/*
	head -c 65536 /dev/urandom > "$T/factory.bin"
	head -c 300000 /dev/urandom > "$T/recovery.itb"
	head -c 500000 /dev/urandom > "$T/sysupgrade.itb"
}

run() {
	# run NAME EXPECT(ok|fail) [GREP]
	out=$(XR_ROOT="$R" FAULT="$FAULT" PATH="$T/bin:$PATH" $SH "$script" \
		"$T/factory.bin" "$T/recovery.itb" "$T/sysupgrade.itb" 2>&1) && rc=0 || rc=$?
	result=ok
	[ "$rc" = 0 ] && echo "$out" | grep -q XR_INSTALL_OK || result=fail
	if [ "$result" = "$2" ] && { [ -z "$3" ] || echo "$out" | grep -q "$3"; }; then
		echo "PASS $1"
	else
		echo "FAIL $1 (rc=$rc)"
		echo "$out" | sed 's/^/    /'
		fails=$((fails + 1))
	fi
}

setup
run "install succeeds" ok
names=$(for v in "$R"/sys/class/ubi/ubi0_*; do cat "$v/name"; done | tr '\n' ' ')
if [ "$names" = "ubootenv ubootenv2 factory recovery fit rootfs_data " ]; then
	echo "PASS volume ids and names"
else
	echo "FAIL volumes: $names"; fails=$((fails + 1))
fi
cmp -s "$R/dev/ubi0_2" "$T/factory.bin" && echo "PASS factory content" \
	|| { echo "FAIL factory content"; fails=$((fails + 1)); }
grep -q "ubiformat $R/dev/mtd2 -y" "$R/log" && echo "PASS ubiformat on mtd2" \
	|| { echo "FAIL ubiformat target"; cat "$R/log"; fails=$((fails + 1)); }
rm -rf "$T"

setup
FAULT=recovery
run "short read-back is caught" fail "volume recovery does not read back"
FAULT=
rm -rf "$T"

UBI_SIZE=$((0x1f700000))
setup
UBI_SIZE=
run "UBI 1.0 sized partition refused" fail "UBI 2.0 needs"
[ ! -e "$R/log" ] && echo "PASS nothing touched" || { echo "FAIL ubi touched"; fails=$((fails + 1)); }
rm -rf "$T"

setup
echo gemtek,w1700k-ubi > "$R/tmp/sysinfo/board_name"
run "other board refused" fail "not an XR1710G"
rm -rf "$T"

[ "$fails" = 0 ] && echo "all install-ubi.sh tests passed" || { echo "$fails failed"; exit 1; }
