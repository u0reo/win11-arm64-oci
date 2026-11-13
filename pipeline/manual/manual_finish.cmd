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

echo [1/6] Assigning the ESP to S:
(
echo select disk 0
echo select partition 1
echo assign letter=S
echo exit
) > %TEMP%\assign_esp.txt
diskpart /s %TEMP%\assign_esp.txt
if not exist S:\NUL goto noesp
echo.

echo [2/6] Adding virtio drivers to the offline image
dism /image:%WIN%\ /add-driver:"%OEM%\drivers" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers returned an error (continuing)
if exist "%OEM%\drivers-extra" dism /image:%WIN%\ /add-driver:"%OEM%\drivers-extra" /recurse
if errorlevel 1 echo WARN: dism /add-driver drivers-extra returned an error (continuing)
echo.

echo [3/6] Copying unattend, OEM scripts and drivers
if not exist %WIN%\Windows\Panther mkdir %WIN%\Windows\Panther
copy /y "%OEM%\autounattend.xml" %WIN%\Windows\Panther\unattend.xml
xcopy /e /i /y "%OEM%\oem" %WIN%\OEM
xcopy /e /i /y "%OEM%\drivers" %WIN%\drivers
if exist "%OEM%\drivers-extra" xcopy /e /i /y "%OEM%\drivers-extra" %WIN%\drivers-extra
echo.

echo [4/6] Creating the EFI boot files on S:
bcdboot %WIN%\Windows /s S: /f UEFI
if errorlevel 1 goto fail
echo.

rem ------------------------------------------------------------------
rem Optional: chainload the recovery Ubuntu from the Windows boot menu.
rem bcdboot above replaced \EFI\BOOT\BOOTAA64.EFI with the Windows boot
rem manager, so the firmware still starts Windows.  The Ubuntu entry is
rem only added when GRUB is actually on the ESP.
rem ------------------------------------------------------------------
echo [5/6] Adding the Ubuntu recovery entry to the BCD
if not exist S:\EFI\ubuntu\grubaa64.efi goto noubuntu
set BCD=S:\EFI\Microsoft\Boot\BCD
set GUB=
for /f "tokens=3" %%a in ('bcdedit /store %BCD% /create /d "Ubuntu (recovery)" /application bootapp') do set GUB=%%a
if "%GUB%"=="" goto bcdwarn
bcdedit /store %BCD% /set %GUB% device partition=S:
if errorlevel 1 goto bcdwarn
bcdedit /store %BCD% /set %GUB% path \EFI\ubuntu\grubaa64.efi
if errorlevel 1 goto bcdwarn
bcdedit /store %BCD% /displayorder %GUB% /addlast
bcdedit /store %BCD% /timeout 5
bcdedit /store %BCD% /set {bootmgr} displaybootmenu Yes
echo   entry %GUB% added
bcdedit /store %BCD% /enum %GUB%
goto bcddone

:noubuntu
echo   no \EFI\ubuntu\grubaa64.efi on the ESP; skipping
goto bcddone

:bcdwarn
echo WARN: could not add the Ubuntu entry; Windows still boots.
echo       Add it later with bcdedit (see docs/DUALBOOT.md).

:bcddone
echo.

echo [6/6] Done.  Shutting down in 10 seconds...
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
