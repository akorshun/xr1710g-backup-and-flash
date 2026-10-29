#!/usr/bin/env python3
"""Fake XR1710G serial console for testing xr1710g-flash.ps1 without hardware.

Listens on TCP (the script's -SerialTcp) and plays the boot chain the script
drives: stock AXON U-Boot, OpenWrt U-Boot loaded into RAM, the OpenWrt
initramfs shell, and the boot from flash after the loader is written. Files
are fetched from the script's TFTP server with a real TFTP client using the
blksize/tsize/timeout options like U-Boot does. The flash lives in STATE/
mtd0..mtd3.bin, shared with fake_ssh.py.

  fake_router.py STATE PORT TFTP_PORT [--init]
"""
import json
import os
import random
import socket
import struct
import sys
import threading
import time
import queue

STATE, PORT, TFTP_PORT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
MTD = [("vendor", 0x600000), ("chainloader", 0x100000),
       ("ubi", 0x1B700000), ("reserved_bmt", 0x4200000)]
STOCK_ENV = {
    "ver": "U-Boot 2014.04-rc1 (Mar 15 2024 - 15:13:21) AXON 1.6",
    "vendor": "ecnt", "board": "an7581_evb", "loadaddr": "0x81800000",
    "fdt_high": "0xac000000",
    "bootcmd": "flash read 0x602100 0x4000000 $loadaddr; bootm",
    "ipaddr": "192.168.0.1", "serverip": "192.168.0.205",
}


def path(*p):
    return os.path.join(STATE, *p)


def init_state():
    os.makedirs(path("tmp"), exist_ok=True)
    rnd = random.Random(1710)
    v = bytearray(rnd.randbytes(0x600000))
    dsd = (b"wan_mac=02:11:22:33:44:50\0lan_mac=02:11:22:33:44:51\0"
           b"fan_id=1\0serial_number=XR1710G0123456789\0")
    v[0x400000:0x401000] = dsd.ljust(0x1000, b"\xff")
    v[0x405000:0x405002] = b"\x90\x79"
    open(path("mtd0.bin"), "wb").write(v)
    open(path("mtd1.bin"), "wb").write(b"\x27\x05\x19\x56STOCK" + rnd.randbytes(0x100000 - 9))
    with open(path("mtd2.bin"), "wb") as f:
        # the stock firmware 5.1.1.12 keeps its own UBI here
        f.write(b"UBI#" + bytes(60) + b"VOLS:rootfs_data,config,log\0" + rnd.randbytes(1 << 20))
        f.truncate(0x1B700000)
    with open(path("mtd3.bin"), "wb") as f:
        f.truncate(0x4200000)
    json.dump(STOCK_ENV, open(path("env.json"), "w"))
    set_mode("off")
    for f in ("reboot", "authorized", "installed", "detached"):
        if os.path.exists(path(f)):
            os.remove(path(f))


def set_mode(m):
    open(path("mode"), "w").write(m)


