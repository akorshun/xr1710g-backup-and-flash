<#
.SYNOPSIS
    Gemtek / Brightspeed XR1710G: back up the stock firmware and install OpenWrt
    (UBI 2.0 layout) from Windows over UART and Ethernet.

.DESCRIPTION
    Drives the router's boot loader over a USB-UART adapter and serves the files
    from its own TFTP server. Install mode:
      1. Stock U-Boot (AXON): stop autoboot, save printenv, TFTP the OpenWrt
         U-Boot into RAM and boot the OpenWrt initramfs from it. Nothing is
         written to flash and the environment is not saved at this stage.
      2. initramfs in RAM: every flash partition (vendor, chainloader, ubi,
         reserved_bmt) is copied to the PC over SSH and checked with sha256;
         the factory volume is built on the PC from vendor (DSD + EEPROM).
      3. After confirmation: ubiformat and the UBI 2.0 volumes (ubootenv,
         ubootenv2, factory, recovery, fit + rootfs_data), read back.
      4. Stock U-Boot: the chosen loader goes into the chainloader slot
         (0x600000, 1 MiB) with its own flash write and is read back, bootcmd
         is changed if needed, then the router reboots into OpenWrt.

    Backup mode runs steps 1-2 and reboots the router into the stock firmware.
    Restore mode writes the stock firmware back from such a backup.
    Loader mode runs step 4 only: finish an Install that stopped after the UBI
    layout was written, or switch the loader on an installed router.

.PARAMETER Mode
    Install (default), Backup, Restore or Loader.
.PARAMETER Loader
    http - YYH2913's U-Boot with HTTP recovery; openwrt - OpenWrt chainloaded U-Boot.
    Asked interactively when not given.
.PARAMETER Lang
    en or ru: language of the messages. Asked interactively when not given.
.PARAMETER ComPort
    COM port of the USB-UART adapter (COM3 etc.). Picked from a list when not given.
.PARAMETER Firmware
    Your own sysupgrade.itb instead of firmware\...-squashfs-sysupgrade.itb.
    Must be built for gemtek,xr1710g-ubi with the UBI 2.0 layout.
.PARAMETER BackupDir
    Install/Backup: where to put the backup (default backup\<date-time>).
    Restore: folder with an earlier backup.
.EXAMPLE
    .\xr1710g-flash.ps1 -ComPort COM5 -Loader http
.EXAMPLE
    .\xr1710g-flash.ps1 -Mode Backup -Lang ru
.EXAMPLE
    .\xr1710g-flash.ps1 -Mode Restore -BackupDir .\backup\20261028-150000
.EXAMPLE
    .\xr1710g-flash.ps1 -Mode Loader -Loader openwrt
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Backup', 'Restore', 'Loader')]
    [string]$Mode = 'Install',
    [ValidateSet('', 'http', 'openwrt')]
    [string]$Loader = '',
    [ValidateSet('', 'en', 'ru')]
    [string]$Lang = '',
    [string]$ComPort = '',
    [string]$Firmware = '',
    [string]$BackupDir = '',
    [string]$PcIp = '192.168.1.10',
    [string]$UbootIp = '192.168.1.2',
    [string]$RouterIp = '192.168.1.1',
    [switch]$SkipNetworkSetup,
    [switch]$Yes,
    # for tests without hardware (tests\run-fake.ps1)
    [string]$SerialTcp = '',
    [string]$SshExe = '',
    [string]$SshPrefix = '',
    [int]$TftpPort = 69,
    [int]$TimeScale = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root = $PSScriptRoot
$FwDir = Join-Path $Root 'firmware'
$Files = @{
    OpenWrtUboot = 'openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb'
    HttpUboot    = 'xr1710g-chainloader-slot.bin'
    Backup       = 'xr1710g-backup-initramfs.itb'
    Recovery     = 'openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb'
    Sysupgrade   = 'openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb'
}

# Partitions OpenWrt sees on the XR1710G with the UBI 2.0 layout
$Layout = @(
    @{ Mtd = 'mtd0'; Name = 'vendor';       Size = 0x00600000 },
    @{ Mtd = 'mtd1'; Name = 'chainloader';  Size = 0x00100000 },
    @{ Mtd = 'mtd2'; Name = 'ubi';          Size = 0x1b700000 },
    @{ Mtd = 'mtd3'; Name = 'reserved_bmt'; Size = 0x04200000 }
)

# Stock loader bootcmd and the values each chainloader works with
$StockBootcmd = 'flash read 0x602100 0x4000000 $loadaddr; bootm'
$OpenWrtBootcmd = 'flash read 0x600000 0x100000 $loadaddr; bootm'
$HttpBootcmds = @($StockBootcmd, $OpenWrtBootcmd,
    'flash read 0x602100 0x100000 $loadaddr; bootm 0x81800000',
    'flash read 0x600000 0x100000 $loadaddr; bootm 0x81802100')

