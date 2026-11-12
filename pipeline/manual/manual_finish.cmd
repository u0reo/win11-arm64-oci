@echo off
setlocal
set OEM=%~d0
set WIN=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\System32\ntoskrnl.exe set WIN=%%d:
if "%WIN%"=="" goto nowin

echo ============================================================
echo Manual finish: drivers + boot files
echo   OEMDRV  = %OEM%
echo   WINDOWS = %WIN%
echo ============================================================
echo.

echo [1/5] Assigning the ESP to S:
(
echo select disk 0
echo select partition 1
echo assign letter=S
echo exit
) > %TEMP%\assign_esp.txt
diskpart /s %TEMP%\assign_esp.txt
if not exist S:\NUL goto noesp
echo.

echo [2/5] Adding virtio drivers to the offline image
dism /image:%WIN%\ /add-driver:"%OEM%\drivers" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers returned an error (continuing)
if exist "%OEM%\drivers-extra" dism /image:%WIN%\ /add-driver:"%OEM%\drivers-extra" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers-extra returned an error (continuing)
echo.

echo [3/5] Copying unattend, OEM scripts and drivers
if not exist %WIN%\Windows\Panther mkdir %WIN%\Windows\Panther
copy /y "%OEM%\autounattend.xml" %WIN%\Windows\Panther\unattend.xml
xcopy /e /i /y "%OEM%\oem" %WIN%\OEM
xcopy /e /i /y "%OEM%\drivers" %WIN%\drivers
if exist "%OEM%\drivers-extra" xcopy /e /i /y "%OEM%\drivers-extra" %WIN%\drivers-extra
echo.

echo [4/5] Creating the EFI boot files on S:
bcdboot %WIN%\Windows /s S: /f UEFI
if errorlevel 1 goto fail
echo.

echo [5/5] Done.  Shutting down in 10 seconds...
ping -n 11 127.0.0.1 >nul
wpeutil shutdown
goto :eof

:noesp
echo ERROR: the ESP was not assigned to S:.
goto fail

:nowin
echo ERROR: no existing Windows installation was found.
goto fail

:fail
echo.
echo *** MANUAL FINISH FAILED ***
pause
