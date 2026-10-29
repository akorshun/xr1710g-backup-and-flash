# XR1710G: stock backup and OpenWrt with the UBI 2.0 layout, from Windows in one script

**English** | [Русский](README.ru.md)

A script for the Gemtek XR1710G (Brightspeed XR1710G, Airoha AN7581, 512 MiB SPI-NAND).
It takes the router from the stock firmware to a working OpenWrt by itself:

1. stops the stock boot loader over UART and **takes a full flash backup** to the
   PC (all 512 MiB, checked with sha256) before anything is written to flash;
2. lays the flash out for **UBI 2.0** right away (`ubi` = `0x700000 + 0x1b700000`,
   528 PEBs reserved for the vendor loader's BMT) and installs OpenWrt;
3. writes **the loader of your choice** to the `chainloader` slot — U-Boot with
   HTTP recovery (YYH2913) or the vanilla OpenWrt chainloaded U-Boot;
4. reboots the router and checks that OpenWrt came up from flash.

There are also "backup only", "restore stock from a backup" and "loader only" modes.
Messages are in English or Russian: the script asks at start (`-Lang en` / `-Lang ru`
skips the question).

> [!NOTE]
> **Verified on hardware (XR1710G, 2026-10-28):** stock backup, UBI 2.0 layout,
> OpenWrt `xr1710g-r2` install and the OpenWrt loader (`-Loader openwrt`) — the
> router boots OpenWrt, Ethernet and Wi-Fi (EEPROM from the factory volume) work.
> `firmware/` now carries the newer `xr1710g-r8` build; its reset-button TFTP
> recovery has not been run through the script on hardware yet.
> The http-uboot loader (`-Loader http`) and Restore mode are so far covered only
> by the emulator (`tests/`). The stock backup is taken first, the vendor loader
> (0x0–0x600000) is never touched, and the UART stays a working way to recover.

## What you need

* an XR1710G on the stock firmware (or already flashed — then the "backup" is a
  copy of whatever is there now; the script warns about it);
* a **3.3 V** USB-UART adapter (CH340, CP2102, FT232, PL2303) with its driver;
* a Torx T10 screwdriver, an Ethernet cable;
* Windows 10/11, PowerShell 5.1 (built in), the **OpenSSH client**
  (Settings → System → Optional features; usually already present on Windows 11),
  administrator rights;
* ~600 MB of free space for the backup.

## Wiring

1. A Torx T10 screw sits under the QR-code sticker. Remove it, then pry the grey
   and white halves of the case apart starting at the port side — there are
   latches all around.
2. The UART header is next to the screw, counting from the screw:
   **TX – GND – VCC – N/C – RX**, 115200 8N1. Connect GND, router TX → adapter RX,
   router RX → adapter TX. **Do not connect VCC.**
3. Ethernet from the PC goes to a **gigabit LAN port** of the router. The stock
   loader's network driver is flaky: if TFTP fails the script retries, and you can
   move the cable to another port while it does.

The script sets `192.168.1.254/24` on that adapter itself (and puts DHCP back at
the end), as well as a temporary firewall rule for TFTP (UDP 69).

## Which loader to choose

The stock loader (U-Boot 2014.04 "AXON 1.6", signed) stays in place and boots
whatever sits in the `chainloader` slot (0x600000, 1 MiB). One of two loaders goes
there; both work with the UBI 2.0 layout.

| | **http-uboot** (YYH2913, `xr1710g_260805`) — default | **OpenWrt U-Boot** (`uboot-airoha`, vanilla) |
|---|---|---|
| Version | U-Boot 2026.07, third-party build | U-Boot 2026.07 from OpenWrt, own XR1710G configuration (reset button, LEDs) |
| Recovery | web page at `http://192.168.255.1` with its own DHCP; upload `sysupgrade.itb` and the loader itself from a browser | reset button: `initramfs-recovery.itb` over TFTP from a server on the PC, retried until it answers; a `fit` that does not boot falls back to the `recovery` volume; UART menu: TFTP, recovery from flash, TFTP installer |
| How to enter recovery | cable in the **10GbE** port, hold **reset** at power-on, release when the LED goes from red to "running" | PC `192.168.1.254/24` with a TFTP server in a **1 GbE** port (lan3/lan4, not 10GbE); power on, press **reset 1–2 s later** (held at power-on the SoC waits for a UART download) and hold it until the **blue** LED, about 15–20 s |
| UART needed after install | no | no (a TFTP server is needed instead of a browser) |
| Network in the loader | 10GbE | gigabit ports |
| UBI rebuild | from the web UI, with a choice of 2.0 / 1.5 / 1.0 layout and factory restored from DSD | by hand from an initramfs |
| AXON environment | unchanged: the slot is "dual-entry" and works with the stock `bootcmd` | `bootcmd` becomes `flash read 0x600000 0x100000 $loadaddr; bootm` (as in the OpenWrt instructions) |
| Origin | binary from the author's release, sources in [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot) | built from [akorshun/openwrt `xr1710g-r8`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r8) |

Both boot OpenWrt from the `fit` volume; updates are a plain `sysupgrade`. If in
doubt, take **http-uboot**: its recovery needs only a browser.
You can switch loaders later with http-uboot's own web page or with
`-Mode Loader`.

## Running it

Download the repository (Code → Download ZIP, or `git clone`), unpack it, then
**double-click `xr1710g-flash.cmd`** — or from PowerShell:

```powershell
.\xr1710g-flash.ps1                              # install, asks for everything
.\xr1710g-flash.ps1 -Lang en                     # English messages, no language question
.\xr1710g-flash.ps1 -ComPort COM5 -Loader http   # no questions about the port and loader
.\xr1710g-flash.ps1 -Mode Backup                 # stock backup only, flash untouched
.\xr1710g-flash.ps1 -Mode Restore -BackupDir .\backup\20261028-150000
.\xr1710g-flash.ps1 -Mode Loader -Loader openwrt   # slot + bootcmd only (see below)
.\xr1710g-flash.ps1 -Firmware D:\my-sysupgrade.itb   # your own OpenWrt build
```

The script asks for administrator rights itself. Then it:

1. asks for the message language (English / Русский, English by default; not asked
   with `-Lang en` or `-Lang ru`), the COM port and the loader (unless given as
   parameters);
2. asks you to **power the router on** — it stops autoboot itself;
3. takes the backup (a few minutes), shows the serial number and MAC addresses;
4. **asks for confirmation** (`YES`) before the first flash write;
5. lays out UBI, installs OpenWrt, reboots, writes the loader, reboots again and
   waits for OpenWrt.

About 10–15 minutes in total. All router console output goes to `serial.log`, the
script's steps to `flash.log`; both are in the backup folder.

### What happens inside

| Step | Runs in | Flash write |
|---|---|---|
| Stop the stock U-Boot, `printenv` → `stock-uboot-env.txt` | AXON U-Boot | no |
| TFTP `chainload-uboot.itb` into RAM, `bootm` | AXON U-Boot | no |
| TFTP `xr1710g-backup-initramfs.itb` into RAM, `bootm` | OpenWrt U-Boot in RAM | no |
| SSH key over the console, dump `mtd0…mtd3` over SSH with sha256 checks | initramfs in RAM | no |
| Build the `factory` volume from `mtd0-vendor.bin` | PC | no |
| `ubiformat` of the `ubi` area, volumes, OpenWrt, read back | initramfs in RAM | **yes** (0x700000–0x1be00000) |
| TFTP the loader, `flash erase/write 0x600000`, check with `cmp.b` | AXON U-Boot | **yes** (0x600000–0x700000) |
| `setenv bootcmd …; saveenv` — only for the OpenWrt U-Boot | AXON U-Boot | AXON environment |
| `reset`, wait for OpenWrt, check `board_name` | — | no |

`xr1710g-backup-initramfs.itb` is the `initramfs-recovery.itb` from the same
OpenWrt build with two changes in its DTB (see `tools/make-backup-initramfs.py`;
39 bytes change, no sizes change, the FIT hashes are recomputed):

* the `ubi` partition loses `compatible = "linux,ubi"`, so the kernel does not try
  to attach UBI over the stock data before it is backed up;
* the Ethernet MAC nodes (`gdm1`, `gdm2`, `gdm4`) lose their `nvmem-cells`: they
  point at the `factory` volume in UBI, which a stock router does not have, and
  without this change the Ethernet driver waits for it forever (deferred probe),
  leaving the initramfs without network — exactly what happened on the first
  hardware run. Without them the MACs are random.

Also, the OpenWrt kernel attaches a partition named `ubi` by itself when it
starts with `UBI#` (patch 490). The stock firmware (`XR1710G_fw_5.1.1.12`) keeps
its own UBI there too, with the volumes `rootfs_data`, `config` and `log` (its
settings and syslog), so an attached UBI alone does not mean an earlier flash. The
script looks at the volume names: only OpenWrt's (`ubootenv`, `factory`, `fit`,
`recovery`…) make it warn that the backup is not stock. In both cases it detaches
UBI (`ubidetach`) before the backup and before a restore.

