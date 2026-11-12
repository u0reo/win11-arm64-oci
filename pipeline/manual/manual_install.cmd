@echo off
setlocal
set OEM=%~d0
set SRC=
set IMGFILE=
set INDEX=1
if exist "%OEM%\image-index.txt" set /p INDEX=<%OEM%\image-index.txt
if "%INDEX%"=="" set INDEX=1

for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\sources\install.wim set SRC=%%d
    if exist %%d:\sources\install.esd set SRC=%%d
)
if "%SRC%"=="" goto nosrc
if exist %SRC%:\sources\install.wim set IMGFILE=%SRC%:\sources\install.wim
if not defined IMGFILE if exist %SRC%:\sources\install.esd set IMGFILE=%SRC%:\sources\install.esd
if not defined IMGFILE goto nosrc

echo ============================================================
echo Manual Windows 11 ARM64 install
echo   OEMDRV = %OEM%
echo   SOURCE = %SRC%
echo   IMAGE  = %IMGFILE%
echo   INDEX  = %INDEX%
echo ============================================================
echo.

echo [1/7] Partitioning disk 0 (ESP 100M + MSR 16M + NTFS rest)
diskpart /s %OEM%\diskpart.txt
if errorlevel 1 goto fail
echo.

echo [2/7] Applying image index %INDEX% to W:
dism /apply-image /imagefile:"%IMGFILE%" /index:%INDEX% /applydir:W:\
if errorlevel 1 goto fail
echo.

echo [3/7] Adding virtio drivers to the offline image
if exist "%OEM%\drivers" dism /image:W:\ /add-driver:"%OEM%\drivers" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers returned an error (continuing)
if exist "%OEM%\drivers-extra" dism /image:W:\ /add-driver:"%OEM%\drivers-extra" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers-extra returned an error (continuing)
echo.

echo [4/7] Removing stale OEM/Panther state from the applied image
if exist W:\OEM rd /s /q W:\OEM
if exist W:\Windows\Panther\unattend.xml del /f /q W:\Windows\Panther\unattend.xml
echo.

echo [5/7] Copying unattend, OEM scripts and drivers to the target
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
copy /y %OEM%\autounattend.xml W:\Windows\Panther\unattend.xml
xcopy /e /i /y %OEM%\oem W:\OEM
xcopy /e /i /y %OEM%\drivers W:\drivers
if exist "%OEM%\drivers-extra" xcopy /e /i /y "%OEM%\drivers-extra" W:\drivers-extra
echo.

echo [6/7] Creating the EFI boot files on S:
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 goto fail
echo.

echo [7/7] Done.  Rebooting in 10 seconds...
ping -n 11 127.0.0.1 >nul
wpeutil reboot
goto :eof

:nosrc
echo ERROR: sources\install.wim or install.esd was not found on any drive.
goto fail

:fail
echo.
echo *** MANUAL INSTALL FAILED ***
echo Inspect the messages above, then retry or reboot.
pause