# ---------------------------------------------------------------------------
# Helper classes: console (COM, or TCP for tests), TFTP server,
# ssh runner with binary stdin/stdout.
# ---------------------------------------------------------------------------
if (-not ('XrConsole' -as [type])) {
    Add-Type -ReferencedAssemblies System -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Ports;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class XrConsole : IDisposable {
    static readonly Encoding L1 = Encoding.GetEncoding(28591);
    SerialPort port; TcpClient tcp; Stream stream;
    readonly StringBuilder buf = new StringBuilder();
    readonly object lk = new object();
    Thread reader; volatile bool stop;
    StreamWriter log;
    public bool Echo = true;

    public XrConsole(string portName, string logPath) {
        port = new SerialPort(portName, 115200, Parity.None, 8, StopBits.One);
        port.Handshake = Handshake.None;
        port.ReadTimeout = 200;
        port.Open();
        stream = port.BaseStream;
        Start(logPath);
    }
    public XrConsole(string host, int tcpPort, string logPath) {
        tcp = new TcpClient(host, tcpPort);
        tcp.NoDelay = true;
        stream = tcp.GetStream();
        stream.ReadTimeout = 200;
        Start(logPath);
    }
    void Start(string logPath) {
        log = new StreamWriter(logPath, true, L1);
        log.AutoFlush = true;
        reader = new Thread(Read);
        reader.IsBackground = true;
        reader.Start();
    }
    void Read() {
        byte[] b = new byte[8192];
        while (!stop) {
            int n;
            try { n = stream.Read(b, 0, b.Length); }
            catch (TimeoutException) { continue; }
            catch (IOException) { if (stop) break; Thread.Sleep(20); continue; }
            catch (ObjectDisposedException) { break; }
            if (n <= 0) { if (tcp != null) break; continue; }
            string s = L1.GetString(b, 0, n);
            lock (lk) { buf.Append(s); }
            try { log.Write(s); } catch (Exception) { }
            if (Echo) {
                StringBuilder o = new StringBuilder(s.Length);
                foreach (char c in s)
                    if (c == '\n' || c == '\t' || (c >= ' ' && c != (char)127)) o.Append(c);
                Console.Write(o.ToString());
            }
        }
    }
    public int Mark() { lock (lk) { return buf.Length; } }
    public string Since(int pos) {
        lock (lk) { return pos >= buf.Length ? "" : buf.ToString(pos, buf.Length - pos); }
    }
    public void Send(string s) {
        byte[] b = L1.GetBytes(s);
        lock (stream) { stream.Write(b, 0, b.Length); stream.Flush(); }
    }
    // Waits for pattern in the output from `from` on; returns the position after the match or -1.
    public Match LastMatch;
    public int WaitFor(string pattern, int from, int timeoutMs) {
        Regex re = new Regex(pattern, RegexOptions.Multiline);
        DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        do {
            Match m = re.Match(Since(from));
            if (m.Success) { LastMatch = m; return from + m.Index + m.Length; }
            Thread.Sleep(25);
        } while (DateTime.UtcNow < end);
        return -1;
    }
    // Sends s every intervalMs until pattern shows up or the time runs out.
    public int SpamUntil(string s, int intervalMs, string pattern, int from, int timeoutMs) {
        Regex re = pattern == null ? null : new Regex(pattern, RegexOptions.Multiline);
        DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        do {
            Send(s);
            Thread.Sleep(intervalMs);
            if (re != null) {
                Match m = re.Match(Since(from));
                if (m.Success) { LastMatch = m; return from + m.Index + m.Length; }
            }
        } while (DateTime.UtcNow < end);
        return -1;
    }
    public void Dispose() {
        stop = true;
        try { if (port != null) port.Close(); } catch (Exception) { }
        try { if (tcp != null) tcp.Close(); } catch (Exception) { }
        if (reader != null) reader.Join(1000);
        try { log.Dispose(); } catch (Exception) { }
    }
}

// Minimal TFTP server (RFC 1350 + blksize/tsize/timeout options), read only,
// one transfer at a time, all on one socket: U-Boot takes the server port from the
// first reply, so no per-transfer port is needed and UDP 69 is enough in the firewall.
public class XrTftp : IDisposable {
    UdpClient udp; Thread th; volatile bool stop;
    readonly Dictionary<string, string> files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public volatile string Status = "";
    public long Served;

    public XrTftp(int port) {
        udp = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        udp.Client.ReceiveTimeout = 500;
        th = new Thread(Loop);
        th.IsBackground = true;
        th.Start();
    }
    public void Add(string name, string path) { lock (files) { files[name] = path; } }

    void Send(byte[] p, IPEndPoint to) { udp.Send(p, p.Length, to); }
    static byte[] Err(int code, string msg) {
        byte[] m = Encoding.ASCII.GetBytes(msg);
        byte[] p = new byte[5 + m.Length];
        p[1] = 5; p[3] = (byte)code;
        Buffer.BlockCopy(m, 0, p, 4, m.Length);
        return p;
    }
    byte[] Receive(out IPEndPoint from) {
        from = new IPEndPoint(IPAddress.Any, 0);
        try { return udp.Receive(ref from); }
        catch (SocketException) { return null; }
    }
    void Loop() {
        while (!stop) {
            IPEndPoint from;
            byte[] p = Receive(out from);
            if (p == null || p.Length < 4 || p[1] != 1) continue;  // RRQ only
            try { Serve(p, from); }
            catch (Exception e) { Status = "error: " + e.Message; }
        }
    }
    void Serve(byte[] rrq, IPEndPoint client) {
        List<string> f = new List<string>();
        int s = 2;
        for (int i = 2; i < rrq.Length; i++)
            if (rrq[i] == 0) { f.Add(Encoding.ASCII.GetString(rrq, s, i - s)); s = i + 1; }
        if (f.Count < 2) return;
        string name = f[0].TrimStart('/');
        string path;
        lock (files) { files.TryGetValue(name, out path); }
        if (path == null || !File.Exists(path)) {
            Send(Err(1, "file not found"), client);
            Status = "not found: " + name;
            return;
        }
        byte[] data = File.ReadAllBytes(path);
        int blk = 512; int tmo = 1;
        List<string> oack = new List<string>();
        for (int i = 2; i + 1 < f.Count; i += 2) {
            string k = f[i].ToLowerInvariant(), v = f[i + 1];
            int n;
            if (k == "blksize" && int.TryParse(v, out n) && n >= 8) { blk = Math.Min(n, 1468); oack.Add(k); oack.Add(blk.ToString()); }
            else if (k == "tsize") { oack.Add(k); oack.Add(data.Length.ToString()); }
            else if (k == "timeout" && int.TryParse(v, out n) && n >= 1 && n <= 255) { tmo = n; oack.Add(k); oack.Add(v); }
        }
        Status = "sending " + name;
        if (oack.Count > 0) {
            MemoryStream ms = new MemoryStream();
            ms.WriteByte(0); ms.WriteByte(6);
            foreach (string o in oack) { byte[] b = Encoding.ASCII.GetBytes(o); ms.Write(b, 0, b.Length); ms.WriteByte(0); }
            if (!Exchange(ms.ToArray(), 0, client, tmo)) { Status = "no ack for oack: " + name; return; }
        }
        int nblocks = data.Length / blk + 1;   // the last block is shorter than blk (may be empty)
        for (int i = 1; i <= nblocks; i++) {
            int off = (i - 1) * blk, len = Math.Min(blk, data.Length - off);
            byte[] pkt = new byte[4 + len];
            pkt[1] = 3; pkt[2] = (byte)((i >> 8) & 0xff); pkt[3] = (byte)(i & 0xff);
            Buffer.BlockCopy(data, off, pkt, 4, len);
            if (!Exchange(pkt, i & 0xffff, client, tmo)) { Status = "timeout: " + name; return; }
        }
        Served++;
        Status = "sent " + name + " " + data.Length;
    }
    // Send a packet and wait for the ACK of block; a new RRQ from the client restarts.
    bool Exchange(byte[] pkt, int block, IPEndPoint client, int tmo) {
        for (int tries = 0; tries < 8 && !stop; tries++) {
            Send(pkt, client);
            DateTime end = DateTime.UtcNow.AddSeconds(tmo);
            while (DateTime.UtcNow < end && !stop) {
                IPEndPoint from;
                byte[] r = Receive(out from);
                if (r == null || r.Length < 4 || !from.Address.Equals(client.Address)) continue;
                if (r[1] == 1) throw new Exception("client restarted the transfer");
                if (r[1] == 5) return false;
                if (r[1] == 4 && ((r[2] << 8) | r[3]) == block) return true;
            }
        }
        return false;
    }
    public void Dispose() { stop = true; try { udp.Close(); } catch (Exception) { } th.Join(1000); }
}

public class XrProc {
    public int ExitCode = -1;
    public string Out = "";
    public string Err = "";

    static void Copy(Stream from, Stream to) {
        byte[] b = new byte[1 << 20];
        int n;
        while ((n = from.Read(b, 0, b.Length)) > 0) to.Write(b, 0, n);
    }
    // stdinPath/stdoutPath: binary files or an empty string (PowerShell passes $null as ""); echo prints stdout line by line.
    public static XrProc Run(string exe, string args, string stdinPath, string stdoutPath, bool echo, int timeoutMs) {
        ProcessStartInfo si = new ProcessStartInfo(exe, args);
        si.UseShellExecute = false;
        si.CreateNoWindow = true;
        si.RedirectStandardInput = true;
        si.RedirectStandardOutput = true;
        si.RedirectStandardError = true;
        XrProc r = new XrProc();
        // .NET Framework StandardInput is a StreamWriter with Console.InputEncoding; on a
        // UTF-8 console it writes a BOM first and the file arrives 3 bytes longer.
        try {
            if (Console.InputEncoding.GetPreamble().Length > 0) Console.InputEncoding = new UTF8Encoding(false);
        } catch (Exception) { }
        Process p = Process.Start(si);
        StringBuilder err = new StringBuilder();
        p.ErrorDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
        p.BeginErrorReadLine();
        Thread inT = new Thread(delegate () {
            try {
                if (!string.IsNullOrEmpty(stdinPath)) using (FileStream fs = File.OpenRead(stdinPath)) Copy(fs, p.StandardInput.BaseStream);
                p.StandardInput.Close();
            } catch (Exception) { }
        });
        inT.IsBackground = true; inT.Start();
        StringBuilder outText = new StringBuilder();
        Thread outT = new Thread(delegate () {
            try {
                if (!string.IsNullOrEmpty(stdoutPath)) {
                    using (FileStream fs = File.Create(stdoutPath)) Copy(p.StandardOutput.BaseStream, fs);
                } else {
                    string line;
                    while ((line = p.StandardOutput.ReadLine()) != null) {
                        outText.AppendLine(line);
                        if (echo) Console.WriteLine("  | " + line);
                    }
                }
            } catch (Exception) { }
        });
        outT.IsBackground = true; outT.Start();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch (Exception) { } }
        p.WaitForExit();
        outT.Join(5000);
        r.ExitCode = p.HasExited ? p.ExitCode : -1;
        r.Out = outText.ToString();
        lock (err) r.Err = err.ToString();
        return r;
    }
}
'@
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$script:LogFile = $null
function Write-Log([string]$text) {
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $text -Encoding UTF8 }
}
function Say([string]$text) {
    Write-Host ''
    Write-Host "==> $text" -ForegroundColor Cyan
    Write-Log "==> $text"
}
function Info([string]$text) { Write-Host "    $text"; Write-Log "    $text" }
function Warn([string]$text) { Write-Host "[!] $text" -ForegroundColor Yellow; Write-Log "[!] $text" }
function Fail([string]$text) { throw $text }
# Message in the chosen language: T 'English' 'Русский'
function T([string]$en, [string]$ru) { if ($script:Lang -eq 'ru') { return $ru } return $en }

function Confirm-Step([string]$question) {
    if ($Yes) { return }
    Write-Host ''
    $a = Read-Host "$question $(T 'Type YES to continue' 'Введите YES, чтобы продолжить')"
    if ($a -cne 'YES') { Fail (T 'Stopped by the user.' 'Остановлено пользователем.') }
}

function Format-Hex([long]$v) { '0x{0:x}' -f $v }

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }

function Scale([int]$seconds) { [int]($seconds * 1000 / $TimeScale) }

