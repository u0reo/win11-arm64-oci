@echo off
rem Runs at first logon of the configured user account.
set LOG=C:\OEM\firstlogon.log
if not exist C:\OEM mkdir C:\OEM
copy /y "%~dp0*" C:\OEM\ >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\firstlogon.ps1 >> "%LOG%" 2>&1
exit /b 0