class Router:
    def __init__(self, conn):
        self.conn = conn
        self.inq = queue.Queue()
        self.ram = {}
        self.env = json.load(open(path("env.json")))
        self.prompt = "ECNT> "
        threading.Thread(target=self.reader, daemon=True).start()

    # -- io ---------------------------------------------------------------
    def reader(self):
        while True:
            try:
                d = self.conn.recv(4096)
            except OSError:
                d = b""
            if not d:
                os._exit(0)
            for c in d.decode("latin-1"):
                self.inq.put(c)

    def out(self, s):
        self.conn.sendall(s.replace("\n", "\r\n").encode("latin-1"))

    def drain(self):
        n = 0
        while True:
            try:
                self.inq.get_nowait()
                n += 1
            except queue.Empty:
                return n

    def readline(self, prompt, intr_ok=True):
        """Line editor of a console: echo, Ctrl-C, Enter. Returns the line."""
        self.out(prompt)
        line = ""
        while True:
            if os.path.exists(path("reboot")):
                return None
            try:
                c = self.inq.get(timeout=0.1)
            except queue.Empty:
                continue
            if c == "\x03":
                if intr_ok:
                    self.out("<INTERRUPT>\n" + prompt)
                line = ""
            elif c == "\r":
                self.out("\n")
                return line
            elif c == "\n":
                continue
            elif c in "\x08\x7f":
                line = line[:-1]
            else:
                line += c
                self.out(c)

    # -- hush-like words ---------------------------------------------------
    def split(self, line, env):
        """Split into commands on ';', expand $vars, honour quotes and \\."""
        cmds, words, cur, have, i, q = [], [], "", False, 0, None
        while i < len(line):
            c = line[i]
            if q == "'":
                if c == "'":
                    q = None
                else:
                    cur += c
            elif c == "\\" and i + 1 < len(line):
                i += 1
                cur += line[i]
                have = True
            elif c == '"':
                q = None if q == '"' else '"'
                have = True
            elif c == "'" and q is None:
                q = "'"
                have = True
            elif c == "$":
                j = i + 1
                if j < len(line) and line[j] == "?":
                    cur += "0"
                    i = j
                else:
                    while j < len(line) and (line[j].isalnum() or line[j] == "_"):
                        j += 1
                    cur += env.get(line[i + 1:j], "")
                    i = j - 1
                have = True
            elif q is None and c in " \t":
                if have or cur:
                    words.append(cur)
                cur, have = "", False
            elif q is None and c == ";":
                if have or cur:
                    words.append(cur)
                cmds.append(words)
                words, cur, have = [], "", False
            else:
                cur += c
                have = True
            i += 1
        if have or cur:
            words.append(cur)
        cmds.append(words)
        return [w for w in cmds if w]

    # -- RAM / flash -------------------------------------------------------
    def ram_put(self, addr, data):
        for base, blob in self.ram.items():
            if base <= addr and addr + len(data) <= base + len(blob):
                blob[addr - base:addr - base + len(data)] = data
                return
        self.ram[addr] = bytearray(data)

    def ram_get(self, addr, ln):
        for base, blob in self.ram.items():
            if base <= addr < base + len(blob):
                return bytes(blob[addr - base:addr - base + ln]).ljust(ln, b"\0")
        return b"\0" * ln

    def flash_rw(self, off, ln, data=None):
        if not (0x600000 <= off and off + ln <= 0x700000):
            raise ValueError("flash access outside the chainloader slot: %#x" % off)
        with open(path("mtd1.bin"), "r+b") as f:
            f.seek(off - 0x600000)
            if data is None:
                return f.read(ln)
            f.write(data[:ln])

    def tftp(self, name):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        srv = ("127.0.0.1", TFTP_PORT)
        s.sendto(b"\0\1" + name.encode() + b"\0octet\0timeout\0" + b"5\0tsize\0" + b"0\0blksize\0" + b"1468\0", srv)
        data, blk, want = bytearray(), 1468, 1
        while True:
            try:
                p, srv = s.recvfrom(2048)
            except socket.timeout:
                return None
            op = p[1]
            if op == 5:
                return None
            if op == 6:
                opts = p[2:].split(b"\0")
                d = dict(zip(opts[0::2], opts[1::2]))
                blk = int(d.get(b"blksize", 512))
                s.sendto(b"\0\4\0\0", srv)
                continue
            if op == 3:
                n = struct.unpack(">H", p[2:4])[0]
                if n == want & 0xFFFF:
                    data += p[4:]
                    want += 1
                s.sendto(b"\0\4" + p[2:4], srv)
                if n == (want - 1) & 0xFFFF and len(p) - 4 < blk:
                    return bytes(data)

    # -- stock U-Boot ------------------------------------------------------
    def stock_boot(self):
        set_mode("stock-uboot")
        self.ram = {}
        self.env = json.load(open(path("env.json")))
        self.out("\nAiroha preloader\n\n" + self.env["ver"] + "\n\nDRAM:  2 GiB\nNet:   eth0\n")
        self.out("Hit any key to stop autoboot:  1 ")
        time.sleep(0.8)
        if self.drain():
            self.out("\b\b0 \n")
            return self.stock_shell()
        self.out("\b\b0 \n")
        return self.run_bootcmd()

    def run_bootcmd(self):
        cmds = self.split(self.env["bootcmd"], self.env)
        src = None
        for w in cmds:
            if w[0] == "flash" and w[1] == "read":
                src = int(w[2], 16)
            if w[0] == "bootm":
                break
        slot = self.flash_rw(0x600000, 0x100000)
        if src == 0x600000 and slot[:4] == b"\xd0\x0d\xfe\xed" and b"Linux-u-boot" in slot:
            return self.flash_uboot("U-Boot 2026.01-OpenWrt (Oct 27 2026)")
        if slot[:4] == b"\x27\x05\x19\x56" and slot[0x2100:0x2104] == b"\xd0\x0d\xfe\xed" \
                and src in (0x600000, 0x602100):
            return self.flash_uboot("U-Boot 2026.07-00762-g59060dde7b91 xr1710g http-uboot")
        if slot[4:9] == b"STOCK" and src == 0x602100:
            self.out("## Booting kernel\nStarting kernel ...\n\nLinux version 5.4.55 (stock)\n")
            set_mode("stock-linux")
            return "idle"
        self.out("Wrong Image Format for bootm command\nERROR: can't get kernel image!\n")
        return self.stock_shell()

    def flash_uboot(self, banner):
        self.out("\n" + banner + "\n\n")
        if not os.path.exists(path("installed")):
            self.out("UBI error: no valid UBI volumes\n")
            return self.ram_uboot_shell()
        self.out("Hit any key to stop autoboot:  3 \n## Loading kernel from FIT Image\n")
        return self.linux("openwrt")

    def stock_shell(self):
        set_mode("stock-uboot")
        self.prompt = "ECNT> "
        while True:
            line = self.readline(self.prompt)
            if line is None:
                continue
            for w in self.split(line, self.env):
                r = self.stock_cmd(w)
                if r:
                    return r

    def common_cmd(self, w):
        c = w[0]
        if c == "echo":
            self.out(" ".join(w[1:]) + "\n")
        elif c == "setenv":
            if len(w) == 2:
                self.env.pop(w[1], None)
            else:
                self.env[w[1]] = " ".join(w[2:])
        elif c == "printenv":
            names = w[1:] or sorted(self.env)
            for n in names:
                if n in self.env:
                    self.out("%s=%s\n" % (n, self.env[n]))
                else:
                    self.out("## Error: \"%s\" not defined\n" % n)
        elif c == "tftpboot":
            addr = int(w[1], 16)
            self.out("Using eth0 device\nTFTP from server %s; our IP address is %s\nFilename '%s'.\n"
                     % (self.env.get("serverip"), self.env.get("ipaddr"), w[2]))
            data = self.tftp(w[2])
            if data is None:
                self.out("T T T \nRetry count exceeded\n")
            else:
                self.ram_put(addr, data)
                self.out("#################\ndone\nBytes transferred = %d (%x hex)\n" % (len(data), len(data)))
        elif c == "mw.b":
            self.ram[int(w[1], 16)] = bytearray([int(w[2], 16)]) * int(w[3], 16)
        elif c == "cmp.b":
            a, b, n = int(w[1], 16), int(w[2], 16), int(w[3], 16)
            x, y = self.ram_get(a, n), self.ram_get(b, n)
            same = next((i for i in range(n) if x[i] != y[i]), n)
            if same < n:
                self.out("byte at 0x%08x (%#04x) != byte at 0x%08x (%#04x)\n" % (a + same, x[same], b + same, y[same]))
            self.out("Total of %d byte(s) were the same\n" % same)
        elif c == "md.b":
            a = int(w[1], 16)
            d = self.ram_get(a, int(w[2], 16))
            self.out("%08x: %s\n" % (a, " ".join("%02x" % x for x in d)))
        else:
            return False
        return True

    def stock_cmd(self, w):
        if self.common_cmd(w):
            return None
        c = w[0]
        if c == "saveenv":
            json.dump(self.env, open(path("env.json"), "w"))
            self.out("Saving Environment to Flash...\ndone\n")
        elif c == "flash":
            off, ln = int(w[2], 16), int(w[3], 16)
            if w[1] == "erase":
                self.flash_rw(off, ln, b"\xff" * ln)
                self.out("erase: addr=%#x, len=%#x\n" % (off, ln))
            elif w[1] == "write":
                self.flash_rw(off, ln, self.ram_get(int(w[4], 16), ln))
                # as the real AXON U-Boot: progress dots, then the prompt on the same line
                self.out("write: src=%s, len=%#x, dst=%#x\n" % (w[4], ln, off) + "." * 25)
            elif w[1] == "read":
                self.ram_put(int(w[4], 16), self.flash_rw(off, ln))
                self.out("Read from %#x len %#x OK\n" % (off, ln))
        elif c == "bootm":
            img = self.ram_get(int(w[1], 16), 0x100000)
            if img[:4] == b"\xd0\x0d\xfe\xed" and b"Linux-u-boot" in img:
                self.out("## Loading kernel from FIT Image at 89000000 ...\nStarting kernel ...\n\n")
                self.out("U-Boot 2026.01-OpenWrt (Oct 27 2026)\n\n")
                return self.ram_uboot_menu()
            self.out("Wrong Image Format for bootm command\n")
        elif c == "reset":
            self.out("resetting ...\n")
            return "reset"
        else:
            self.out("Unknown command '%s' - try 'help'\n" % c)
        return None

    # -- OpenWrt U-Boot in RAM ---------------------------------------------
    def ram_uboot_menu(self):
        set_mode("ram-uboot")
        self.env = {"loadaddr": "0x81800000", "initaddr": "0x89000000", "bootconf": "config-1",
                    "ipaddr": "192.168.1.1", "serverip": "192.168.1.10"}
        self.out("Loading Environment from UBI... UBI error: too many corrupted PEBs, refusing\n")
        self.out("*** Warning - bad CRC, using default environment\n\n")
        self.out("  *** U-Boot Boot Menu ***\n\n     1. Run default boot command.\n     0. U-Boot console\n")
        t = time.time()
        while time.time() - t < 3:
            try:
                if self.inq.get(timeout=0.1) == "\x03":
                    break
            except queue.Empty:
                pass
        else:
            self.out("ubi0 error: cannot attach\n")
        self.drain()
        return self.ram_uboot_shell()

    def ram_uboot_shell(self):
        set_mode("ram-uboot")
        self.env.setdefault("initaddr", "0x89000000")
        self.env.setdefault("bootconf", "config-1")
        self.prompt = "U-Boot> "
        while True:
            line = self.readline(self.prompt)
            if line is None:
                continue
            for w in self.split(line, self.env):
                if self.common_cmd(w):
                    continue
                if w[0] == "bootm":
                    addr = int(w[1].split("#")[0], 16)
                    img = self.ram_get(addr, 64 << 20)
                    if b"no-attach\0" not in img or b"gemtek,xr1710g-ubi" not in img:
                        self.out("TEST FAILURE: not the backup initramfs\n")
                        continue
                    self.out("## Loading kernel from FIT Image at %08x ...\nStarting kernel ...\n\n" % addr)
                    return self.linux("initramfs")
                self.out("Unknown command '%s' - try 'help'\n" % w[0])

    # -- Linux -------------------------------------------------------------
    def linux(self, kind):
        self.out("[    0.000000] Linux version 6.18.55 (OpenWrt)\n")
        self.out("[    1.000000] spi-nand spi0.0: Winbond SPI NAND was found.\n")
        set_mode(kind)
        time.sleep(0.5)
        self.out("Please press Enter to activate this console.\n")
        while True:
            try:
                c = self.inq.get(timeout=0.1)
            except queue.Empty:
                if os.path.exists(path("reboot")):
                    break
                continue
            if c == "\r":
                break
        while not os.path.exists(path("reboot")):
            line = self.readline("root@OpenWrt:/# ", intr_ok=False)
            if line is None:
                break
            if line.strip() == "sync; reboot":
                open(path("reboot"), "w").write("1")
                break
            if "authorized_keys" in line and kind == "initramfs":
                open(path("authorized"), "w").write(line)
            if 'XR_""RC=$?' in line:
                self.out("XR_RC=0\n")
            elif line.startswith('echo XR_""BOARD='):
                self.out("XR_BOARD=gemtek,xr1710g-ubi\n")
        os.remove(path("reboot"))
        for f in ("authorized", "detached"):
            if os.path.exists(path(f)):
                os.remove(path(f))
        self.out("[  100.000000] reboot: Restarting system\n")
        return "reset"


def main():
    if "--init" in sys.argv:
        init_state()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(1)
    conn, _ = srv.accept()
    r = Router(conn)
    time.sleep(1.5)
    while True:
        res = r.stock_boot()
        if res == "idle":
            while not os.path.exists(path("poweroff")):
                time.sleep(0.2)
            return
        if res != "reset":
            return


if __name__ == "__main__":
    main()
