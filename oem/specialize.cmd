@echo off
rem Runs in the specialize pass as SYSTEM.
set LOG=C:\OEM\specialize.log
if not exist C:\OEM mkdir C:\OEM
copy /y "%~dp0*" C:\OEM\ >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\specialize.ps1 >> "%LOG%" 2>&1
exit /b 0
