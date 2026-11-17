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
echo MANUAL_FINISH_BEGIN oem=%OEM% win=%WIN% > COM1
echo.

echo [1/6] Assigning the ESP to S:
rem host_apply.sh writes the ESP partition number to OEM\esp-part.txt on
rem the Windows volume.  Keep partition 1 as the fallback for fresh disks.
set ESPPART=1
if exist "%OEM%\esp-part.txt" set /p ESPPART=<%OEM%\esp-part.txt
if exist %WIN%\OEM\esp-part.txt set /p ESPPART=<%WIN%\OEM\esp-part.txt
if "%ESPPART%"=="" set ESPPART=1
echo   using partition %ESPPART% on disk 0
echo MANUAL_FINISH_ESP part=%ESPPART% temp=%TEMP% > COM1

rem Log the layout first: a different disk order or partition numbering in
rem WinPE is the only thing that can make the assign below fail.
(
echo list disk
echo select disk 0
echo list partition
echo exit
) > "%TEMP%\list_disk.txt"
diskpart /s "%TEMP%\list_disk.txt" > "%TEMP%\list_disk.log" 2>&1
type "%TEMP%\list_disk.log" > COM1 2>nul

(
echo select disk 0
echo select partition %ESPPART%
echo assign letter=S
echo exit
) > "%TEMP%\assign_esp.txt"
diskpart /s "%TEMP%\assign_esp.txt" > "%TEMP%\assign_esp.log" 2>&1
set DPRC=%errorlevel%
type "%TEMP%\assign_esp.log" > COM1 2>nul
echo MANUAL_FINISH_DISKPART rc=%DPRC% > COM1
if exist S:\EFI goto espaok

rem Fallback: mountvol /S mounts the EFI System partition.  Release a
rem wrongly assigned S: first so that the mount can take the letter.
echo   diskpart did not expose the ESP; trying mountvol S: /S
if exist S:\NUL mountvol S: /D > "%TEMP%\mountvol.log" 2>&1
mountvol S: /S >> "%TEMP%\mountvol.log" 2>&1
type "%TEMP%\mountvol.log" > COM1 2>nul
:espaok
if not exist S:\EFI goto noesp
echo MANUAL_FINISH_ESP_OK > COM1
echo.

echo [2/6] Adding virtio drivers to the offline image
dism /image:%WIN%\ /add-driver:"%OEM%\drivers" /recurse > "%TEMP%\dism1.log" 2>&1
set DRC=%errorlevel%
type "%TEMP%\dism1.log" > COM1 2>nul
echo MANUAL_FINISH_DISM drivers rc=%DRC% > COM1
if not "%DRC%"=="0" echo WARN: dism /add-driver drivers returned an error (continuing)
if exist "%OEM%\drivers-extra" dism /image:%WIN%\ /add-driver:"%OEM%\drivers-extra" /recurse > "%TEMP%\dism2.log" 2>&1
if exist "%TEMP%\dism2.log" type "%TEMP%\dism2.log" > COM1 2>nul
echo.

echo [3/6] Copying unattend, OEM scripts and drivers
if not exist %WIN%\Windows\Panther mkdir %WIN%\Windows\Panther
copy /y "%OEM%\autounattend.xml" %WIN%\Windows\Panther\unattend.xml > "%TEMP%\copy.log" 2>&1
xcopy /e /i /y "%OEM%\oem" %WIN%\OEM >> "%TEMP%\copy.log" 2>&1
xcopy /e /i /y "%OEM%\drivers" %WIN%\drivers >> "%TEMP%\copy.log" 2>&1
if exist "%OEM%\drivers-extra" xcopy /e /i /y "%OEM%\drivers-extra" %WIN%\drivers-extra >> "%TEMP%\copy.log" 2>&1
type "%TEMP%\copy.log" > COM1 2>nul
echo MANUAL_FINISH_COPY_OK > COM1
echo.

echo [4/6] Creating the EFI boot files on S:
bcdboot %WIN%\Windows /s S: /f UEFI > "%TEMP%\bcdboot.log" 2>&1
set BRC=%errorlevel%
type "%TEMP%\bcdboot.log" > COM1 2>nul
echo MANUAL_FINISH_BCDBOOT rc=%BRC% > COM1
if not "%BRC%"=="0" goto fail
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
bcdedit /store %BCD% /create /d "Ubuntu (recovery)" /application bootapp > "%TEMP%\bcdcreate.log" 2>&1
set CRRC=%errorlevel%
type "%TEMP%\bcdcreate.log" > COM1 2>nul
set GUB=
for /f "usebackq tokens=3" %%a in ("%TEMP%\bcdcreate.log") do set GUB=%%a
if "%GUB%"=="" goto bcdwarn
if not "%GUB:~0,1%"=="{" goto bcdwarn
bcdedit /store %BCD% /set %GUB% device partition=S: >> "%TEMP%\bcdcreate.log" 2>&1
if errorlevel 1 goto bcdwarn
bcdedit /store %BCD% /set %GUB% path \EFI\ubuntu\grubaa64.efi >> "%TEMP%\bcdcreate.log" 2>&1
if errorlevel 1 goto bcdwarn
bcdedit /store %BCD% /displayorder %GUB% /addlast >> "%TEMP%\bcdcreate.log" 2>&1
bcdedit /store %BCD% /timeout 1 >> "%TEMP%\bcdcreate.log" 2>&1
bcdedit /store %BCD% /set {bootmgr} displaybootmenu Yes >> "%TEMP%\bcdcreate.log" 2>&1
type "%TEMP%\bcdcreate.log" > COM1 2>nul
echo MANUAL_FINISH_BCD_OK entry=%GUB% > COM1
echo   entry %GUB% added
bcdedit /store %BCD% /enum %GUB% > "%TEMP%\bcdenum.log" 2>&1
type "%TEMP%\bcdenum.log" > COM1 2>nul
goto bcddone

:noubuntu
echo   no \EFI\ubuntu\grubaa64.efi on the ESP; skipping
echo MANUAL_FINISH_BCD_SKIPPED > COM1
goto bcddone

:bcdwarn
echo WARN: could not add the Ubuntu entry; Windows still boots.
echo       Add it later with bcdedit (see docs/DUALBOOT.md).
echo MANUAL_FINISH_BCD_FAILED > COM1

:bcddone
echo.
echo [6/6] Done.  Shutting down in 10 seconds...
echo MANUAL_FINISH_OK > COM1
ping -n 11 127.0.0.1 >nul
wpeutil shutdown
exit /b 0

:noesp
echo ERROR: the ESP was not assigned to S:.
echo MANUAL_FINISH_FAILED reason=noesp > COM1
exit /b 1

:nowin
echo ERROR: no existing Windows installation was found.
echo MANUAL_FINISH_FAILED reason=nowin > COM1
exit /b 1

:fail
echo.
echo *** MANUAL FINISH FAILED ***
echo MANUAL_FINISH_FAILED reason=bcdboot > COM1
exit /b 1
