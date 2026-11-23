$ErrorActionPreference = "Continue"
$Oem = "C:\OEM"
New-Item -ItemType Directory -Force -Path $Oem | Out-Null
$Log = "$Oem\boot.log"
$Lock = "$Oem\boot.lock"
function Log($m) {
    try {
        ((Get-Date -Format "o") + " " + $m) | Out-File -Append -Encoding ascii $Log -ErrorAction Stop
    } catch {
        # A second instance may hold the log open; logging must never abort boot.
    }
}

# bcdedit prints one block per object, beginning with an "identifier" line.
# Keep only the fields we need for the firmware-entry comparison.
function Get-BcdObjects([string]$Text) {
    $objects = @()
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*identifier\s+(\{[^}]+\})') {
            if ($current) { $objects += $current }
            $current = @{ Id = $Matches[1] }
        } elseif ($current -and $line -match '^\s*(description|path|device)\s+(.+?)\s*$') {
            $current[$Matches[1]] = $Matches[2]
        }
    }
    if ($current) { $objects += $current }
    return $objects
}

# Compare the partition, not the spelling: bootmgr prints
# "partition=\Device\HarddiskVolume1" while a firmware object may print the
# bare device name.  A stale GPT GUID does not resolve to a HarddiskVolume and
# therefore never compares equal.
function Get-BcdDeviceKey([string]$Value) {
    if ($Value -match '(\\Device\\HarddiskVolume[0-9]+)') {
        return $Matches[1].ToLowerInvariant()
    }
    return $Value.ToLowerInvariant()
}

