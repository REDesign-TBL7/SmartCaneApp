@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_ota_bin_windows.ps1" %*
endlocal
