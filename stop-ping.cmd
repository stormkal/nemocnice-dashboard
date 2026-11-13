@echo off
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ping-monitor.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo Ping monitor zastaven.
