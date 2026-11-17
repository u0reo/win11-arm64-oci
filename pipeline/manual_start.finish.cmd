@echo off
echo MANUAL_START_BEGIN > COM1
wpeinit
echo MANUAL_START_WPEINIT_DONE > COM1
echo.
echo === Installing vioscsi into WinPE ===
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\drivers\vioscsi.inf pnputil /add-driver %%d:\drivers\vioscsi.inf /install
pnputil /scan-devices
echo MANUAL_START_VIOSCSI_DONE > COM1
echo.
echo === Checking for an existing Windows installation ===
set EXIST=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\System32\ntoskrnl.exe set EXIST=%%d
if defined EXIST goto finish
echo No existing Windows found; looking for an install image.
echo MANUAL_START_NOWIN > COM1
echo.
echo === Waiting for sources\install.wim or install.esd ===
set WAIT=0
set SRC=
:wait
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\sources\install.wim set SRC=%%d
    if exist %%d:\sources\install.esd set SRC=%%d
)
if defined SRC goto found
set /a WAIT+=1
if %WAIT% GEQ 30 goto notfound
ping -n 3 127.0.0.1 >nul
goto wait
:found
echo Found install image on %SRC%:
if exist %SRC%:\sources\install.wim echo   %SRC%:\sources\install.wim
if exist %SRC%:\sources\install.esd echo   %SRC%:\sources\install.esd
echo MANUAL_START_INSTALL=%SRC% > COM1
echo.
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\manual_install.cmd call %%d:\manual_install.cmd
goto done
:finish
echo Found existing Windows on %EXIST%:
echo MANUAL_START_WINDOWS=%EXIST% > COM1
set FINISH_FAILED=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\manual_finish.cmd (
    call %%d:\manual_finish.cmd
    if errorlevel 1 set FINISH_FAILED=1
)
if defined FINISH_FAILED echo MANUAL_START_FAILED reason=manual_finish > COM1
if not defined FINISH_FAILED echo MANUAL_START_OK > COM1
goto done
:notfound
echo WARNING: install.wim / install.esd was not found after waiting.
echo MANUAL_START_FAILED reason=noinstall > COM1
:done
echo.
echo === manual_start.cmd finished ===
echo MANUAL_START_END > COM1
wpeutil shutdown
exit /b 0
