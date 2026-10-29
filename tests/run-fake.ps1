# End-to-end run of xr1710g-flash.ps1 against tests/fake_router.py and
# tests/fake_ssh.py: Backup, Install with each loader, then Restore.
# Needs python 3.9+ and ssh-keygen.exe (Windows OpenSSH client) in PATH.
param([string]$Work = (Join-Path ([IO.Path]::GetTempPath()) 'xr1710g-fake'))

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
$Py = (Get-Command python).Source
$script:Failed = 0

function Start-Router([string]$state, [int]$port, [switch]$Init) {
    $a = @("`"$PSScriptRoot\fake_router.py`"", "`"$state`"", $port, 6969)
    if ($Init) { $a += '--init' }
    $p = Start-Process $Py -ArgumentList $a -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
    return $p
}

function Invoke-Flash([string]$name, [string]$state, [int]$port, [string[]]$extra) {
    Write-Host "`n######## $name" -ForegroundColor Magenta
    $env:XR_FAKE_STATE = $state
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$Root\xr1710g-flash.ps1",
        '-SerialTcp', "127.0.0.1:$port", '-SshExe', $Py, '-SshPrefix', "$PSScriptRoot\fake_ssh.py",
        '-TftpPort', '6969', '-SkipNetworkSetup', '-Yes') + $extra
    & powershell.exe @a | Out-Host
    return $LASTEXITCODE
}

function Check([string]$what, [bool]$ok) {
    if ($ok) { Write-Host "PASS $what" -ForegroundColor Green }
    else { Write-Host "FAIL $what" -ForegroundColor Red; $script:Failed++ }
}

function Get-Env([string]$state) { Get-Content "$state\env.json" -Raw | ConvertFrom-Json }

function Get-Head([string]$file, [int]$off, [int]$n) {
    $fs = [IO.File]::OpenRead($file)
    try { $b = New-Object byte[] $n; $fs.Seek($off, 'Begin') | Out-Null; $fs.Read($b, 0, $n) | Out-Null; return $b }
    finally { $fs.Close() }
}

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Work | Out-Null
$slot = [IO.File]::ReadAllBytes("$Root\firmware\xr1710g-chainloader-slot.bin")
$owrt = [IO.File]::ReadAllBytes("$Root\firmware\openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb")

# 1. Backup only, Russian messages: nothing in the flash may change
$s = "$Work\state-backup"
$r = Start-Router $s 7001 -Init
$before = (Get-FileHash "$s\mtd1.bin").Hash
$rc = Invoke-Flash 'backup' $s 7001 @('-Mode', 'Backup', '-Lang', 'ru', '-BackupDir', "$Work\bk1")
Check 'backup: exit code 0' ($rc -eq 0)
Check 'backup: four partition dumps' (@(Get-ChildItem "$Work\bk1\mtd*.bin").Count -eq 4)
Check 'backup: dumps equal the flash' ((Get-FileHash "$Work\bk1\mtd0-vendor.bin").Hash -eq (Get-FileHash "$s\mtd0.bin").Hash)
Check 'backup: stock env saved' ((Get-Content "$Work\bk1\stock-uboot-env.txt") -contains 'bootcmd=flash read 0x602100 0x4000000 $loadaddr; bootm')
Check 'backup: factory.bin built' ((Get-Item "$Work\bk1\factory.bin").Length -eq 0x10000)
Check 'backup: slot untouched' ((Get-FileHash "$s\mtd1.bin").Hash -eq $before)
Check 'backup: env untouched' ((Get-Env $s).bootcmd -eq 'flash read 0x602100 0x4000000 $loadaddr; bootm')
# "Kopiya stoka" (Stock backup) in Cyrillic, escaped: this file has no BOM and PowerShell 5.1 would misread it
Check 'backup: Russian messages' ((Get-Content "$Work\bk1\flash.log" -Raw -Encoding UTF8) -match '\u041a\u043e\u043f\u0438\u044f \u0441\u0442\u043e\u043a\u0430')
# the stock UBI (rootfs_data, config, log) is not taken for an earlier flash
$log = Get-Content "$Work\bk1\flash.log" -Raw -Encoding UTF8
Check 'backup: stock UBI recognised' ($log -match 'rootfs_data, config, log')
Check 'backup: no "flashed before" warning' ($log -notmatch '\u041d\u0415 \u0441\u0442\u043e\u043a\u0430')
Check 'backup: stock UBI detached before the dump' ($log -match 'ubidetach -m 2')
Stop-Process $r -ErrorAction SilentlyContinue