# ---------------------------------------------------------------------------
# File checks
# ---------------------------------------------------------------------------
function Test-Bundle {
    $sums = Join-Path $FwDir 'SHA256SUMS'
    if (-not (Test-Path $sums)) { Fail (T "missing $sums" "нет $sums") }
    $want = @{}
    foreach ($l in Get-Content -LiteralPath $sums) {
        if ($l -match '^([0-9a-f]{64})\s+\*?(.+)$') { $want[$Matches[2].Trim()] = $Matches[1] }
    }
    foreach ($f in $Files.Values) {
        $p = Join-Path $FwDir $f
        if (-not (Test-Path $p)) { Fail (T "missing file firmware\$f" "нет файла firmware\$f") }
        if ($want[$f] -ne (Get-Sha256 $p)) { Fail (T "sha256 mismatch: firmware\$f (file damaged or changed)" "sha256 не совпадает: firmware\$f (файл повреждён или изменён)") }
    }
    Info (T 'all files in firmware\ present, sha256 match' 'все файлы в firmware\ на месте, sha256 совпадают')
}

# The sysupgrade image must be for the XR1710G with the UBI 2.0 layout: the DTB in
# the FIT has the ubi partition at <0x00700000 0x1b700000>.
function Test-Sysupgrade([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $s = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    if ($s.IndexOf('gemtek,xr1710g-ubi') -lt 0) { Fail (T "$path is not built for gemtek,xr1710g-ubi" "$path собран не под gemtek,xr1710g-ubi") }
    $l1 = [Text.Encoding]::GetEncoding(28591)
    $ubi20 = $l1.GetString([byte[]](0, 0x70, 0, 0, 0x1b, 0x70, 0, 0))
    $ubi15 = $l1.GetString([byte[]](0, 0x70, 0, 0, 0x1d, 0x9c, 0, 0))
    $ubi10 = $l1.GetString([byte[]](0, 0x70, 0, 0, 0x1f, 0x70, 0, 0))
    if ($s.IndexOf($ubi15) -ge 0) { Fail (T "$path has the UBI 1.5 layout, a UBI 2.0 image is needed" "$path - разметка UBI 1.5, нужен образ с UBI 2.0") }
    if ($s.IndexOf($ubi10) -ge 0) { Fail (T "$path has the UBI 1.0 layout, a UBI 2.0 image is needed" "$path - разметка UBI 1.0, нужен образ с UBI 2.0") }
    if ($s.IndexOf($ubi20) -lt 0) { Fail (T "$path - no ubi partition 0x700000+0x1b700000 (UBI 2.0) in the DTB" "$path - в DTB не найден раздел ubi 0x700000+0x1b700000 (UBI 2.0)") }
    if ($bytes[0] -ne 0xd0 -or $bytes[1] -ne 0x0d -or $bytes[2] -ne 0xfe -or $bytes[3] -ne 0xed) {
        Fail (T "$path is not a FIT (*-squashfs-sysupgrade.itb)" "$path - это не FIT (*-squashfs-sysupgrade.itb)")
    }
}

# ---------------------------------------------------------------------------
# PC network: PcIp on the wired adapter and a firewall rule for TFTP
# ---------------------------------------------------------------------------
$script:NetUndo = $null
$script:FwRule = $null

function Invoke-Netsh([string]$netshArgs, [switch]$NoFail) {
    $out = cmd.exe /c "netsh $netshArgs 2>&1"
    Write-Log "netsh $netshArgs (rc=$LASTEXITCODE)`n$out"
    if ($LASTEXITCODE -ne 0 -and -not $NoFail) { Fail "netsh $netshArgs : $out" }
}

function Initialize-Network {
    $have = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $PcIp }
    if ($have) {
        Info (T "$PcIp is already set on adapter '$($have[0].InterfaceAlias)'" "адрес $PcIp уже есть на адаптере '$($have[0].InterfaceAlias)'")
    } else {
        $nics = @(Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | Sort-Object Name)
        if ($nics.Count -eq 0) { Fail (T 'no wired network adapters found' 'не найдено проводных сетевых адаптеров') }
        Info (T 'Wired adapters:' 'Проводные адаптеры:')
        for ($i = 0; $i -lt $nics.Count; $i++) {
            Info ("  [{0}] {1} - {2} ({3})" -f ($i + 1), $nics[$i].Name, $nics[$i].InterfaceDescription, $nics[$i].Status)
        }
        $n = 1
        if ($nics.Count -gt 1) {
            $n = [int](Read-Host (T 'Number of the adapter connected to the router' 'Номер адаптера, подключённого к роутеру'))
            if ($n -lt 1 -or $n -gt $nics.Count) { Fail (T 'wrong number' 'неверный номер') }
        }
        $nic = $nics[$n - 1]
        Write-Host ''
        Write-Host (T "Adapter '$($nic.Name)' will temporarily get the address $PcIp/24" "На адаптере '$($nic.Name)' будет временно задан адрес $PcIp/24") -ForegroundColor Yellow
        Write-Host (T '(DHCP on it is off until the script ends, then everything is put back).' '(DHCP на нём отключается до конца работы скрипта, потом всё возвращается).') -ForegroundColor Yellow
        if (-not $Yes) {
            $a = Read-Host (T 'Continue? [Y/n]' 'Продолжить? [Y/n]')
            if ($a -match '^[nNнН]') { Fail (T "set $PcIp/24 by hand and run again" "задайте адрес $PcIp/24 вручную и запустите снова") }
        }
        $ipif = Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4
        $script:NetUndo = @{ Index = $nic.ifIndex; Dhcp = [string]$ipif.Dhcp }
        # netsh, not New-NetIPAddress: that one refuses ("Inconsistent parameters PolicyStore
        # PersistentStore and Dhcp Enabled") when DHCP is off in only one of the stores.
        if ($ipif.Dhcp -eq 'Enabled') {
            Invoke-Netsh "interface ipv4 set address name=$($nic.ifIndex) source=static address=$PcIp mask=255.255.255.0"
        } else {
            Invoke-Netsh "interface ipv4 add address name=$($nic.ifIndex) address=$PcIp mask=255.255.255.0"
        }
        Info (T "$PcIp/24 set on '$($nic.Name)'" "адрес $PcIp/24 задан на '$($nic.Name)'")
    }
    $name = 'XR1710G flash TFTP (temporary)'
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol UDP `
        -LocalPort $TftpPort -RemoteAddress '192.168.1.0/24' -Profile Any | Out-Null
    $script:FwRule = $name
    Info (T "temporary firewall rule for TFTP (UDP $TftpPort) added" "временное правило брандмауэра для TFTP (UDP $TftpPort) добавлено")
}

function Restore-Network {
    if ($script:FwRule) {
        Get-NetFirewallRule -DisplayName $script:FwRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        $script:FwRule = $null
    }
    if ($script:NetUndo) {
        $u = $script:NetUndo
        $script:NetUndo = $null
        if ($u.Dhcp -eq 'Enabled') {
            Invoke-Netsh "interface ipv4 set address name=$($u.Index) source=dhcp" -NoFail
        } else {
            Invoke-Netsh "interface ipv4 delete address name=$($u.Index) address=$PcIp" -NoFail
        }
        Info (T 'network adapter settings restored' 'настройки сетевого адаптера возвращены')
    }
}

# ---------------------------------------------------------------------------
# UART
# ---------------------------------------------------------------------------
function Select-ComPort {
    if ($ComPort) { return $ComPort }
    $ports = @([IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique)
    if ($ports.Count -eq 0) { Fail (T 'no COM ports: plug in the USB-UART adapter and install its driver' 'COM-порты не найдены: подключите USB-UART и установите его драйвер') }
    $names = @{}
    Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '\((COM\d+)\)') { $names[$Matches[1]] = $_.Name } }
    if ($ports.Count -eq 1) { Info (T "COM port: $($ports[0]) $($names[$ports[0]])" "COM-порт: $($ports[0]) $($names[$ports[0]])"); return $ports[0] }
    Info (T 'COM ports:' 'COM-порты:')
    for ($i = 0; $i -lt $ports.Count; $i++) { Info ("  [{0}] {1}" -f ($i + 1), $names[$ports[$i]]) }
    $n = [int](Read-Host (T 'Number of the USB-UART port' 'Номер порта USB-UART'))
    if ($n -lt 1 -or $n -gt $ports.Count) { Fail (T 'wrong number' 'неверный номер') }
    return $ports[$n - 1]
}

$script:C = $null
$script:Prompt = ''

$ReKernel = 'Starting kernel|Linux version \d|Uncompressing Linux|Booting Linux'

# Stock U-Boot: wait for its banner, stop autoboot, learn the prompt.
function Enter-StockUboot([string]$hint, [int]$from = -1) {
    Say $hint
    # $from is the output position taken before a reboot: the banner may arrive
    # before we start waiting for it
    if ($from -lt 0) { $from = $script:C.Mark() }
    $deadline = (Get-Date).AddMinutes(10)
    $nag = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $pos = $script:C.WaitFor('U-Boot 2014|AXON|[Hh]it any key|autoboot', $from, 1000)
        if ($pos -lt 0) {
            if ((Get-Date) -gt $nag) { Warn (T 'nothing on the UART: power the router on (or cycle power), check TX/RX/GND' 'с UART ничего не приходит: включите (или передёрните) питание роутера, проверьте TX/RX/GND'); $nag = (Get-Date).AddSeconds(30) }
            continue
        }
        # Ctrl-C stops autoboot; then check that we are at the command line
        $script:C.SpamUntil([string][char]3, 40, $null, $pos, (Scale 3)) | Out-Null
        Start-Sleep -Milliseconds 300
        for ($i = 0; $i -lt 3; $i++) {
            $m = $script:C.Mark()
            $script:C.Send("echo XR_`"`"OK`r")
            if ($script:C.WaitFor('XR_OK', $m, 1500) -ge 0) {
                Learn-Prompt
                Info (T "stock U-Boot stopped, prompt '$($script:Prompt)'" "стоковый U-Boot остановлен, приглашение '$($script:Prompt)'")
                return
            }
            if ($script:C.WaitFor($ReKernel, $pos, 10) -ge 0) { break }
        }
        Warn (T 'could not stop the boot - power the router off and on again' 'не удалось остановить загрузку - выключите и включите питание роутера ещё раз')
        $from = $script:C.Mark()
    }
    Fail (T 'the stock U-Boot never showed up on the console' 'стоковый U-Boot так и не появился в консоли')
}

function Learn-Prompt {
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Milliseconds 200
        $m = $script:C.Mark()
        $script:C.Send("`r")
        Start-Sleep -Milliseconds 700
        $t = ($script:C.Since($m) -replace "`r", '') -split "`n"
        $p = $t[-1].Trim()
        if ($p) { $script:Prompt = $p; return }
    }
    Fail (T 'could not learn the U-Boot prompt' 'не удалось определить приглашение U-Boot')
}

