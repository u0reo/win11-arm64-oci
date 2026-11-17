@echo off
rem Runs in the specialize pass as SYSTEM.
set LOG=C:\OEM\specialize.log
if not exist C:\OEM mkdir C:\OEM
copy /y "%~dp0*" C:\OEM\ >nul 2>&1
rem Keep cmd.exe output separate: the PowerShell script appends to %LOG%
rem itself, and a second handle on that file makes both logs unreliable.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\specialize.ps1 >> "%LOG%.cmd" 2>&1
exit /b 0
