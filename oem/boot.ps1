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