# 2. Install with http-uboot: stock bootcmd stays, slot = slot.bin
$s = "$Work\state-http"
$r = Start-Router $s 7002 -Init
$rc = Invoke-Flash 'install http' $s 7002 @('-Loader', 'http', '-BackupDir', "$Work\bk2")
Check 'http: exit code 0' ($rc -eq 0)
Check 'http: slot written' (@(Compare-Object (Get-Head "$s\mtd1.bin" 0 $slot.Length) $slot -SyncWindow 0).Count -eq 0)
Check 'http: bootcmd unchanged' ((Get-Env $s).bootcmd -eq 'flash read 0x602100 0x4000000 $loadaddr; bootm')
Check 'http: OpenWrt installed' (Test-Path "$s\installed")
Check 'http: English messages' ((Get-Content "$Work\bk2\flash.log" -Raw -Encoding UTF8) -match 'Stock backup saved')
Stop-Process $r -ErrorAction SilentlyContinue

# 3. Install with the OpenWrt chainloader: bootcmd switched to 0x600000
$s = "$Work\state-openwrt"
$r = Start-Router $s 7003 -Init
$rc = Invoke-Flash 'install openwrt' $s 7003 @('-Loader', 'openwrt', '-BackupDir', "$Work\bk3")
Check 'openwrt: exit code 0' ($rc -eq 0)
Check 'openwrt: slot written' (@(Compare-Object (Get-Head "$s\mtd1.bin" 0 $owrt.Length) $owrt -SyncWindow 0).Count -eq 0)
Check 'openwrt: bootcmd' ((Get-Env $s).bootcmd -eq 'flash read 0x600000 0x100000 $loadaddr; bootm')
Stop-Process $r -ErrorAction SilentlyContinue

# 3b. Backup of the router flashed in test 3: OpenWrt volumes mean "not stock"
$r = Start-Router $s 7007
$rc = Invoke-Flash 'backup flashed' $s 7007 @('-Mode', 'Backup', '-BackupDir', "$Work\bk7")
Check 'flashed: exit code 0' ($rc -eq 0)
Check 'flashed: "not stock" warning' ((Get-Content "$Work\bk7\flash.log" -Raw) -match 'OpenWrt UBI volumes \(ubootenv, ubootenv2, factory, recovery, fit\)')
Stop-Process $r -ErrorAction SilentlyContinue

# 4. Loader only: switch the router of test 2 from http-uboot to the OpenWrt loader
$s = "$Work\state-http"
$r = Start-Router $s 7006
$ubi = (Get-FileHash "$s\mtd2.bin").Hash
$rc = Invoke-Flash 'loader openwrt' $s 7006 @('-Mode', 'Loader', '-Loader', 'openwrt', '-BackupDir', "$Work\bk6")
Check 'loader: exit code 0' ($rc -eq 0)
Check 'loader: slot written' (@(Compare-Object (Get-Head "$s\mtd1.bin" 0 $owrt.Length) $owrt -SyncWindow 0).Count -eq 0)
Check 'loader: bootcmd' ((Get-Env $s).bootcmd -eq 'flash read 0x600000 0x100000 $loadaddr; bootm')
Check 'loader: ubi untouched' ((Get-FileHash "$s\mtd2.bin").Hash -eq $ubi)
Stop-Process $r -ErrorAction SilentlyContinue

# 5. Restore the stock from backup 3 onto the router of test 3
$r = Start-Router $s 7004
$rc = Invoke-Flash 'restore' $s 7004 @('-Mode', 'Restore', '-BackupDir', "$Work\bk3")
Check 'restore: exit code 0' ($rc -eq 0)
Check 'restore: attached UBI detached first' ((Get-Content "$Work\bk3\flash.log" -Raw) -match 'ubidetach -m 2')
Check 'restore: slot back to stock' ((Get-FileHash "$s\mtd1.bin").Hash -eq (Get-FileHash "$Work\bk3\mtd1-chainloader.bin").Hash)
Check 'restore: ubi back to stock' ((Get-FileHash "$s\mtd2.bin").Hash -eq (Get-FileHash "$Work\bk3\mtd2-ubi.bin").Hash)
Check 'restore: bootcmd back to stock' ((Get-Env $s).bootcmd -eq 'flash read 0x602100 0x4000000 $loadaddr; bootm')
Stop-Process $r -ErrorAction SilentlyContinue

# 6. A sysupgrade with the UBI 1.0 layout is refused before anything runs
$bad = "$Work\ubi10.itb"
$b = [IO.File]::ReadAllBytes("$Root\firmware\openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb")
$l1 = [Text.Encoding]::GetEncoding(28591)
$i = $l1.GetString($b).IndexOf($l1.GetString([byte[]](0, 0x70, 0, 0, 0x1b, 0x70, 0, 0)))
$b[$i + 4] = 0x1f
[IO.File]::WriteAllBytes($bad, $b)
$rc = Invoke-Flash 'ubi 1.0 image' "$Work\none" 7005 @('-Loader', 'http', '-Firmware', $bad, '-BackupDir', "$Work\bk5")
Check 'ubi 1.0 image refused' ($rc -ne 0)

Write-Host ''
if ($script:Failed) { Write-Host "$script:Failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green

exit 0