# Idempotent: only one instance at a time (scheduled task + first logon).
# A hard reset can leave a stale lock behind.  Ignore locks older than ten
# minutes, and negative ages (clock corrected backwards after an RTC read).
if (Test-Path $Lock) {
    $age = ((Get-Date) - (Get-Item $Lock).LastWriteTime).TotalMinutes
    if ($age -ge 0 -and $age -lt 10) { exit 0 }
    Remove-Item -Path $Lock -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType File -Path $Lock -Force | Out-Null
try {
    Log "=== boot start ==="
    Log ("whoami=" + (whoami))

    # RDP / TermService.  Use sc.exe only: the PowerShell service cmdlets can
    # block for minutes while the OOBE/setup session manager is still busy.
    $ts = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    $rdp = "$ts\WinStations\RDP-Tcp"
    Set-ItemProperty -Path $ts -Name fDenyTSConnections -Type DWord -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rdp -Name UserAuthentication -Type DWord -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rdp -Name SecurityLayer -Type DWord -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $rdp -Name MinEncryptionLevel -Type DWord -Value 1 -ErrorAction SilentlyContinue
    & sc.exe config TermService start= auto 2>&1 | Out-File -Append -Encoding ascii $Log
    & sc.exe start TermService 2>&1 | Out-File -Append -Encoding ascii $Log

    # WinRM: the listener itself is configured once by specialize.ps1 and is
    # stored in the registry, so only the service needs to be started here.
    & sc.exe config WinRM start= auto 2>&1 | Out-File -Append -Encoding ascii $Log
    & sc.exe start WinRM 2>&1 | Out-File -Append -Encoding ascii $Log

    & netsh.exe advfirewall set allprofiles state off 2>&1 | Out-File -Append -Encoding ascii $Log
    Log "services-configured"

    # Keep the UEFI "Ubuntu" boot option healthy and first.  Windows Setup
    # prepends its own Boot#### on first boot, and an Ubuntu entry that still
    # carries the GPT GUID of an older image wins the order but cannot load
    # its loader.  Repair the entry itself instead of only pushing {bootmgr}
    # to the end; GRUB's own default is still Windows 11 (WORKLOG 22.54).
    $ubuntuId = $null
    try {
        $espLetter = $null
        foreach ($cand in @('S:', 'T:', 'U:')) {
            if (Test-Path ($cand + '\')) { continue }
            & mountvol.exe $cand /s 2>&1 | Out-File -Append -Encoding ascii $Log
            if (Test-Path ($cand + '\EFI\Microsoft\Boot\bootmgfw.efi')) {
                $espLetter = $cand
                break
            }
            & mountvol.exe $cand /d 2>&1 | Out-File -Append -Encoding ascii $Log
        }
        if ($espLetter) {
            $loader = '\EFI\ubuntu\grubaa64.efi'
            if (Test-Path ($espLetter + '\EFI\ubuntu\shimaa64.efi')) {
                $loader = '\EFI\ubuntu\shimaa64.efi'
            }
            if (Test-Path ($espLetter + $loader)) {
                $bootmgrObjs = @(Get-BcdObjects (& bcdedit.exe /enum '{bootmgr}' 2>&1 | Out-String))
                $bootmgrDev = if ($bootmgrObjs.Count -gt 0) { Get-BcdDeviceKey $bootmgrObjs[0].device } else { '' }
                $fwObjs = @(Get-BcdObjects (& bcdedit.exe /enum firmware 2>&1 | Out-String))
                $ubuntuObjs = @($fwObjs | Where-Object {
                    $_.description -like '*Ubuntu*' -and $_.path -like '\EFI\ubuntu\*'
                })

                if (-not $bootmgrDev) {
                    Log "ubuntu-firmware-check-skipped: bootmgr has no device"
                }
                foreach ($u in $ubuntuObjs) {
                    $sameDevice = (Get-BcdDeviceKey $u.device) -eq $bootmgrDev
                    $samePath = ($u.path -ieq $loader) -or ($u.path -ieq '\EFI\ubuntu\grubaa64.efi')
                    if ($sameDevice -and $samePath -and -not $ubuntuId) {
                        $ubuntuId = $u.Id
                    } else {
                        Log ("ubuntu-firmware-stale: " + $u.Id + " device=" + $u.device + " path=" + $u.path)
                        & bcdedit.exe /delete $u.Id /f 2>&1 | Out-File -Append -Encoding ascii $Log
                    }
                }
                if (-not $ubuntuId) {
                    $created = (& bcdedit.exe /create /d "Ubuntu" /application firmware 2>&1 | Out-String)
                    $m = [regex]::Match($created, '\{[0-9a-fA-F-]{36}\}')
                    if ($m.Success) {
                        $ubuntuId = $m.Value
                        & bcdedit.exe /set $ubuntuId device partition=$espLetter 2>&1 | Out-File -Append -Encoding ascii $Log
                        & bcdedit.exe /set $ubuntuId path $loader 2>&1 | Out-File -Append -Encoding ascii $Log
                        Log ("ubuntu-firmware-created: " + $ubuntuId + " -> " + $loader + " on " + $espLetter)
                    } else {
                        Log ("ubuntu-firmware-create-failed: " + $created.Trim())
                    }
                }
                if ($ubuntuId) {
                    & bcdedit.exe /set '{fwbootmgr}' displayorder $ubuntuId /remove 2>&1 | Out-File -Append -Encoding ascii $Log
                    & bcdedit.exe /set '{fwbootmgr}' displayorder $ubuntuId /addfirst 2>&1 | Out-File -Append -Encoding ascii $Log
                    Log ("ubuntu-firmware-first: " + $ubuntuId)
                }
            } else {
                Log ("ubuntu-loader-missing: " + $loader)
            }
            & mountvol.exe $espLetter /d 2>&1 | Out-File -Append -Encoding ascii $Log
        } else {
            Log "esp-not-found-for-ubuntu-entry"
        }
    } catch {
        Log "ubuntu-firmware-entry-unavailable: $_"
    }

    if (-not $ubuntuId) {
        # Fallback when the Ubuntu entry cannot be created/repaired: keep the
        # old behaviour so the block-volume fallback (shim -> GRUB) still wins.
        try {
            & bcdedit.exe /set '{fwbootmgr}' displayorder '{bootmgr}' /addlast 2>&1 |
                Out-File -Append -Encoding ascii $Log
            Log ("fwbootmgr-windows-last rc=" + $LASTEXITCODE)
        } catch {
            Log "fwbootmgr-order-unavailable: $_"
        }
    }

    # The Windows Boot Manager OS chooser must stay Windows-only and brief.
    # ARM64 BootMgr cannot start an EFI application through a bootapp entry,
    # so an Ubuntu entry there only fails (WORKLOG 22.55).  Ubuntu stays in
    # {fwbootmgr} (the firmware BootMenu), where it reaches shim -> GRUB.
    try {
        & bcdedit.exe /set '{bootmgr}' timeout 1 2>&1 | Out-File -Append -Encoding ascii $Log
        Log ("wbm-timeout rc=" + $LASTEXITCODE)
        if ($ubuntuId) {
            & bcdedit.exe /set '{bootmgr}' displayorder $ubuntuId /remove 2>&1 |
                Out-File -Append -Encoding ascii $Log
            Log ("wbm-ubuntu-removed rc=" + $LASTEXITCODE)
        }
    } catch {
        Log "wbm-menu-unavailable: $_"
    }

    # Do NOT enable EMS here.  ARM64 Windows does not implement EMS/SAC, but
    # bcdedit still writes the BCD and returns 0.  On OCI A1 an explicit
    # EMSPORT:1 means the x86 COM1 I/O port 0x3F8, while the platform serial
    # port is a PL011 at MMIO 0x09000000; bootmgr/winload then hang silently
    # with no video output (WORKLOG 22.21-22.22).  pipeline/finish_disk.sh
    # removes any EMS elements from the final BCD; use RDP or WinRM for
    # Windows recovery.

    # Wait for both listeners.  netstat is used because Get-NetAdapter and
    # Get-NetTCPConnection can hang while the network stack is initializing.
    $rdpOk = $false
    $winrmOk = $false
    for ($i = 0; $i -lt 30; $i++) {
        $ns = & netstat.exe -an 2>&1
        $rdpOk = [bool]($ns | Select-String ":3389 " | Select-String "LISTENING")
        $winrmOk = [bool]($ns | Select-String ":5985 " | Select-String "LISTENING")
        if ($rdpOk -and $winrmOk) { break }
        Start-Sleep -Seconds 2
    }

    & ipconfig.exe /all 2>&1 | Out-File -Append -Encoding ascii $Log
    & netstat.exe -an 2>&1 | Out-File -Append -Encoding ascii $Log
    & sc.exe query TermService 2>&1 | Out-File -Append -Encoding ascii $Log
    & sc.exe query WinRM 2>&1 | Out-File -Append -Encoding ascii $Log
    Log ("listeners rdp=" + $rdpOk + " winrm=" + $winrmOk)

    if ($rdpOk -and $winrmOk) {
        "done" | Out-File -Encoding ascii "$Oem\done.txt"
        Log "READY rdp=1 winrm=1"
    } else {
        Log ("NOT-READY rdp=" + $rdpOk + " winrm=" + $winrmOk)
    }
    Log "=== boot done ==="
} finally {
    Remove-Item -Path $Lock -Force -ErrorAction SilentlyContinue
}
exit 0
