$ErrorActionPreference = "Continue"
$Oem = "C:\OEM"
New-Item -ItemType Directory -Force -Path $Oem | Out-Null
$Log = "$Oem\winre.log"
function Log($m) {
    try {
        ((Get-Date -Format "o") + " " + $m) |
            Out-File -Append -Encoding ascii $Log -ErrorAction Stop
    } catch {
        # Logging must never abort the move.
    }
}

# Move Windows RE to the dedicated partition created by host_apply.sh.
# Runs from the specialize pass and again at first logon (as a retry).
# Builds without --winre-partition have no winre-part.txt and do nothing.
Log "=== winre start ==="

$PartFile = "$Oem\winre-part.txt"
if (-not (Test-Path $PartFile)) {
    Log "no winre-part.txt; Windows RE stays on C:"
    return
}
$WinRePart = 0
try {
    $WinRePart = [int]((Get-Content -Path $PartFile -Raw).Trim())
} catch {
    Log ("winre-part-read-fail " + $_.Exception.Message)
}
if ($WinRePart -le 0) {
    Log "winre-part-invalid"
    return
}
Log ("winre-part=" + $WinRePart)

# host_apply.sh records the partition start.  ReAgent.xml stores the same
# byte offset, which is how the verification below tells p4 from C: without
# parsing localized reagentc output.
$WinReOffset = [uint64]0
$OffsetFile = "$Oem\winre-offset.txt"
if (Test-Path $OffsetFile) {
    try {
        $WinReOffset = [uint64]((Get-Content -Path $OffsetFile -Raw).Trim())
    } catch {
        Log ("winre-offset-read-fail " + $_.Exception.Message)
    }
}
if ($WinReOffset -eq 0) {
    try {
        $Part = Get-Partition -DiskNumber 0 -PartitionNumber $WinRePart -ErrorAction Stop
        $WinReOffset = [uint64]$Part.Offset
    } catch {
        Log ("winre-offset-unknown " + $_.Exception.Message)
    }
}
Log ("winre-offset=" + $WinReOffset)

$ReAgent = "$env:SystemRoot\System32\ReAgentc.exe"
$WinReStage = "$env:SystemRoot\System32\Recovery"
$ReAgentXml = "$WinReStage\ReAgent.xml"
$WinReC = "$env:SystemDrive\Recovery\WindowsRE"

function Get-WinReState {
    if (-not (Test-Path $ReAgentXml)) { return $null }
    try {
        [xml]$cfg = Get-Content -Path $ReAgentXml -Raw -ErrorAction Stop
        $loc = $cfg.WindowsRE.WinreLocation
        $inst = $cfg.WindowsRE.InstallState
        if ($null -eq $loc) { return $null }
        return [pscustomobject]@{
            Path = [string]$loc.path
            Offset = [uint64]$loc.offset
            State = [int]$inst.state
        }
    } catch {
        Log ("winre-xml-fail " + $_.Exception.Message)
        return $null
    }
}

function Test-WinReOnTarget($Cfg) {
    if ($null -eq $Cfg) { return $false }
    if ($Cfg.State -ne 1) { return $false }
    if ($WinReOffset -gt 0) {
        return ($Cfg.Offset -eq $WinReOffset)
    }
    # Without a recorded offset this is weaker, but still requires the
    # standard WinRE directory and an enabled install state.
    return ($Cfg.Path -eq "\Recovery\WindowsRE")
}