The stock `bootcmd` varies: the http-uboot README gives
`flash read 0x602100 0x4000000 $loadaddr; bootm`, while one of our XR1710G units
with the same AXON 1.6 has `flash imgread 2048;bootm`. For http-uboot the script
keeps only the forms its author lists as working and replaces anything else with
`flash read 0x602100 0x4000000 $loadaddr; bootm`. The original value is saved in
`stock-uboot-env.txt` and put back by Restore mode.

The slot is written **with the stock loader's own** `flash write`, as in the
OpenWrt W1700K instructions: that loader reads the slot through its BMT table,
and only its own write is guaranteed to land where it later reads from.

## Stock backup

Folder `backup\<date-time>\`:

| File | What it is |
|---|---|
| `mtd0-vendor.bin` | 6 MiB: AXON loader, its environment, DSD (MACs, serial number), Wi-Fi EEPROM |
| `mtd1-chainloader.bin` | 1 MiB: the start of the stock `tclinux` bank |
| `mtd2-ubi.bin` | 439 MiB: stock firmware banks and data |
| `mtd3-reserved_bmt.bin` | 66 MiB: the end of flash with the vendor BMT tables |
| `SHA256SUMS` | sums checked against the flash on the router |
| `stock-uboot-env.txt` | `printenv` of the stock loader |
| `factory.bin` | the built `factory` volume (EEPROM + MACs + fan_id + serial number) |
| `router-info.txt`, `flash.log`, `serial.log` | `/proc/mtd`, bad blocks, logs |

The backup is read from Linux as is (data after ECC, no OOB). Keep the folder
somewhere safe — it is the only way back to the stock firmware.

### Restoring the stock firmware

```powershell
.\xr1710g-flash.ps1 -Mode Restore -BackupDir .\backup\20261028-150000
```

The script boots the initramfs into RAM again, writes `mtd2-ubi.bin` to the `ubi`
area (`mtd write`), then uses the stock loader to put `mtd1-chainloader.bin` back
into the slot and `bootcmd` back from `stock-uboot-env.txt`. If new bad blocks
appeared since the backup, the read-back will not match byte for byte — the
script warns about it.

### Loader only (`-Mode Loader`)

```powershell
.\xr1710g-flash.ps1 -Mode Loader -Loader openwrt   # or -Loader http
```

The last install step on its own: write the chosen loader to slot `0x600000` with
the stock U-Boot, set `bootcmd` and wait for OpenWrt. The `ubi` area is not
touched and no backup is taken. Use it when Install stopped after the UBI 2.0
layout was written (the log says "UBI 2.0 laid out"), or to switch between
http-uboot and the OpenWrt loader.

## UBI 2.0 layout

| Partition | Offset | Size | |
|---|---|---|---|
| `vendor` | `0x00000000` | `0x00600000` | AXON loader, `uenv`, `dsd` — not touched |
| `chainloader` | `0x00600000` | `0x00100000` | http-uboot or OpenWrt U-Boot |
| `ubi` | `0x00700000` | `0x1b700000` | UBI, ends at `0x1be00000` |
| `reserved_bmt` | `0x1be00000` | `0x04200000` | 528 PEBs for the vendor BMT — not touched |

UBI volumes (as in hurrian's installer): `0 ubootenv`, `1 ubootenv2`,
`2 factory` (static, 64 KiB: EEPROM @0, WAN MAC @0x5000, LAN MAC @0x6000,
fan_id @0x7000, serial number @0x8000), `3 recovery` (OpenWrt initramfs),
`fit` and `rootfs_data` — created by OpenWrt's `nand_upgrade_fit`.

Any image you install (including later through http-uboot's recovery) must be
built with the same layout: the DTB inside the FIT has
`ubi` = `<0x00700000 0x1b700000>`. The script checks this for `-Firmware` and
refuses UBI 1.5 (`0x1d9c0000`) and UBI 1.0 (`0x1f700000`) images. In the
http-uboot web recovery pick **UBI 2.0** for such images.

## After the install

* OpenWrt: `http://192.168.1.1`, `root` has no password — set one.
* Updates: `sysupgrade` with `*-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb`.
* Wi-Fi radios start disabled, as usual in OpenWrt. On this build `wifi config`
  may leave out `band` for the third radio: set `wireless.radio2.band='6g'` and a
  fixed 6 GHz channel (for example `37`) — automatic channel selection did not
  start the 6 GHz AP on our unit.
