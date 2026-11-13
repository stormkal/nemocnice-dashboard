@echo off
rem Spusti ping monitor skryte na pozadi (ping.js se zapisuje vedle dashboardu)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ping-monitor.ps1"
