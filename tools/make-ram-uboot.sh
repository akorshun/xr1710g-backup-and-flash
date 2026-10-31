#!/bin/sh
# Make firmware/xr1710g-ram-uboot.itb from an OpenWrt chainload-uboot.itb.
#
# The script boots the OpenWrt U-Boot from RAM to fetch the backup initramfs. That
# U-Boot loads its environment from UBI (CONFIG_ENV_UBI_PART="ubi"), and attaching
# UBI on the "ubi" partition of a stock router erases the stock firmware banks
# (0x700000-0x8600000, which UBI does not recognise) or crashes the loader. Here the
# partition label "ubi" becomes "ubz" in both copies of the device tree (the one
# appended to u-boot.bin, which U-Boot uses, and fdt-1 of the FIT), so the
# environment lookup finds no partition and UBI is never attached. Nothing else
# changes; the FIT is rebuilt with the same layout and fresh hashes.
#
# Needs dumpimage/mkimage (u-boot-tools) and python3.
#   tools/make-ram-uboot.sh IN-chainload-uboot.itb OUT.itb
set -e
in=$(readlink -f "$1"); out=$(readlink -f "$2")
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cd "$t"
dumpimage -T flat_dt -p 0 -o kernel.lzma "$in" >/dev/null
dumpimage -T flat_dt -p 1 -o fdt.dtb "$in" >/dev/null
python3 - <<'EOF'
import lzma, struct

def relabel(buf, base):
    """Turn label = "ubi" of the nand partition into "ubz" in the FDT at buf[base:]."""
    magic, total, off_struct, off_strings = struct.unpack_from(">4I", buf, base)
    assert magic == 0xD00DFEED
    p, path, hits = base + off_struct, [], 0
    while True:
        tok, = struct.unpack_from(">I", buf, p); p += 4
        if tok == 1:
            e = buf.index(b"\0", p); path.append(buf[p:e].decode()); p = (e + 4) & ~3
        elif tok == 2:
            path.pop()
        elif tok == 3:
            ln, no = struct.unpack_from(">II", buf, p); p += 8
            s = base + off_strings + no
            name = buf[s:buf.index(b"\0", s)].decode()
            if name == "label" and buf[p:p + ln] == b"ubi\0" and "partitions" in "/".join(path):
                buf[p:p + ln] = b"ubz\0"; hits += 1
            p = (p + ln + 3) & ~3
        elif tok == 4:
            continue
        else:
            break
    assert hits == 1, hits
    return base + total

u = bytearray(lzma.decompress(open("kernel.lzma", "rb").read(), format=lzma.FORMAT_ALONE))
i, n = 0, 0
while (i := u.find(b"\xd0\x0d\xfe\xed", i)) >= 0:
    try:
        i = relabel(u, i); n += 1
    except (AssertionError, struct.error, ValueError, UnicodeDecodeError):
        i += 4
assert n == 1, "expected one device tree in u-boot.bin, found %d" % n
f = bytearray(open("fdt.dtb", "rb").read())
relabel(f, 0)
open("fdt-noubi.dtb", "wb").write(f)
c = lzma.compress(bytes(u), format=lzma.FORMAT_ALONE, filters=[{"id": lzma.FILTER_LZMA1,
    "dict_size": 1 << 23, "lc": 3, "lp": 0, "pb": 2, "preset": 9}])
assert lzma.decompress(c, format=lzma.FORMAT_ALONE) == bytes(u)
open("u-boot-noubi.lzma", "wb").write(c)
EOF
cat > ram.its <<'EOF'
/dts-v1/;
/ {
	description = "ARM64 OpenWrt FIT (Flattened Image Tree)";
	#address-cells = <1>;
	images {
		kernel-1 {
			description = "ARM64 OpenWrt Linux-u-boot (RAM boot, no UBI)";
			data = /incbin/("u-boot-noubi.lzma");
			type = "kernel";
			arch = "arm64";
			os = "linux";
			compression = "lzma";
			load = <0x80200000>;
			entry = <0x80200000>;
			hash-1 { algo = "crc32"; };
			hash-2 { algo = "sha1"; };
		};
		fdt-1 {
			description = "ARM64 OpenWrt gemtek_xr1710g-ubi device tree blob";
			data = /incbin/("fdt-noubi.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			load = <0x82000000>;
			hash-1 { algo = "crc32"; };
			hash-2 { algo = "sha1"; };
		};
	};
	configurations {
		default = "conf-uboot";
		conf-uboot {
			description = "OpenWrt gemtek_xr1710g-ubi";
			kernel = "kernel-1";
			fdt = "fdt-1";
		};
	};
};
EOF
mkimage -f ram.its "$out" >/dev/null
echo "$out: $(wc -c < "$out") bytes"