# U-Boot command: send it, wait for the prompt, return the output.
function Invoke-Uboot([string]$cmd, [int]$timeout = 20, [switch]$NoFail) {
    $m = $script:C.Mark()
    $script:C.Send("$cmd`r")
    # the stock 'flash write' prints dots and then the prompt with no newline
    $re = '(?:\n|\.)' + [regex]::Escape($script:Prompt) + '[ \t]*\z'
    $end = $script:C.WaitFor($re, $m + $cmd.Length, (Scale $timeout))
    $out = $script:C.Since($m)
    Write-Log "U-Boot> $cmd`n$out"
    if ($end -lt 0) {
        $script:C.SpamUntil([string][char]3, 200, $re, $script:C.Mark(), 5000) | Out-Null
        if ($NoFail) { return $out }
        Fail (T "U-Boot did not answer '$cmd' within $timeout s" "U-Boot не ответил на '$cmd' за $timeout с")
    }
    return $out
}

function Get-UbootVar([string]$name) {
    $o = Invoke-Uboot "printenv $name" -NoFail
    foreach ($l in ($o -replace "`r", '') -split "`n") {
        if ($l.StartsWith("$name=")) { return $l.Substring($name.Length + 1) }
    }
    return $null
}

# setenv with any value ($ and ; inside): quotes and \$, as in the OpenWrt W1700K
# instructions; if the stock hush reads it differently - the one/two variant from there.
function Set-UbootVar([string]$name, [string]$value) {
    $esc = $value.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$')
    Invoke-Uboot "setenv $name `"$esc`"" | Out-Null
    if ((Get-UbootVar $name) -ceq $value) { return }
    $i = $value.IndexOf(';')
    if ($i -gt 0) {
        Invoke-Uboot ('setenv one ' + $value.Substring(0, $i).Replace('$', '\$')) | Out-Null
        Invoke-Uboot ('setenv two "' + $value.Substring($i).Replace('$', '\$') + '"') | Out-Null
        Invoke-Uboot "setenv $name `"`$one`$two`"" | Out-Null
        Invoke-Uboot 'setenv one' | Out-Null
        Invoke-Uboot 'setenv two' | Out-Null
        if ((Get-UbootVar $name) -ceq $value) { return }
    }
    Fail (T "could not set $name='$value' (now: '$(Get-UbootVar $name)')" "не удалось записать $name='$value' (сейчас: '$(Get-UbootVar $name)')")
}

$script:Tftp = $null

function Invoke-TftpLoad([string]$path, [string]$addr, [int]$tries = 6) {
    $name = Split-Path $path -Leaf
    $script:Tftp.Add($name, $path)
    $size = (Get-Item -LiteralPath $path).Length
    for ($i = 1; $i -le $tries; $i++) {
        $o = Invoke-Uboot "tftpboot $addr $name" 180 -NoFail
        if ($o -match 'Bytes transferred = (\d+)' -and [int64]$Matches[1] -eq $size) {
            Info (T "$name loaded over TFTP ($size bytes)" "$name загружен по TFTP ($size байт)")
            return $size
        }
        Warn (T "TFTP: attempt $i of $tries failed ($($script:Tftp.Status))" "TFTP: попытка $i из $tries не удалась ($($script:Tftp.Status))")
        if ($i -eq 2) { Warn (T 'The stock U-Boot network driver is flaky, this is normal. If it never works, move the cable to another LAN port.' 'Сетевой драйвер стокового U-Boot капризный, это нормально. Если так и не пойдёт - переткните кабель в другой LAN-порт.') }
        Start-Sleep -Seconds 2
    }
    Fail (T "could not load $name over TFTP. Check the cable, the address $PcIp and the firewall" "не удалось загрузить $name по TFTP. Проверьте кабель, адрес $PcIp и брандмауэр")
}

# From the stock U-Boot to the OpenWrt U-Boot and initramfs, all in RAM.
function Enter-RamLinux {
    Say (T 'Loading the OpenWrt U-Boot into RAM (flash untouched)' 'Загрузка U-Boot OpenWrt в ОЗУ (флеш не трогается)')
    Invoke-Uboot "setenv ipaddr $UbootIp" | Out-Null
    Invoke-Uboot "setenv serverip $PcIp" | Out-Null
    Invoke-TftpLoad (Join-Path $FwDir $Files.OpenWrtUboot) '0x89000000' | Out-Null
    $m = $script:C.Mark()
    $script:C.Send("bootm 0x89000000`r")
    $pos = $script:C.WaitFor('U-Boot 20(1[5-9]|[2-9]\d)', $m, (Scale 60))
    if ($pos -lt 0) { Fail (T 'the OpenWrt U-Boot did not start from RAM (bootm)' 'U-Boot OpenWrt не стартовал из ОЗУ (bootm)') }
    # boot menu: Ctrl-C picks Exit and gives the command line
    $script:C.SpamUntil([string][char]3, 100, '\nU-Boot> ?\z', $pos, (Scale 15)) | Out-Null
    Start-Sleep -Milliseconds 500
    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
        $m = $script:C.Mark()
        $script:C.Send("echo XR_`"`"OK`r")
        $ok = $script:C.WaitFor('XR_OK', $m, 2000) -ge 0
        if (-not $ok) { $script:C.Send([string][char]3) }
    }
    if (-not $ok) { Fail (T 'could not reach the OpenWrt U-Boot command line' 'не удалось попасть в командную строку U-Boot OpenWrt') }
    Learn-Prompt
    Info (T "OpenWrt U-Boot in RAM, prompt '$($script:Prompt)'" "U-Boot OpenWrt в ОЗУ, приглашение '$($script:Prompt)'")

    Say (T 'Loading the OpenWrt initramfs into RAM' 'Загрузка initramfs OpenWrt в ОЗУ')
    Invoke-Uboot "setenv ipaddr $UbootIp" | Out-Null
    Invoke-Uboot "setenv serverip $PcIp" | Out-Null
    Invoke-TftpLoad (Join-Path $FwDir $Files.Backup) '$initaddr' | Out-Null
    $m = $script:C.Mark()
    $script:C.Send("bootm `$initaddr#`$bootconf`r")
    if ($script:C.WaitFor('Please press Enter to activate this console', $m, (Scale 240)) -lt 0) {
        Fail (T 'the initramfs did not boot within 4 minutes' 'initramfs не загрузился за 4 минуты')
    }
    Start-Sleep -Seconds 2
    $m = $script:C.Mark()
    $script:C.Send("`r")
    if ($script:C.WaitFor('root@[^\r\n]*# ?$', $m, 10000) -lt 0) { Fail (T 'no shell prompt in the initramfs' 'нет приглашения shell в initramfs') }
    Info (T 'OpenWrt initramfs is running' 'initramfs OpenWrt работает')

    # The SSH key goes in over the console: an empty root password behaves differently
    # across dropbear builds, a key always works.
    $pub = (Get-Content -LiteralPath "$($script:Key).pub" -Raw).Trim()
    Invoke-Shell "mkdir -p /etc/dropbear && echo '$pub' > /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys"
    Wait-Ssh
}