* http-uboot recovery: PC in the 10GbE port with DHCP, reset at power-on,
  `http://192.168.255.1`, target `firmware`, layout `UBI 2.0`.
* OpenWrt U-Boot recovery: PC `192.168.1.254/24` in a **1 GbE** port (lan3/lan4 — the
  loader has no 10GbE), a TFTP server
  serving `openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb`;
  power on, press reset 1–2 s later and hold it until the blue LED (15–20 s).
  The recovery system comes up at `192.168.1.1`, sysupgrade from there. If the
  `fit` volume does not boot, the loader starts the `recovery` volume by itself.
  Over the UART the same is in the loader menu ("Boot system via TFTP",
  "Boot recovery system from flash").
  The loader from `xr1710g-r5` … `r7` (written by earlier versions of this
  script) looks for the TFTP server at `192.168.1.10` instead: give the PC that
  address, or put the r8 loader in with `-Mode Loader -Loader openwrt`.
* Coming from `xr1710g-r2` … `r4`: those set the compat version to 2.0, which
  later builds dropped, so sysupgrade refuses them. First run
  `uci set system.@system[0].compat_version=1.0 && uci commit system`. The
  chainloader is not updated by sysupgrade: to get the r8 loader with the
  button recovery, run `-Mode Loader -Loader openwrt`.

