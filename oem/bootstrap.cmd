@echo off
rem Detached launcher used by the OEM Bootstrap scheduled task.
rem cmd.exe exits immediately; PowerShell keeps running outside SCM timeouts.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\boot.ps1
exit /b 0