# Command in the router shell over UART (exit code via a marker).
function Invoke-Shell([string]$cmd, [int]$timeout = 30) {
    $m = $script:C.Mark()
    $script:C.Send("$cmd; echo XR_`"`"RC=`$?`r")
    if ($script:C.WaitFor('XR_RC=(\d+)', $m, (Scale $timeout)) -lt 0) { Fail (T "no shell answer to: $cmd" "нет ответа shell на: $cmd") }
    $rc = $script:C.LastMatch.Groups[1].Value
    if ($rc -ne '0') { Fail (T "command exited with code $rc : $cmd" "команда завершилась с кодом $rc : $cmd") }
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
$script:Key = $null
$script:Ssh = $null

function ConvertTo-Arg([string]$a) {
    if ($a -notmatch '[\s"]' -and $a) { return $a }
    $r = '"'
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { $r += ('\' * (2 * $bs + 1)) + '"' }
        else { $r += ('\' * $bs) + $ch }
        $bs = 0
    }
    return $r + ('\' * (2 * $bs)) + '"'
}

function Initialize-Ssh([string]$dir) {
    if ($SshExe) { $script:Ssh = $SshExe }
    else {
        $c = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if (-not $c) { Fail (T 'no ssh.exe: Settings -> System -> Optional features -> OpenSSH Client' 'нет ssh.exe: Параметры -> Система -> Дополнительные компоненты -> Клиент OpenSSH') }
        $script:Ssh = $c.Source
    }
    $script:Key = Join-Path $dir 'id_ed25519'
    if (-not (Test-Path $script:Key)) {
        $kg = Join-Path (Split-Path $script:Ssh) 'ssh-keygen.exe'
        if ($SshExe) { $kg = 'ssh-keygen.exe' }
        $r = [XrProc]::Run($kg, "-q -t ed25519 -N `"`" -C xr1710g-flash -f $(ConvertTo-Arg $script:Key)", $null, $null, $false, 30000)
        if ($r.ExitCode -ne 0) { Fail "ssh-keygen: $($r.Err)" }
    }
    $script:KnownHosts = Join-Path $dir 'known_hosts'
}

