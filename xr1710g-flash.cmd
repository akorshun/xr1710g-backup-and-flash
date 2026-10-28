@echo off
rem XR1710G: backup of the stock firmware and OpenWrt install (UBI 2.0).
rem Arguments are passed through, e.g.:  xr1710g-flash.cmd -Mode Backup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xr1710g-flash.ps1" %*
pause