## If something goes wrong

* **"the stock U-Boot never showed up on the console"** — check the COM port,
  GND, TX/RX (often swapped), and that the adapter is 3.3 V.
* **"could not stop the boot"** — the script asks you to cycle power and tries again.
* **TFTP fails** — move the cable to another LAN port; `flash.log` shows the TFTP
  server state. Third-party firewalls (not Windows Firewall) need UDP 69 open.
* **An error before the "UBI 2.0 layout" step** — nothing was written to flash,
  the stock firmware boots as usual, just run the script again.
* **An error after the layout, before the loader was written** — the stock firmware
  is already erased, but the vendor loader is intact: run
  `-Mode Loader -Loader <your choice>` to finish.
* **OpenWrt did not boot after the loader was written** — see `serial.log`. With
  http-uboot the router goes into web recovery by itself if it finds no `fit`.

The manual path the script follows — stock loader commands from the
[OpenWrt instructions](https://github.com/openwrt/openwrt/pull/22397):

```
setenv serverip 192.168.1.254 ; setenv ipaddr 192.168.1.1
tftpboot 0x89000000 openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb
setenv one flash read 0x600000 0x100000 \$loadaddr
setenv two "; bootm"
setenv bootcmd "$one$two"
saveenv
flash erase 0x600000 0x100000
flash write 0x600000 0x100000 0x89000000
reset
```

## Files

| File | Source | sha256 |
|---|---|---|
| `xr1710g-flash.ps1`, `xr1710g-flash.cmd` | this repository | |
| `router/install-ubi.sh` | this repository; volume order and sizes and the `factory` build come from `install.sh` in [hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer/blob/46df1f5282f53c6757752354d7b6702f6fa54ec5/files/installer/install.sh) | |
| `firmware/xr1710g-chainloader-slot.bin` | [YYH2913/http-uboot, release `xr1710g_260805`](https://github.com/YYH2913/http-uboot/releases/tag/xr1710g_260805) | `deaefed3…d27be30` |
| `firmware/openwrt-…-chainload-uboot.itb` | [akorshun/openwrt, release `xr1710g-r8`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r8) (commit `c2235765d1`) | `85ed1978…c21ca4` |
| `firmware/openwrt-…-initramfs-recovery.itb` | same | `e984690c…440b5d64` |
| `firmware/openwrt-…-squashfs-sysupgrade.itb` | same | `fd3e1bbe…6c7a41` |
| `firmware/xr1710g-backup-initramfs.itb` | `tools/make-backup-initramfs.py` from `initramfs-recovery.itb` | `cf32aee4…4e080` |

Full sums are in `firmware/SHA256SUMS`; the script checks them on every run.

The OpenWrt build `xr1710g-r8` comes from the `main-gemtek-xr1710g` branch
(OpenWrt main, kernel 6.18.55, XR1710G support modelled on the W1700K plus 10G
link fixes, U-Boot 2026.07 with its own XR1710G configuration); `xr1710g-r2` from
the same branch was installed by the script and boots on hardware (2026-10-28). With `-Firmware`
you can install any other build for `gemtek,xr1710g-ubi` with UBI 2.0.

## Sources and credits

* **The chainloader install method** (slot 0x600000, the stock loader's
  `flash write`, `bootcmd` via `one`/`two`, opening the case and the UART pinout) —
  the OpenWrt commit "airoha: add support for Gemtek W1700K" by Andrew LaMarche,
  merged into OpenWrt by Christian Marangi:
  [openwrt/openwrt#17869, 9930758](https://github.com/openwrt/openwrt/pull/17869/changes/99307582dea256731a8006a734a41ac6f26be5b7).
* **XR1710G support** and its chainloader — Kenneth Kasilag (hurrian),
  [openwrt/openwrt#22397](https://github.com/openwrt/openwrt/pull/22397);
  the `main-gemtek-xr1710g` branch the images are built from is based on it.
* **The UBI installer**: the `ubootenv`/`ubootenv2`/`factory`/`recovery`/`fit`
  volumes, the EEPROM search (magic 0x7990, little-endian — bytes `90 79`, from
  0x405000), the DSD fields `wan_mac`, `lan_mac`, `fan_id`, `serial_number` and
  the `factory` volume layout —
  [hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer)
  (GPL-3.0), itself based on
  [dangowrt/owrt-ubi-installer](https://github.com/dangowrt/owrt-ubi-installer)
  (Daniel Golle).
* **The UBI 2.0 layout** (`0x1b700000`, 528 PEB reserve), the "dual-entry" slot
  (shim `27 05 19 56` at 0x600000, FIT at 0x602100), the compatible `bootcmd`
  forms, HTTP recovery and the `xr1710g-chainloader-slot.bin` loader —
  [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot).
* The script itself, the TFTP server, building `factory` on the PC, the backup
  initramfs, the backup/restore/loader modes and the test emulator — this
  repository (Andrey Korshunov). The http-uboot slot was verified on hardware
  earlier in
  [akorshun/xr1710g-uboot-recovery](https://github.com/akorshun/xr1710g-uboot-recovery).

## License

The scripts are GPL-3.0 (`LICENSE`): `router/install-ubi.sh` and the `factory`
build in `xr1710g-flash.ps1` follow the logic of hurrian's GPL-3.0 installer.
The binary images in `firmware/` are distributed under their projects' terms
(OpenWrt and U-Boot — GPL-2.0); the source code is linked in the table above.

## Tests

```powershell
.\tests\run-fake.ps1          # end-to-end emulator run: Backup (ru, stock UBI), Install x2, Backup of a flashed router, Loader, Restore, UBI 1.0 refusal
```

```sh
sh tests/test-install-ubi.sh  # install-ubi.sh with stubbed ubi-utils
python tools/make-backup-initramfs.py --check firmware/xr1710g-backup-initramfs.itb
```

CI runs all of these (`.github/workflows/check.yml`).