function Get-SshArgs([string]$cmd) {
    $o = @('-i', $script:Key, '-o', 'StrictHostKeyChecking=no', '-o', "UserKnownHostsFile=$($script:KnownHosts)",
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=6', '-o', 'LogLevel=ERROR', "root@$RouterIp", $cmd)
    if ($SshPrefix) { $o = @($SshPrefix) + $o }
    return ($o | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
}

function Invoke-Ssh([string]$cmd, [int]$timeout = 60, [string]$In = $null, [string]$OutFile = $null, [switch]$Echo, [switch]$NoFail) {
    $r = [XrProc]::Run($script:Ssh, (Get-SshArgs $cmd), $In, $OutFile, [bool]$Echo, $timeout * 1000)
    Write-Log "ssh> $cmd (rc=$($r.ExitCode))`n$($r.Out)$($r.Err)"
    if ($r.ExitCode -ne 0 -and -not $NoFail) { Fail (T "ssh '$cmd' exited with code $($r.ExitCode): $($r.Err.Trim())" "ssh '$cmd' завершился с кодом $($r.ExitCode): $($r.Err.Trim())") }
    return $r
}

function Wait-Ssh {
    # a stale ARP entry for this address (from U-Boot) gets in the way of SSH; arp.exe writes
    # to stderr when there is none, and PowerShell 5.1 with ErrorActionPreference=Stop fails on it
    if (-not $SshExe) { cmd.exe /c "arp -d $RouterIp >nul 2>&1" | Out-Null }
    $end = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $end) {
        $r = Invoke-Ssh 'echo XR_SSH_OK' 15 -NoFail
        if ($r.Out -match 'XR_SSH_OK') { Info (T "SSH to $RouterIp works" "SSH до $RouterIp работает"); return }
        Start-Sleep -Seconds 3
    }
    Fail (T "no SSH to $RouterIp. The cable must be in a LAN port of the router, the PC must have $PcIp" "нет SSH до $RouterIp. Кабель должен быть в LAN-порту роутера, у ПК - адрес $PcIp")
}

# ---------------------------------------------------------------------------
# Stock backup
# ---------------------------------------------------------------------------
function Test-MtdLayout([string]$procMtd) {
    foreach ($p in $Layout) {
        $re = '(?m)^' + $p.Mtd + ': ([0-9a-f]{8}) ([0-9a-f]{8}) "' + $p.Name + '"'
        if ($procMtd -notmatch $re) { Fail ((T "/proc/mtd has no $($p.Mtd) `"$($p.Name)`" - wrong layout or image" "в /proc/mtd нет $($p.Mtd) `"$($p.Name)`" - это не та разметка/не тот образ") + "`n$procMtd") }
        if ([Convert]::ToInt64($Matches[1], 16) -ne $p.Size) { Fail (T "$($p.Name): size 0x$($Matches[1]), expected $(Format-Hex $p.Size)" "$($p.Name): размер 0x$($Matches[1]), ожидался $(Format-Hex $p.Size)") }
    }
}

# Detach UBI from the ubi partition so the kernel writes nothing there during a dump or write.
function Dismount-Ubi {
    Invoke-Ssh 'for b in /dev/ubiblock*; do [ -e "$b" ] && ubiblock -r "/dev/ubi${b#/dev/ubiblock}"; done; ubidetach -m 2 2>/dev/null; [ ! -e /sys/class/ubi/ubi0 ]' 60 | Out-Null
    Info (T 'UBI detached from the ubi partition' 'UBI отключён от раздела ubi')
}

function Save-Flash([string]$dir) {
    Say (T "Backing up the whole flash to $dir" "Снимаю копию всего флеша в $dir")
    $info = (Invoke-Ssh ('cat /proc/mtd; echo; cat /tmp/sysinfo/board_name; uname -a; ' +
        'for m in /sys/class/mtd/mtd[0-9]*; do [ -e $m/name ] && echo "$(basename $m) $(cat $m/name) bad_blocks=$(cat $m/bad_blocks 2>/dev/null) ecc_failures=$(cat $m/ecc_failures 2>/dev/null)"; done; ' +
        '[ -e /sys/class/ubi/ubi0 ] && echo XR_UBI_ATTACHED; dmesg | grep -i -E "spi-nand|nand|mtd|ubi" | head -50')).Out
    Set-Content -LiteralPath (Join-Path $dir 'router-info.txt') -Value $info -Encoding UTF8
    if ($info -notmatch 'gemtek,xr1710g') { Fail ((T 'the initramfs reports a wrong board_name:' 'initramfs сообщает не тот board_name:') + "`n$info") }
    if ($info -match 'XR_UBI_ATTACHED') {
        # The OpenWrt kernel attaches the "ubi" partition by itself when it starts with UBI# -
        # on stock it holds a tclinux bank, so the router has been flashed before.
        Warn (T 'the ubi area already holds UBI and the kernel attached it - the router was flashed before, this is NOT a stock backup' 'в области ubi уже есть UBI и ядро его подключило - роутер прошивался раньше, это копия НЕ стока')
        Dismount-Ubi
    }
    Test-MtdLayout $info
    foreach ($l in $info -split "`n") {
        if ($l -match '^(mtd\d) (\S+) bad_blocks=(\d+)' -and [int]$Matches[3] -gt 0) {
            Warn (T "$($Matches[1]) ($($Matches[2])): $($Matches[3]) bad blocks" "$($Matches[1]) ($($Matches[2])): плохих блоков $($Matches[3])")
        }
    }
    $sums = @()
    foreach ($p in $Layout) {
        $file = Join-Path $dir ('{0}-{1}.bin' -f $p.Mtd, $p.Name)
        Info ((T '{0} {1} ({2} MiB)...' '{0} {1} ({2} МиБ)...') -f $p.Mtd, $p.Name, [math]::Round($p.Size / 1MB, 1))
        Invoke-Ssh "cat /dev/$($p.Mtd)" 1800 -OutFile $file | Out-Null
        $len = (Get-Item -LiteralPath $file).Length
        if ($len -ne $p.Size) { Fail (T "$($p.Name): got $len bytes instead of $($p.Size)" "$($p.Name): получено $len байт вместо $($p.Size)") }
        $remote = (Invoke-Ssh "sha256sum /dev/$($p.Mtd)" 600).Out.Split(' ')[0].Trim()
        $local = Get-Sha256 $file
        if ($remote -ne $local) { Fail (T "$($p.Name): sha256 of the copy ($local) does not match the flash ($remote)" "$($p.Name): sha256 копии ($local) не совпадает с флешем ($remote)") }
        $sums += "$local  $(Split-Path $file -Leaf)"
        Info "  ok, sha256 $local"
    }
    Set-Content -LiteralPath (Join-Path $dir 'SHA256SUMS') -Value $sums -Encoding ASCII
    $head = [byte[]]::new(4)
    $fs = [IO.File]::OpenRead((Join-Path $dir 'mtd2-ubi.bin'))
    try { $fs.Read($head, 0, 4) | Out-Null } finally { $fs.Close() }
    if ([Text.Encoding]::ASCII.GetString($head) -eq 'UBI#') {
        Warn (T 'the ubi area already holds UBI - the router was flashed before, this is NOT a stock backup. Keep an earlier backup if you have one.' 'в области ubi уже лежит UBI - роутер прошивался раньше, это копия НЕ стока. Сохраните более раннюю копию, если она есть.')
    }
}

# The factory volume: Wi-Fi EEPROM and DSD data from the vendor partition - the same as
# files/installer/install.sh in hurrian/w1700k-ubi-installer, only on the PC.
function New-Factory([string]$vendorFile, [string]$outFile, [int]$eraseSize = 0x20000) {
    $v = [IO.File]::ReadAllBytes($vendorFile)
    $l1 = [Text.Encoding]::GetEncoding(28591)
    $dsd = $l1.GetString($v, 0x400000, 0x1000)
    $strings = [regex]::Matches($dsd, '[\x20-\x7e\t]{4,}') | ForEach-Object { $_.Value }
    function Get-Dsd([string]$key) {
        foreach ($s in $strings) { if ($s.StartsWith("$key=")) { return $s.Substring($key.Length + 1) } }
        return $null
    }
    $wan = Get-Dsd 'wan_mac'; $lan = Get-Dsd 'lan_mac'; $fan = Get-Dsd 'fan_id'; $serial = Get-Dsd 'serial_number'
    foreach ($k in @(@('wan_mac', $wan), @('lan_mac', $lan), @('fan_id', $fan), @('serial_number', $serial))) {
        if (-not $k[1]) { Fail (T "DSD (vendor+0x400000) has no $($k[0])" "в DSD (vendor+0x400000) нет $($k[0])") }
    }
    foreach ($mac in @($wan, $lan)) {
        if ($mac -notmatch '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$') { Fail (T "bad MAC in DSD: $mac" "неверный MAC в DSD: $mac") }
    }
    if (-not $serial.StartsWith('XR1710G')) {
        Fail (T "serial number '$serial' is not an XR1710G (this script does not flash the W1700K/W1701K)" "серийный номер '$serial' - это не XR1710G (W1700K/W1701K этот скрипт не прошивает)")
    }
    $eeprom = -1
    for ($i = 0; $i -lt 4; $i++) {
        $o = 0x405000 + $i * $eraseSize
        if ($v[$o] -eq 0x90 -and $v[$o + 1] -eq 0x79) { $eeprom = $o; break }
    }
    if ($eeprom -lt 0) { Fail (T 'Wi-Fi EEPROM (magic 0x7990, bytes 90 79) not found in vendor from 0x405000' 'EEPROM Wi-Fi (магия 0x7990, байты 90 79) не найдена в vendor с 0x405000') }
    $blob = New-Object byte[] 0x10000
    [Array]::Copy($v, $eeprom, $blob, 0, 0x1e00)
    $put = {
        param([int]$off, [byte[]]$b)
        [Array]::Copy($b, 0, $blob, $off, $b.Length)
    }
    $macBytes = { param($m) [byte[]]($m.Split(':') | ForEach-Object { [Convert]::ToByte($_, 16) }) }
    & $put 0x5000 (& $macBytes $wan)
    & $put 0x6000 (& $macBytes $lan)
    & $put 0x7000 ([Text.Encoding]::ASCII.GetBytes($fan))
    & $put 0x8000 ([Text.Encoding]::ASCII.GetBytes($serial))
    [IO.File]::WriteAllBytes($outFile, $blob)
    Info (T "serial number $serial, WAN $wan, LAN $lan, fan_id $fan" "серийный номер $serial, WAN $wan, LAN $lan, fan_id $fan")
    Info ((T 'EEPROM found at {0}, factory volume built ({1})' 'EEPROM найдена по {0}, том factory собран ({1})') -f (Format-Hex $eeprom), (Split-Path $outFile -Leaf))
}

# ---------------------------------------------------------------------------
# UBI 2.0 and loader install
# ---------------------------------------------------------------------------
function Install-Ubi([string]$dir, [string]$sysupgrade) {
    Say (T 'Uploading files to the router (RAM)' 'Загрузка файлов на роутер (в ОЗУ)')
    Invoke-Ssh 'rm -rf /tmp/xr && mkdir -p /tmp/xr' | Out-Null
    $up = [ordered]@{
        'install-ubi.sh' = (Join-Path $Root 'router\install-ubi.sh')
        'factory.bin'    = (Join-Path $dir 'factory.bin')
        'recovery.itb'   = (Join-Path $FwDir $Files.Recovery)
        'sysupgrade.itb' = $sysupgrade
    }
    foreach ($k in $up.Keys) {
        Invoke-Ssh "cat > /tmp/xr/$k" 300 -In $up[$k] | Out-Null
        $remote = (Invoke-Ssh "sha256sum /tmp/xr/$k").Out.Split(' ')[0].Trim()
        if ($remote -ne (Get-Sha256 $up[$k])) { Fail (T "$k was damaged in transfer" "$k повредился при передаче") }
        Info "$k ok"
    }
    Say (T 'UBI 2.0 layout and OpenWrt install (irreversible flash write)' 'Разметка UBI 2.0 и установка OpenWrt (необратимая запись во флеш)')
    $r = Invoke-Ssh 'sh /tmp/xr/install-ubi.sh /tmp/xr/factory.bin /tmp/xr/recovery.itb /tmp/xr/sysupgrade.itb 2>&1' 900 -Echo -NoFail
    if ($r.ExitCode -ne 0 -or $r.Out -notmatch 'XR_INSTALL_OK') { Fail (T 'the UBI install did not finish (output above)' 'установка UBI не завершилась (вывод выше)') }
    Info (T 'UBI 2.0 laid out, OpenWrt and the factory volume written and read back' 'UBI 2.0 размечен, OpenWrt и том factory записаны и прочитаны обратно')
}

function Restart-ToStock {
    # Reboot over the console, not ssh: ssh notices the dropped connection seconds
    # later, and the stock loader waits for a key for under a second. Returns the
    # output position before the reboot, from which Enter-StockUboot looks for the banner.
    Invoke-Ssh 'sync' 60 -NoFail | Out-Null
    $m = $script:C.Mark()
    $script:C.Send("`rsync; reboot`r")
    return $m
}

# Write the chainloader slot with stock U-Boot commands and read it back.
function Write-Slot([string]$path, [string]$what) {
    Say (T "Writing $what to the chainloader slot (0x600000, 1 MiB)" "Запись $what в слот chainloader (0x600000, 1 МиБ)")
    Invoke-Uboot "setenv ipaddr $UbootIp" | Out-Null
    Invoke-Uboot "setenv serverip $PcIp" | Out-Null
    Invoke-Uboot 'mw.b 0x89000000 0xff 0x100000' -NoFail | Out-Null
    $size = Invoke-TftpLoad $path '0x89000000'
    if ($size -gt 0x100000) { Fail (T "$path is larger than 1 MiB" "$path больше 1 МиБ") }
    $hex = Format-Hex $size
    for ($try = 1; $try -le 2; $try++) {
        $o = Invoke-Uboot 'flash erase 0x600000 0x100000' 120
        if ($o -match '(?i)fail|error|bad') { Warn "flash erase: $($o.Trim())" }
        $o = Invoke-Uboot 'flash write 0x600000 0x100000 0x89000000' 120
        if ($o -match '(?i)fail|error') { Warn "flash write: $($o.Trim())" }
        Invoke-Uboot 'mw.b 0x8a000000 0x00 0x100000' -NoFail | Out-Null
        Invoke-Uboot 'flash read 0x600000 0x100000 0x8a000000' 120 | Out-Null
        $o = Invoke-Uboot "cmp.b 0x89000000 0x8a000000 $hex" 60 -NoFail
        if ($o -match 'Total of (\d+) byte') {
            if ([int64]$Matches[1] -eq $size) { Info (T "slot read back, $size bytes match" "слот прочитан обратно, $size байт совпадают"); return }
            Warn (T "only $($Matches[1]) of $size bytes match after the write" "после записи совпало только $($Matches[1]) из $size байт")
            continue
        }
        # no cmp in the stock loader - compare the signatures
        $o = Invoke-Uboot 'md.b 0x8a000000 0x4' -NoFail
        if ($o -match '8a000000:\s*([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2})') {
            $got = ($Matches[1..4] -join ' ')
            $want = (([IO.File]::ReadAllBytes($path))[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
            if ($got -eq $want) { Warn (T "the stock U-Boot has no cmp, only the signature was checked ($got)" "в стоковом U-Boot нет cmp, проверена только сигнатура ($got)"); return }
            Warn (T "slot signature $got, expected $want" "сигнатура слота $got, ожидалась $want")
            continue
        }
        Fail (T 'could not verify the written slot' 'не удалось проверить записанный слот')
    }
    Fail (T 'the chainloader slot was not written - nothing saved in the stock U-Boot, you can retry' 'слот chainloader не записался - в стоковом U-Boot ничего не сохранено, можно повторить')
}

function Set-Bootcmd([string]$kind) {
    $cur = Get-UbootVar 'bootcmd'
    $la = Get-UbootVar 'loadaddr'
    Info (T "now bootcmd='$cur' loadaddr='$la'" "сейчас bootcmd='$cur' loadaddr='$la'")
    $changed = $false
    if ($kind -eq 'openwrt') {
        if ($cur -cne $OpenWrtBootcmd) { Set-UbootVar 'bootcmd' $OpenWrtBootcmd; $changed = $true }
    } else {
        if ($HttpBootcmds -cnotcontains $cur) { Set-UbootVar 'bootcmd' $StockBootcmd; $changed = $true }
        if ($la -ne '0x81800000') { Invoke-Uboot 'setenv loadaddr 0x81800000' | Out-Null; $changed = $true }
    }
    if ($changed) {
        $o = Invoke-Uboot 'saveenv' 60
        if ($o -match '(?i)fail|error') { Fail "saveenv: $($o.Trim())" }
        Info (T "bootcmd='$(Get-UbootVar 'bootcmd')' saved" "bootcmd='$(Get-UbootVar 'bootcmd')' сохранён")
    } else {
        Info (T 'the stock U-Boot environment needs no change' 'окружение стокового U-Boot менять не нужно')
    }
}

# Slot, bootcmd and the first OpenWrt boot - from an already stopped stock U-Boot.
function Complete-Loader([string]$kind) {
    if ($kind -eq 'http') {
        Write-Slot (Join-Path $FwDir $Files.HttpUboot) 'http-uboot (xr1710g-chainloader-slot.bin)'
    } else {
        Write-Slot (Join-Path $FwDir $Files.OpenWrtUboot) 'U-Boot OpenWrt (chainload-uboot.itb)'
    }
    Set-Bootcmd $kind
    Wait-OpenWrt
    Say (T 'Done.' 'Готово.')
    Info (T "OpenWrt: http://$RouterIp (root has no password - set one)" "OpenWrt: http://$RouterIp (root без пароля - задайте пароль)")
    if ($kind -eq 'http') {
        Info (T 'Recovery: cable in the 10GbE port, hold reset at power-on -> http://192.168.255.1' 'Рекавери: кабель в порт 10GbE, держать reset при включении -> http://192.168.255.1')
    } else {
        Info (T 'Recovery: U-Boot menu on the UART (TFTP / recovery from flash)' 'Рекавери: меню U-Boot в UART (TFTP / recovery из флеша)')
    }
}

function Wait-OpenWrt {
    Say (T 'Rebooting into OpenWrt' 'Перезагрузка в OpenWrt')
    $m = $script:C.Mark()
    $script:C.Send("reset`r")
    if ($script:C.WaitFor('Please press Enter to activate this console', $m, (Scale 300)) -lt 0) {
        Fail (T 'OpenWrt did not boot within 5 minutes - see serial.log' 'OpenWrt не загрузился за 5 минут - смотрите serial.log')
    }
    Start-Sleep -Seconds 3
    $m = $script:C.Mark()
    $script:C.Send("`r")
    $script:C.WaitFor('root@[^\r\n]*# ?$', $m, 10000) | Out-Null
    $m = $script:C.Mark()
    $script:C.Send("echo XR_`"`"BOARD=`$(cat /tmp/sysinfo/board_name)`r")
    if ($script:C.WaitFor('XR_BOARD=(\S+)', $m, 10000) -lt 0) { Fail (T 'OpenWrt booted, but the shell does not answer' 'OpenWrt загрузился, но shell не отвечает') }
    $board = $script:C.LastMatch.Groups[1].Value
    Info (T "OpenWrt booted from flash, board_name=$board" "OpenWrt загрузился с флеша, board_name=$board")
}

# ---------------------------------------------------------------------------
# Loader choice
# ---------------------------------------------------------------------------
function Select-Loader {
    if ($Loader) { return $Loader }
    if ($script:Lang -eq 'ru') {
        Write-Host @'

Какой загрузчик поставить в слот chainloader?

  [1] http-uboot (YYH2913/http-uboot, релиз xr1710g_260805) - рекомендуется
      + веб-рекавери http://192.168.255.1 со своим DHCP: прошивка OpenWrt и
        самого загрузчика из браузера, без UART (кнопка reset при включении)
      + 10GbE в загрузчике; полное пересоздание UBI с выбором разметки 2.0/1.5/1.0
        и восстановлением factory из DSD
      + работает со стоковым bootcmd, окружение AXON не меняется
      - сторонняя сборка (U-Boot 2026.07), исходники у автора

  [2] U-Boot OpenWrt (uboot-airoha, an7581_gemtek_xr1710g) - "ванильный"
      + та же сборка, что у Gemtek W1700K в OpenWrt; меню загрузки в UART:
        TFTP, recovery из флеша, установщик по TFTP
      - любое восстановление - только через UART и TFTP
      - нужен bootcmd 'flash read 0x600000 0x100000 $loadaddr; bootm' в AXON
        (скрипт поставит сам)

'@
    } else {
        Write-Host @'

Which loader goes into the chainloader slot?

  [1] http-uboot (YYH2913/http-uboot, release xr1710g_260805) - recommended
      + web recovery at http://192.168.255.1 with its own DHCP: flash OpenWrt
        and the loader itself from a browser, no UART (reset button at power-on)
      + 10GbE in the loader; full UBI rebuild with a choice of 2.0/1.5/1.0
        layout and factory restored from DSD
      + works with the stock bootcmd, the AXON environment is not changed
      - third-party build (U-Boot 2026.07), sources with the author

  [2] OpenWrt U-Boot (uboot-airoha, an7581_gemtek_xr1710g) - "vanilla"
      + the same build as the Gemtek W1700K in OpenWrt; boot menu on the UART:
        TFTP, recovery from flash, TFTP installer
      - any recovery needs the UART and TFTP
      - needs bootcmd 'flash read 0x600000 0x100000 $loadaddr; bootm' in AXON
        (the script sets it)

'@
    }
    $a = Read-Host (T 'Choice [1/2]' 'Выбор [1/2]')
    switch ($a) {
        '1' { return 'http' }
        '2' { return 'openwrt' }
        default { Fail (T 'enter 1 or 2' 'нужно 1 или 2') }
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Lang) {
    if ($Yes) { $Lang = 'en' }
    else {
        Write-Host ''
        Write-Host '  [1] English'
        Write-Host '  [2] Русский'
        $Lang = if ((Read-Host 'Language / Язык [1]') -eq '2') { 'ru' } else { 'en' }
    }
    $PSBoundParameters['Lang'] = $Lang
}
$script:Lang = $Lang

if (-not $SkipNetworkSetup -and -not (Test-Admin)) {
    Write-Host (T 'Administrator rights are needed (adapter address and a firewall rule for TFTP). Restarting...' 'Нужны права администратора (адрес на адаптере и правило брандмауэра для TFTP). Перезапуск...') -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', (ConvertTo-Arg $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += (ConvertTo-Arg ([string]$v)) }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList ($argList -join ' ')
    exit
}

if (-not $BackupDir) {
    if ($Mode -eq 'Restore') { Fail (T 'Restore needs -BackupDir with an earlier backup' 'для Restore укажите -BackupDir с ранее снятой копией') }
    $BackupDir = Join-Path $Root ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if ($Mode -ne 'Restore') {
    if ((Test-Path $BackupDir) -and @(Get-ChildItem -LiteralPath $BackupDir -Filter 'mtd*.bin').Count -gt 0) {
        Fail (T "$BackupDir already holds a backup - choose another folder so it is not overwritten" "в $BackupDir уже есть копия - укажите другую папку, чтобы её не затереть")
    }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
}
$BackupDir = (Resolve-Path -LiteralPath $BackupDir).Path
$Session = Join-Path $BackupDir 'session'
New-Item -ItemType Directory -Force -Path $Session | Out-Null
$script:LogFile = Join-Path $BackupDir 'flash.log'

$sysupgrade = Join-Path $FwDir $Files.Sysupgrade
try {
    Say (T "XR1710G: mode $Mode, folder $BackupDir" "XR1710G: режим $Mode, папка $BackupDir")
    Test-Bundle
    $kind = ''
    if ($Mode -eq 'Install') {
        if ($Firmware) { $sysupgrade = (Resolve-Path -LiteralPath $Firmware).Path }
        Test-Sysupgrade $sysupgrade
        Info (T "firmware: $sysupgrade" "прошивка: $sysupgrade")
        $kind = Select-Loader
        Info (T "loader: $kind" "загрузчик: $kind")
    }
    if ($Mode -eq 'Loader') {
        $kind = Select-Loader
        Info (T "loader: $kind" "загрузчик: $kind")
        Confirm-Step (T @"
The loader '$kind' will be written to the chainloader slot (0x600000) and the stock
U-Boot bootcmd set for it. The ubi area is not touched: OpenWrt with the UBI 2.0
layout must already be installed (Install got as far as writing the loader).
"@ @"
В слот chainloader (0x600000) запишется загрузчик '$kind', bootcmd стокового U-Boot
будет настроен под него. Область ubi не трогается: OpenWrt в разметке UBI 2.0 уже
должен быть установлен (режим Install дошёл до записи загрузчика).
"@)
    }
    if ($Mode -eq 'Restore') {
        foreach ($f in @('mtd1-chainloader.bin', 'mtd2-ubi.bin', 'stock-uboot-env.txt', 'SHA256SUMS')) {
            if (-not (Test-Path (Join-Path $BackupDir $f))) { Fail (T "$BackupDir has no $f" "в $BackupDir нет $f") }
        }
        foreach ($l in Get-Content -LiteralPath (Join-Path $BackupDir 'SHA256SUMS')) {
            if ($l -match '^([0-9a-f]{64})\s+(\S+)$' -and (Get-Sha256 (Join-Path $BackupDir $Matches[2])) -ne $Matches[1]) {
                Fail (T "backup damaged: $($Matches[2])" "копия повреждена: $($Matches[2])")
            }
        }
        $stockEnv = Get-Content -LiteralPath (Join-Path $BackupDir 'stock-uboot-env.txt')
        $script:RestoreBootcmd = ($stockEnv | Where-Object { $_ -like 'bootcmd=*' } | Select-Object -First 1)
        if (-not $script:RestoreBootcmd) { Fail (T 'stock-uboot-env.txt has no bootcmd' 'в stock-uboot-env.txt нет bootcmd') }
        $script:RestoreBootcmd = $script:RestoreBootcmd.Substring(8)
        Info (T "bootcmd will be restored to '$($script:RestoreBootcmd)'" "будет восстановлен bootcmd='$($script:RestoreBootcmd)'")
        Confirm-Step (T 'The stock firmware will be written back over OpenWrt.' 'Сток будет записан обратно поверх OpenWrt.')
    }

    if (-not $SkipNetworkSetup) { Initialize-Network }
    Initialize-Ssh $Session
    $script:Tftp = New-Object XrTftp $TftpPort

    if ($SerialTcp) {
        $h, $p = $SerialTcp.Split(':')
        $script:C = New-Object XrConsole $h, ([int]$p), (Join-Path $BackupDir 'serial.log')
    } else {
        $port = Select-ComPort
        $script:C = New-Object XrConsole $port, (Join-Path $BackupDir 'serial.log')
    }

    Write-Host (T @"

Wiring:
  * USB-UART 3.3 V to the header by the screw: TX, GND, VCC (do not connect), N/C, RX
    (router TX -> adapter RX, router RX -> adapter TX)
  * Ethernet cable from the PC to a gigabit LAN port of the router
  * PC address $PcIp/24

"@ @"

Подключение:
  * USB-UART 3.3 В к разъёму у винта: TX, GND, VCC (не подключать), N/C, RX
    (TX роутера -> RX адаптера, RX роутера -> TX адаптера)
  * кабель Ethernet от ПК в гигабитный LAN-порт роутера
  * адрес ПК $PcIp/24

"@) -ForegroundColor Green
    Enter-StockUboot (T 'Power the router on (if it is on, power it off and on)' 'Включите питание роутера (если включён - выключите и включите)')
    $envText = Invoke-Uboot 'printenv' 30
    if ($Mode -in 'Install', 'Backup') {
        Set-Content -LiteralPath (Join-Path $BackupDir 'stock-uboot-env.txt') -Encoding UTF8 `
            -Value (($envText -replace "`r", '') -split "`n" | Where-Object { $_ -match '^[A-Za-z0-9_.]+=' })
    }
    if ($envText -notmatch 'AXON|ecnt') { Warn (T 'no AXON/ecnt in the environment - is this really the stock XR1710G loader?' 'в окружении нет AXON/ecnt - точно ли это стоковый загрузчик XR1710G?') }
    if ($Mode -eq 'Loader') {
        Complete-Loader $kind
        return
    }
    Enter-RamLinux

    if ($Mode -eq 'Restore') {
        Test-MtdLayout (Invoke-Ssh 'cat /proc/mtd').Out
        Dismount-Ubi
        Say (T 'Writing the ubi area from the backup (mtd write)' 'Запись области ubi из копии (mtd write)')
        $r = Invoke-Ssh 'mtd write - ubi 2>&1' 3600 -In (Join-Path $BackupDir 'mtd2-ubi.bin') -Echo -NoFail
        if ($r.ExitCode -ne 0) { Fail (T 'mtd write failed' 'mtd write завершился с ошибкой') }
        $want = Get-Sha256 (Join-Path $BackupDir 'mtd2-ubi.bin')
        $got = (Invoke-Ssh 'sha256sum /dev/mtd2' 600).Out.Split(' ')[0].Trim()
        if ($got -ne $want) { Warn (T 'reading ubi back does not match the backup byte for byte (happens with new bad blocks)' 'чтение ubi не совпало с копией побайтно (так бывает при новых плохих блоках)') }
        else { Info (T 'the ubi area matches the backup' 'область ubi совпадает с копией') }
        $m = Restart-ToStock
        Enter-StockUboot (T 'Rebooting into the stock U-Boot' 'Перезагрузка в стоковый U-Boot') $m
        Write-Slot (Join-Path $BackupDir 'mtd1-chainloader.bin') (T 'the stock start of tclinux' 'стоковое начало tclinux')
        if ((Get-UbootVar 'bootcmd') -cne $script:RestoreBootcmd) {
            Set-UbootVar 'bootcmd' $script:RestoreBootcmd
            Invoke-Uboot 'saveenv' 60 | Out-Null
        }
        Say (T 'Done: the stock firmware is back. The router is rebooting into it.' 'Готово: сток записан обратно. Роутер перезагружается в стоковую прошивку.')
        $script:C.Send("reset`r")
        Start-Sleep -Seconds 5
        return
    }

    Save-Flash $BackupDir
    New-Factory (Join-Path $BackupDir 'mtd0-vendor.bin') (Join-Path $BackupDir 'factory.bin')
    Say (T "Stock backup saved: $BackupDir" "Копия стока сохранена: $BackupDir")
    Info (T 'keep this folder safe - it is the only way back to the stock firmware' 'сохраните эту папку отдельно - это единственный способ вернуть сток')

    if ($Mode -eq 'Backup') {
        Restart-ToStock | Out-Null
        Say (T 'Done (backup only). The router is rebooting into the stock firmware, nothing was written to flash.' 'Готово (только копия). Роутер перезагружается в стоковую прошивку, во флеш ничего не писалось.')
        Start-Sleep -Seconds 3
        return
    }

    Confirm-Step (T @"
The flash will now be repartitioned: the stock firmware in the ubi area
(0x700000-0x1be00000) will be erased, the loader '$kind' goes into the chainloader slot.
The vendor loader (0x0-0x600000) and the BMT reserve at the end of flash are not touched.
"@ @"
Дальше флеш будет переразмечен: стоковая прошивка в области ubi (0x700000-0x1be00000)
будет стёрта, в слот chainloader запишется загрузчик '$kind'.
Вендорский загрузчик (0x0-0x600000) и резерв BMT в конце флеша не трогаются.
"@)
    Install-Ubi $BackupDir $sysupgrade
    $m = Restart-ToStock
    Enter-StockUboot (T 'Rebooting into the stock U-Boot to write the loader' 'Перезагрузка в стоковый U-Boot для записи загрузчика') $m
    Complete-Loader $kind
    Info (T "Stock backup: $BackupDir" "Копия стока: $BackupDir")
}
catch {
    Write-Host ''
    Write-Host "$(T 'ERROR' 'ОШИБКА'): $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-Host (T "Logs: $BackupDir\flash.log and serial.log" "Журналы: $BackupDir\flash.log и serial.log") -ForegroundColor Red
    exit 1
}
finally {
    if ($script:C) { $script:C.Dispose() }
    if ($script:Tftp) { $script:Tftp.Dispose() }
    Restore-Network
}
