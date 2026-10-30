#!/usr/bin/env python3
"""Stand-in for ssh.exe in tests: answers the commands xr1710g-flash.ps1 runs
on the initramfs, against the flash files of fake_router.py. The state
directory comes from XR_FAKE_STATE; the remote command is the last argument.
"""
import hashlib
import os
import re
import sys
import time

STATE = os.environ["XR_FAKE_STATE"]
MTD = [("vendor", 0x600000), ("chainloader", 0x100000),
       ("ubi", 0x1B700000), ("reserved_bmt", 0x4200000)]


def path(*p):
    return os.path.join(STATE, *p)


def fail(msg, rc=255):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


args = sys.argv[1:]
cmd = args[-1]
mode = open(path("mode")).read()
if mode != "initramfs":
    fail("ssh: connect to host 192.168.1.1 port 22: Connection timed out")
if not os.path.exists(path("authorized")):
    fail("root@192.168.1.1: Permission denied (publickey).")
key = args[args.index("-i") + 1]
if open(key + ".pub").read().split()[1] not in open(path("authorized")).read():
    fail("root@192.168.1.1: Permission denied (publickey).")

out = sys.stdout.buffer


def sha(f):
    h = hashlib.sha256()
    with open(f, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def tmpfile(name):
    return path("tmp", os.path.basename(name))


if cmd == "echo XR_SSH_OK":
    print("XR_SSH_OK")
elif "ubidetach -m 2" in cmd:
    # a flashed router has the "fit" volume mapped by ubiblock and claimed by fitblk
    if b"fit," in open(path("mtd2.bin"), "rb").read(256) and "fitblk" not in cmd:
        fail("ubiblock: error!: cannot remove block device\n"
             "         error 16 (Resource busy)", 1)
    open(path("detached"), "w").write("1")
elif cmd.startswith("cat /proc/mtd"):
    print("dev:    size   erasesize  name")
    for i, (n, s) in enumerate(MTD):
        print('mtd%d: %08x 00020000 "%s"' % (i, s, n))
    if cmd != "cat /proc/mtd":
        print("\ngemtek,xr1710g-ubi\nLinux OpenWrt 6.18.55 #0 SMP aarch64 GNU/Linux")
        for i, (n, s) in enumerate(MTD):
            print("mtd%d %s bad_blocks=0 ecc_failures=0" % (i, n))
        # like OpenWrt's 490 patch: "ubi" is auto-attached if it starts with UBI#
        head = open(path("mtd2.bin"), "rb").read(256)
        if head[:4] == b"UBI#" and not os.path.exists(path("detached")):
            print("XR_UBI_ATTACHED")
            # volume names: "VOLS:a,b,c\0" after the fake EC header
            if head[64:69] == b"VOLS:":
                for v in head[69:head.index(b"\0", 69)].decode().split(","):
                    print("XR_UBI_VOL " + v)
        print("[    1.0] spi-nand spi0.0: Winbond SPI NAND was found.")
elif re.fullmatch(r"cat /dev/mtd\d", cmd):
    with open(path(cmd[9:] + ".bin"), "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            out.write(b)
elif re.fullmatch(r"sha256sum /dev/mtd\d", cmd):
    print("%s  %s" % (sha(path(cmd[15:] + ".bin")), cmd[10:]))
elif cmd == "rm -rf /tmp/xr && mkdir -p /tmp/xr":
    for f in os.listdir(path("tmp")):
        os.remove(path("tmp", f))
elif cmd.startswith("cat > /tmp/xr/"):
    with open(tmpfile(cmd[6:]), "wb") as f:
        f.write(sys.stdin.buffer.read())
elif cmd.startswith("sha256sum /tmp/xr/"):
    print("%s  %s" % (sha(tmpfile(cmd[10:])), cmd[10:]))
elif cmd.startswith("sh /tmp/xr/install-ubi.sh "):
    files = cmd.split()[2:5]
    for f in files:
        if not os.path.exists(tmpfile(f)):
            fail("[xr1710g] ERROR: missing file: " + f, 1)
    fac = open(tmpfile(files[0]), "rb").read()
    assert len(fac) == 0x10000 and fac[:2] == b"\x90\x79", "bad factory.bin"
    assert fac[0x5000:0x5006] == bytes.fromhex("021122334450"), "bad WAN MAC"
    assert fac[0x6000:0x6006] == bytes.fromhex("021122334451"), "bad LAN MAC"
    assert fac[0x8000:0x8000 + 17] == b"XR1710G0123456789", "bad serial"
    with open(path("mtd2.bin"), "r+b") as f:
        f.write(b"UBI#" + bytes(60) + b"VOLS:ubootenv,ubootenv2,factory,recovery,fit,rootfs_data\0")
    open(path("installed"), "w").write(sha(tmpfile(files[2])))
    print("[xr1710g] ubiformat /dev/mtd2 (439 MiB)\n[xr1710g] read-back check")
    print("XR_INSTALL_OK")
elif cmd == "mtd write - ubi 2>&1":
    if (open(path("mtd2.bin"), "rb").read(4) == b"UBI#"
            and not os.path.exists(path("detached"))):
        fail("Could not open mtd device: ubi (busy, UBI attached)", 1)
    with open(path("mtd2.bin"), "r+b") as f:
        for b in iter(lambda: sys.stdin.buffer.read(1 << 20), b""):
            f.write(b)
    if os.path.exists(path("installed")):
        os.remove(path("installed"))
    print("Unlocking ubi ...\nWriting from <stdin> to ubi ...")
elif cmd == "sync":
    # a real ssh is slow to come back; the script must not rely on its timing
    time.sleep(2)
else:
    fail("fake_ssh: unexpected command: " + cmd, 127)
