#!/usr/bin/env python3
"""Make the read-only "backup" initramfs for the XR1710G from an OpenWrt
initramfs-recovery.itb.

Two changes in the device tree inside the FIT, both keeping every size:

* the "ubi" partition loses its `compatible = "linux,ubi"` (the value becomes
  "no-attach"), so the kernel does not attach UBI through the DT. On a stock
  router that area holds the vendor firmware banks, not UBI, and an attach is
  not something to try before the backup is taken;
* the Ethernet MACs (/soc/ethernet@*/ethernet@*) lose `nvmem-cells` and
  `nvmem-cell-names`: they point into the "factory" UBI volume, which a stock
  router does not have, and the Ethernet driver would wait for it forever
  (deferred probe), leaving the initramfs without network. The properties are
  renamed to "cells"/"cell-names" by pointing their names at the tail of the
  same strings, so the driver falls back to a random MAC.

Every other byte stays as built by OpenWrt; the crc32/sha1 hashes of the fdt
image are recomputed so U-Boot accepts the FIT.

  make-backup-initramfs.py IN.itb OUT.itb    write the patched image
  make-backup-initramfs.py --check IMG.itb   show the ubi partition and hashes
"""
import hashlib
import re
import struct
import sys
import zlib

FDT_MAGIC = 0xD00DFEED
OLD = b"linux,ubi\0"
NEW = b"no-attach\0"
UBI_REG = struct.pack(">II", 0x00700000, 0x1B700000)  # UBI 2.0


RENAME = {"nvmem-cells": "cells", "nvmem-cell-names": "cell-names"}


def eth_mac_props(fit, dtb_off):
    """(path, name, name-offset position) of nvmem props of the Ethernet MACs."""
    out = []
    for path, name, off, ln in walk(fit, dtb_off):
        if re.fullmatch(r"/soc/ethernet@[0-9a-f]+/ethernet@\d+", path) and name in RENAME:
            out.append((path, name, off - 4))
    return out


def walk(buf, base):
    """Yield (kind, path, offset, length) for an FDT at buf[base:]."""
    magic, _total, off_struct, off_strings = struct.unpack_from(">4I", buf, base)
    if magic != FDT_MAGIC:
        raise ValueError("no FDT at %#x" % base)
    p, strs, path = base + off_struct, base + off_strings, []
    while True:
        tok, = struct.unpack_from(">I", buf, p)
        p += 4
        if tok == 1:  # FDT_BEGIN_NODE
            end = buf.index(b"\0", p)
            path.append(buf[p:end].decode())
            p = (end + 4) & ~3
        elif tok == 2:  # FDT_END_NODE
            path.pop()
        elif tok == 3:  # FDT_PROP
            ln, nameoff = struct.unpack_from(">II", buf, p)
            p += 8
            end = buf.index(b"\0", strs + nameoff)
            name = buf[strs + nameoff:end].decode()
            yield "/".join(path), name, p, ln
            p = (p + ln + 3) & ~3
        elif tok == 4:  # FDT_NOP
            continue
        elif tok == 9:  # FDT_END
            return
        else:
            raise ValueError("bad FDT token %#x at %#x" % (tok, p - 4))


def props(buf, base):
    return {(path, name): (off, ln) for path, name, off, ln in walk(buf, base)}


def locate(fit):
    p = props(fit, 0)
    data = p.get(("/images/fdt-1", "data"))
    if not data:
        raise ValueError("FIT has no /images/fdt-1 with inline data")
    hashes = {}
    for (path, name), (off, ln) in p.items():
        if path.startswith("/images/fdt-1/hash") and name == "algo":
            algo = fit[off:off + ln].rstrip(b"\0").decode()
            hashes[algo] = p[(path, "value")]
    return data, hashes


def ubi_node(fit, dtb_off):
    dt = props(fit, dtb_off)
    nodes = [path for (path, name), (off, ln) in dt.items()
             if name == "label" and fit[off:off + ln] == b"ubi\0"]
    if len(nodes) != 1:
        raise ValueError("expected one partition labelled ubi, found %d" % len(nodes))
    node = nodes[0]
    reg = dt.get((node, "reg"))
    comp = dt.get((node, "compatible"))
    return node, reg, comp


def describe(fit):
    (doff, dlen), hashes = locate(fit)
    node, reg, comp = ubi_node(fit, doff)
    print("fdt-1     : %d bytes at %#x" % (dlen, doff))
    print("partition : %s" % node)
    print("reg       : %s" % fit[reg[0]:reg[0] + reg[1]].hex())
    print("compatible: %s" % (fit[comp[0]:comp[0] + comp[1]] if comp else None))
    left = eth_mac_props(fit, doff)
    print("eth nvmem  : %s" % (", ".join("%s:%s" % (p, n) for p, n, _ in left) or "none"))
    blob = fit[doff:doff + dlen]
    ok = True
    for algo, (off, ln) in sorted(hashes.items()):
        want = fit[off:off + ln]
        got = (struct.pack(">I", zlib.crc32(blob) & 0xFFFFFFFF) if algo == "crc32"
               else hashlib.new(algo, blob).digest())
        ok &= want == got
        print("%-10s: %s %s" % (algo, want.hex(), "ok" if want == got else "MISMATCH"))
    return ok


def patch(src, dst):
    fit = bytearray(open(src, "rb").read())
    (doff, dlen), hashes = locate(fit)
    node, reg, comp = ubi_node(fit, doff)
    if not reg or fit[reg[0]:reg[0] + reg[1]] != UBI_REG:
        raise SystemExit("%s: ubi partition is not UBI 2.0 (0x700000 + 0x1b700000)" % src)
    if not comp or fit[comp[0]:comp[0] + comp[1]] != OLD:
        raise SystemExit("%s: %s has no compatible = \"linux,ubi\"" % (src, node))
    if set(hashes) - {"crc32", "sha1"} or not hashes:
        raise SystemExit("%s: unexpected fdt hash algorithms %s" % (src, sorted(hashes)))
    fit[comp[0]:comp[0] + comp[1]] = NEW
    macs = eth_mac_props(fit, doff)
    if not macs:
        raise SystemExit("%s: no nvmem MAC properties on the Ethernet nodes" % src)
    _m, _t, _os, off_strings = struct.unpack_from(">4I", fit, doff)
    for path, name, pos in macs:
        nameoff, = struct.unpack_from(">I", fit, pos)
        new = nameoff + len(name) - len(RENAME[name])
        s0 = doff + off_strings + new
        assert fit[s0:fit.index(b"\0", s0)].decode() == RENAME[name]
        struct.pack_into(">I", fit, pos, new)
    blob = bytes(fit[doff:doff + dlen])
    for algo, (off, ln) in hashes.items():
        val = (struct.pack(">I", zlib.crc32(blob) & 0xFFFFFFFF) if algo == "crc32"
               else hashlib.sha1(blob).digest())
        assert len(val) == ln
        fit[off:off + ln] = val
    open(dst, "wb").write(fit)
    if not describe(bytes(fit)):
        raise SystemExit("hash check failed after patching")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        sys.exit(0 if describe(open(sys.argv[2], "rb").read()) else 1)
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    patch(sys.argv[1], sys.argv[2])