# The recovery partition has GPT attribute bit 63 (no automatic drive
# letter), so pick a free letter and assign it only while WinRE is moved.
$Letter = ""
foreach ($L in @("R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
    if (-not (Test-Path -LiteralPath "${L}:\" -ErrorAction SilentlyContinue)) {
        $Letter = $L
        break
    }
}
if ($Letter -eq "") {
    Log "winre-no-free-letter"
    return
}
$Drive = "${Letter}:"
$DiskPart = Join-Path $env:TEMP "winre-diskpart.txt"
$Assigned = $false

@"
select disk 0
select partition $WinRePart
assign letter=$Letter
"@ | Out-File -Encoding ascii $DiskPart
& diskpart.exe /s $DiskPart 2>&1 | Out-File -Append -Encoding ascii $Log
Log ("winre-assign rc=" + $LASTEXITCODE)
for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath "${Drive}\" -ErrorAction SilentlyContinue); $i++) {
    Start-Sleep -Milliseconds 500
}
if (Test-Path -LiteralPath "${Drive}\" -ErrorAction SilentlyContinue) {
    $Assigned = $true
} else {
    Log ("winre-assign-failed " + $Drive)
}

try {
    if (-not $Assigned) {
        Log "winre-skip (no drive letter)"
        return
    }

    $Target = "$Drive\Recovery\WindowsRE"
    $Cfg = Get-WinReState

    # Windows setup's own WinRE specialize pass runs before the OEM
    # RunSynchronous command and already installs onto a type-2700 partition.
    # In that case there is nothing to move.
    if ((Test-Path "$Target\Winre.wim") -and (Test-WinReOnTarget $Cfg)) {
        Log "winre-already-on-dedicated"
        Remove-Item -Path "$Oem\winre.failed" -Force -ErrorAction SilentlyContinue
        "dedicated" | Out-File -Encoding ascii "$Oem\winre.done"
        return
    }

    # Fallback: WinRE is still on C: (or the configuration does not match).
    # Disable it first so the image is no longer in use, then copy the
    # staged image to the dedicated partition and enable it there.
    & $ReAgent /disable 2>&1 | Out-File -Append -Encoding ascii $Log
    Log ("winre-disable rc=" + $LASTEXITCODE)

    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    foreach ($Name in @("Winre.wim", "boot.sdi")) {
        if (Test-Path "$Target\$Name") {
            Log ("winre-keep " + $Name)
            continue
        }
        $Copied = $false
        foreach ($Dir in @($WinReStage, $WinReC)) {
            $Src = Join-Path $Dir $Name
            if (Test-Path $Src) {
                Copy-Item -Path $Src -Destination "$Target\$Name" -Force
                Log ("winre-copy " + $Name + " from " + $Src)
                $Copied = $true
                break
            }
        }
        if (-not $Copied) {
            Log ("winre-copy " + $Name + " missing")
        }
    }

    & $ReAgent /setreimage /path $Target 2>&1 |
        Out-File -Append -Encoding ascii $Log
    Log ("winre-setreimage rc=" + $LASTEXITCODE)
    & $ReAgent /enable 2>&1 | Out-File -Append -Encoding ascii $Log
    $EnableRc = $LASTEXITCODE
    Log ("winre-enable rc=" + $EnableRc)
    & $ReAgent /info 2>&1 | Out-File -Append -Encoding ascii $Log

    $Ok = ($EnableRc -eq 0) -and (Test-Path "$Target\Winre.wim")
    $Cfg = $null
    for ($i = 0; $i -lt 5; $i++) {
        $Cfg = Get-WinReState
        if (Test-WinReOnTarget $Cfg) { break }
        Start-Sleep -Seconds 1
    }
    if ($Ok -and (Test-WinReOnTarget $Cfg)) {
        Log "winre-moved"
        Remove-Item -Path "$Oem\winre.failed" -Force -ErrorAction SilentlyContinue
        "moved" | Out-File -Encoding ascii "$Oem\winre.done"
    } else {
        # Never leave Windows RE disabled.  Put the image back on C: and
        # enable it there if the dedicated partition was rejected.
        Log "winre-move-failed; restoring C:"
        New-Item -ItemType Directory -Force -Path $WinReStage | Out-Null
        foreach ($Name in @("Winre.wim", "boot.sdi")) {
            $Src = "$Target\$Name"
            if (Test-Path $Src) {
                Copy-Item -Path $Src -Destination "$WinReStage\$Name" -Force
            }
        }
        & $ReAgent /setreimage /path $WinReStage 2>&1 |
            Out-File -Append -Encoding ascii $Log
        & $ReAgent /enable 2>&1 | Out-File -Append -Encoding ascii $Log
        Log ("winre-fallback rc=" + $LASTEXITCODE)
        & $ReAgent /info 2>&1 | Out-File -Append -Encoding ascii $Log
        Remove-Item -Path "$Oem\winre.done" -Force -ErrorAction SilentlyContinue
        "failed" | Out-File -Encoding ascii "$Oem\winre.failed"
    }
} finally {
    if ($Assigned) {
        @"
select disk 0
select partition $WinRePart
remove letter=$Letter
"@ | Out-File -Encoding ascii $DiskPart
        & diskpart.exe /s $DiskPart 2>&1 | Out-File -Append -Encoding ascii $Log
        Log ("winre-unassign rc=" + $LASTEXITCODE)
    }
    Log "=== winre done ==="
}
