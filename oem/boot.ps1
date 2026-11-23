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

    # Keep the firmware boot order pointing at GRUB, not directly at Windows.
    # Windows Setup prepends its own Boot#### on first boot; if that wins, the
    # firmware never starts shim/GRUB and the Ubuntu recovery unit cannot run.
    # Moving {bootmgr} to the end of {fwbootmgr} displayorder leaves the OCI
    # block-volume fallback (which starts \EFI\BOOT\BOOTAA64.EFI) first.
    # GRUB's own default is still Windows 11, so the default boot is unchanged.
    try {
        & bcdedit.exe /set '{fwbootmgr}' displayorder '{bootmgr}' /addlast 2>&1 |
            Out-File -Append -Encoding ascii $Log
        Log ("fwbootmgr-windows-last rc=" + $LASTEXITCODE)
    } catch {
        Log "fwbootmgr-order-unavailable: $_"
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
