@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo CIMQ001 DB Package Exporter v5
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export_CIMQ001_DB.ps1"

echo.
echo ============================================================
echo Finished.
echo ============================================================
pause
