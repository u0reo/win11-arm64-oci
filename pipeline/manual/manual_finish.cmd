@echo off
setlocal
set OEM=%~d0
set WIN=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\System32\ntoskrnl.exe set WIN=%%d:
if "%WIN%"=="" goto nowin
set LOG=%WIN%\manual-finish.log

echo ============================================================
echo Manual finish: drivers + boot files
echo   OEMDRV  = %OEM%
echo   WINDOWS = %WIN%
echo ============================================================
> "%LOG%" echo MANUAL_FINISH_BEGIN oem=%OEM% win=%WIN%
echo.

echo [1/6] Assigning the ESP to S:
rem host_apply.sh writes the ESP partition number to OEM\esp-part.txt on
rem the Windows volume.  Keep partition 1 as the fallback for fresh disks.
set ESPPART=1
if exist "%OEM%\esp-part.txt" set /p ESPPART=<%OEM%\esp-part.txt
if exist %WIN%\OEM\esp-part.txt set /p ESPPART=<%WIN%\OEM\esp-part.txt
if "%ESPPART%"=="" set ESPPART=1
echo   using partition %ESPPART% on disk 0
>> "%LOG%" echo ESP part=%ESPPART%

rem Log the layout first: a different disk order or partition numbering in
rem WinPE is the only thing that can make the assign below fail.
(
echo list disk
echo select disk 0
echo list partition
echo exit
) > "%TEMP%\list_disk.txt"
diskpart /s "%TEMP%\list_disk.txt" > "%TEMP%\list_disk.log" 2>&1
type "%TEMP%\list_disk.log" >> "%LOG%"

(
echo select disk 0
echo select partition %ESPPART%
echo assign letter=S
echo exit
) > "%TEMP%\assign_esp.txt"
diskpart /s "%TEMP%\assign_esp.txt" > "%TEMP%\assign_esp.log" 2>&1
set DPRC=%errorlevel%
type "%TEMP%\assign_esp.log" >> "%LOG%"
>> "%LOG%" echo DISKPART rc=%DPRC%
if exist S:\EFI goto espaok

rem Fallback: mountvol /S mounts the EFI System partition.  Release a
rem wrongly assigned S: first so that the mount can take the letter.
echo   diskpart did not expose the ESP; trying mountvol S: /S
if exist S:\NUL mountvol S: /D > "%TEMP%\mountvol.log" 2>&1
mountvol S: /S >> "%TEMP%\mountvol.log" 2>&1
type "%TEMP%\mountvol.log" >> "%LOG%"
:espaok
if not exist S:\EFI goto noesp
>> "%LOG%" echo ESP_OK
echo.

echo [2/6] Adding virtio drivers to the offline image
dism /image:%WIN%\ /add-driver:"%OEM%\drivers" /recurse > "%TEMP%\dism1.log" 2>&1
set DRC=%errorlevel%
type "%TEMP%\dism1.log" >> "%LOG%"
>> "%LOG%" echo DISM_DRIVERS rc=%DRC%
if not "%DRC%"=="0" goto faildism
if not exist "%OEM%\drivers-extra" goto nodism2
dism /image:%WIN%\ /add-driver:"%OEM%\drivers-extra" /recurse > "%TEMP%\dism2.log" 2>&1
>> "%LOG%" echo DISM_EXTRA rc=%errorlevel%
type "%TEMP%\dism2.log" >> "%LOG%"
:nodism2
echo.

echo [3/6] Copying unattend, OEM scripts and drivers
if not exist %WIN%\Windows\Panther mkdir %WIN%\Windows\Panther
copy /y "%OEM%\autounattend.xml" %WIN%\Windows\Panther\unattend.xml > "%TEMP%\copy.log" 2>&1
xcopy /e /i /y "%OEM%\oem" %WIN%\OEM >> "%TEMP%\copy.log" 2>&1
xcopy /e /i /y "%OEM%\drivers" %WIN%\drivers >> "%TEMP%\copy.log" 2>&1
if exist "%OEM%\drivers-extra" xcopy /e /i /y "%OEM%\drivers-extra" %WIN%\drivers-extra >> "%TEMP%\copy.log" 2>&1
set CRC=%errorlevel%
type "%TEMP%\copy.log" >> "%LOG%"
>> "%LOG%" echo COPY rc=%CRC%
if not "%CRC%"=="0" goto failcopy
echo.

echo [4/6] Creating the EFI boot files on S:
bcdboot %WIN%\Windows /s S: /f UEFI > "%TEMP%\bcdboot.log" 2>&1
set BRC=%errorlevel%
type "%TEMP%\bcdboot.log" >> "%LOG%"
>> "%LOG%" echo BCDBOOT rc=%BRC%
if not "%BRC%"=="0" goto failbcdboot

rem bcdboot leaves an existing \EFI\Boot\BOOTAA64.EFI (the Ubuntu shim)
rem untouched.  The firmware starts that path on an empty boot order, so put
rem the Windows boot manager there.  The host repairs this again if needed.
if not exist S:\EFI\Boot mkdir S:\EFI\Boot
if not exist "%WIN%\Windows\Boot\EFI\bootmgfw.efi" goto nofallback
copy /y "%WIN%\Windows\Boot\EFI\bootmgfw.efi" S:\EFI\Boot\BOOTAA64.EFI > "%TEMP%\fallback.log" 2>&1
>> "%LOG%" echo FALLBACK_BOOT rc=%errorlevel%
type "%TEMP%\fallback.log" >> "%LOG%"
goto fallbackdone
:nofallback
>> "%LOG%" echo FALLBACK_BOOT skipped=no-source
:fallbackdone
echo.

echo [5/6] Checking for the recovery Ubuntu loader
rem The Ubuntu BCD entry is written by the host after QEMU stops; bcdedit's
rem "device partition=S:" fails in this WinPE.  Only report what is here.
if not exist S:\EFI\ubuntu\grubaa64.efi goto noubuntugrub
>> "%LOG%" echo UBUNTU_GRUB present
echo   \EFI\ubuntu\grubaa64.efi is present
goto ubuntugrubdone
:noubuntugrub
>> "%LOG%" echo UBUNTU_GRUB absent
echo   WARNING: \EFI\ubuntu\grubaa64.efi is absent
:ubuntugrubdone
echo.

echo [6/6] Done.  Shutting down...
>> "%LOG%" echo MANUAL_FINISH_OK
ping -n 4 127.0.0.1 >nul
wpeutil shutdown
exit /b 0

:noesp
echo ERROR: the ESP was not assigned to S:.
>> "%LOG%" echo MANUAL_FINISH_FAILED reason=noesp
exit /b 1

:nowin
echo ERROR: no existing Windows installation was found.
exit /b 1

:faildism
echo ERROR: dism /add-driver failed.
>> "%LOG%" echo MANUAL_FINISH_FAILED reason=dism
exit /b 1

:failcopy
echo ERROR: copying unattend/OEM files failed.
>> "%LOG%" echo MANUAL_FINISH_FAILED reason=copy
exit /b 1

:failbcdboot
echo ERROR: bcdboot failed.
>> "%LOG%" echo MANUAL_FINISH_FAILED reason=bcdboot
exit /b 1
