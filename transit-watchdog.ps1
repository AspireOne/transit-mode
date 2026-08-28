# transit-watchdog.ps1
# Internal worker for transit-mode.ps1. Run through the Transit Mode scheduled task.

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("run", "probe")]
    [string]$Action,

    [string]$ExpectedScheme
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PollIntervalSeconds       = 5
$SustainedTemperatureC     = 80
$SustainedTemperatureTime  = 30
$TemperatureResetC         = 75
$CriticalTemperatureC      = 90
$MissingSensorGraceSeconds = 30
$StartupGraceSeconds       = 30
$ResumeGapSeconds          = 20
$ThermalLogRetentionDays   = 30

$StateDir          = Join-Path $env:ProgramData "TransitMode"
$StateFile         = Join-Path $StateDir "state.json"
$WatchdogStatusFile = Join-Path $StateDir "watchdog-status.json"
$WatchdogLogFile    = Join-Path $StateDir "watchdog.log"
$SensorDir          = Join-Path $StateDir "lib\v0.9.6"
$SensorLibrary      = Join-Path $SensorDir "LibreHardwareMonitorLib.dll"
$script:ThermalLogWarningIssued = $false

function Write-WatchdogLog {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $line = "{0} {1}" -f (Get-Date).ToString("o"), $Message
        Add-Content -LiteralPath $WatchdogLogFile -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never prevent the emergency action.
    }
}

function Write-ThermalSample {
    param(
        [Nullable[double]]$CpuTemperatureC,
        [Parameter(Mandatory)][string]$State,
        [Nullable[double]]$HotSeconds
    )

    if ($script:ThermalLogWarningIssued) {
        return
    }

    try {
        $now = Get-Date
        $path = Join-Path $StateDir ("thermal-{0}.csv" -f $now.ToString("yyyy-MM-dd"))
        if (-not (Test-Path -LiteralPath $path)) {
            "Timestamp,CpuTemperatureC,State,HotSeconds,TransitScheme" |
                Set-Content -LiteralPath $path -Encoding UTF8
        }

        $temperatureText = if ($null -eq $CpuTemperatureC) {
            ""
        }
        else {
            ([double]$CpuTemperatureC).ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)
        }

        $hotSecondsText = if ($null -eq $HotSeconds) {
            ""
        }
        else {
            ([double]$HotSeconds).ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)
        }

        $line = '"{0}",{1},"{2}",{3},"{4}"' -f `
            $now.ToString("o"), $temperatureText, $State, $hotSecondsText, $ExpectedScheme
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    }
    catch {
        if (-not $script:ThermalLogWarningIssued) {
            $script:ThermalLogWarningIssued = $true
            Write-WatchdogLog "Thermal history logging failed and was disabled for this run: $($_.Exception.Message)"
        }
    }
}

function Remove-ExpiredThermalLogs {
    try {
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$ThermalLogRetentionDays)
        Get-ChildItem -LiteralPath $StateDir -Filter "thermal-????-??-??.csv" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
            Remove-Item -Force
    }
    catch {
        Write-WatchdogLog "Could not remove expired thermal history: $($_.Exception.Message)"
    }
}

function Write-WatchdogStatus {
    param(
        [Parameter(Mandatory)][string]$State,
        [Nullable[double]]$CpuTemperatureC,
        [string[]]$Sensors = @(),
        [Nullable[double]]$HotSeconds,
        [string]$Reason
    )

    $status = [ordered]@{
        Version            = 1
        State              = $State
        ProcessId          = $PID
        UpdatedAt          = (Get-Date).ToString("o")
        ExpectedScheme     = $ExpectedScheme
        CpuTemperatureC    = $CpuTemperatureC
        Sensors            = $Sensors
        HotSeconds         = $HotSeconds
        Reason             = $Reason
        SustainedLimitC    = $SustainedTemperatureC
        SustainedSeconds   = $SustainedTemperatureTime
        CriticalLimitC     = $CriticalTemperatureC
        SensorFailureGrace = $MissingSensorGraceSeconds
    }

    $tempFile = "$WatchdogStatusFile.$PID.tmp"
    $status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempFile -Encoding UTF8
    Move-Item -LiteralPath $tempFile -Destination $WatchdogStatusFile -Force
}

function Import-SensorLibrary {
    if (-not (Test-Path -LiteralPath $SensorLibrary)) {
        throw "LibreHardwareMonitor is missing at '$SensorLibrary'."
    }

    $dependencyOrder = @(
        "System.Buffers.dll",
        "System.Runtime.CompilerServices.Unsafe.dll",
        "System.Numerics.Vectors.dll",
        "System.Memory.dll",
        "BlackSharp.Core.dll",
        "DiskInfoToolkit.dll",
        "HidSharp.dll",
        "RAMSPDToolkit-NDD.dll"
    )

    foreach ($dependency in $dependencyOrder) {
        $path = Join-Path $SensorDir $dependency
        if (-not (Test-Path -LiteralPath $path)) {
            throw "LibreHardwareMonitor dependency is missing: '$path'."
        }

        [void][Reflection.Assembly]::LoadFrom($path)
    }

    Add-Type -Path $SensorLibrary
}

function New-CpuMonitor {
    $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
    $computer.IsCpuEnabled = $true
    $computer.Open()
    return $computer
}

function Get-PawnIoDescription {
    $pawnIoType = [LibreHardwareMonitor.PawnIo.PawnIo]
    if (-not $pawnIoType::IsInstalled) {
        return "not installed"
    }

    return "v$($pawnIoType::Version)"
}

function Get-CpuSensorInventory {
    param([Parameter(Mandatory)]$Computer)

    $inventory = @()
    foreach ($hardware in $Computer.Hardware) {
        if ($hardware.HardwareType -ne [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
            continue
        }

        $hardware.Update()
        foreach ($sensor in $hardware.Sensors) {
            if ($sensor.SensorType -ne [LibreHardwareMonitor.Hardware.SensorType]::Temperature) {
                continue
            }

            $displayValue = "null"
            if ($null -ne $sensor.Value) {
                $displayValue = ([double]$sensor.Value).ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)
            }

            $inventory += "{0}={1} C [{2}]" -f $sensor.Name, $displayValue, $sensor.Identifier
        }
    }

    return @($inventory)
}

function Read-CpuTemperature {
    param([Parameter(Mandatory)]$Computer)

    $readings = @()

    foreach ($hardware in $Computer.Hardware) {
        if ($hardware.HardwareType -ne [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
            continue
        }

        $hardware.Update()

        foreach ($sensor in $hardware.Sensors) {
            if ($sensor.SensorType -ne [LibreHardwareMonitor.Hardware.SensorType]::Temperature) {
                continue
            }

            if ($null -eq $sensor.Value) {
                continue
            }

            $value = [double]$sensor.Value
            if ([double]::IsNaN($value) -or
                [double]::IsInfinity($value) -or
                ($value -le 0) -or
                ($value -gt 200)) {
                continue
            }

            $readings += [pscustomobject]@{
                Name       = [string]$sensor.Name
                Identifier = [string]$sensor.Identifier
                ValueC     = $value
            }
        }
    }

    if ($readings.Count -eq 0) {
        return $null
    }

    $maximum = $readings | Sort-Object ValueC -Descending | Select-Object -First 1
    return [pscustomobject]@{
        MaximumC = [double]$maximum.ValueC
        Sensors  = @($readings | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Identifier })
        Readings = $readings
    }
}

function Get-ActiveSchemeGuid {
    $output = & powercfg.exe /getactivescheme 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /getactivescheme failed: $(($output | Out-String).Trim())"
    }

    $text = $output | Out-String
    if ($text -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
        return $Matches[0].ToLowerInvariant()
    }

    throw "Could not determine the active power scheme GUID."
}

function Test-RecoveryStateRequiresFailSafe {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if (([string]$state.TransitScheme).ToLowerInvariant() -ne $ExpectedScheme.ToLowerInvariant()) {
            return $false
        }

        if ([string]$state.Status -eq "active") {
            return $true
        }

        if ([string]$state.Status -eq "activating") {
            $controllerProperty = $state.PSObject.Properties["ControllerProcessId"]
            if ($null -eq $controllerProperty) {
                return $true
            }

            $controller = Get-Process -Id ([int]$controllerProperty.Value) -ErrorAction SilentlyContinue
            return $null -eq $controller
        }

        return $false
    }
    catch {
        return $false
    }
}

function Get-ThermalDecision {
    param(
        [Parameter(Mandatory)][double]$TemperatureC,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        $HotSince
    )

    if ($TemperatureC -ge $CriticalTemperatureC) {
        return [pscustomobject]@{
            Action     = "hibernate"
            State      = "critical"
            HotSince   = $HotSince
            HotSeconds = $null
            Reason     = "CPU temperature reached the immediate limit: {0:N1} C." -f $TemperatureC
        }
    }

    if (($TemperatureC -ge $SustainedTemperatureC) -and ($null -eq $HotSince)) {
        $HotSince = $Now
    }
    elseif ($TemperatureC -le $TemperatureResetC) {
        $HotSince = $null
    }

    $hotSeconds = $null
    if ($null -ne $HotSince) {
        $hotSeconds = ($Now - $HotSince).TotalSeconds
    }

    if (($null -ne $hotSeconds) -and ($hotSeconds -ge $SustainedTemperatureTime)) {
        return [pscustomobject]@{
            Action     = "hibernate"
            State      = "hot"
            HotSince   = $HotSince
            HotSeconds = $hotSeconds
            Reason     = "CPU entered the {0} C hot band and did not cool to {1} C within {2:N0} seconds; current temperature is {3:N1} C." -f $SustainedTemperatureC, $TemperatureResetC, $hotSeconds, $TemperatureC
        }
    }

    $state = "healthy"
    if ($null -ne $HotSince) {
        $state = "hot"
    }

    return [pscustomobject]@{
        Action     = "continue"
        State      = $state
        HotSince   = $HotSince
        HotSeconds = $hotSeconds
        Reason     = $null
    }
}

function Initialize-NativePowerApi {
    if ("TransitModeWatchdogNativePower" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class TransitModeWatchdogNativePower
{
    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool SetSuspendState(
        [MarshalAs(UnmanagedType.U1)] bool hibernate,
        [MarshalAs(UnmanagedType.U1)] bool force,
        [MarshalAs(UnmanagedType.U1)] bool disableWakeEvents);
}
'@
}

function Invoke-EmergencyHibernate {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Nullable[double]]$CpuTemperatureC,
        [string[]]$Sensors = @()
    )

    Write-WatchdogLog "EMERGENCY: $Reason"

    try {
        Write-WatchdogStatus `
            -State "hibernating" `
            -CpuTemperatureC $CpuTemperatureC `
            -Sensors $Sensors `
            -Reason $Reason
    }
    catch {
        Write-WatchdogLog "Could not write emergency status: $($_.Exception.Message)"
    }

    Initialize-NativePowerApi
    # Suppress wake timers/events so an emergency-hibernated laptop does not
    # resume unattended while it is still packed away.
    $accepted = [TransitModeWatchdogNativePower]::SetSuspendState($true, $false, $true)
    if (-not $accepted) {
        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-WatchdogLog "SetSuspendState failed with Win32 error $nativeError; trying shutdown.exe /h."

        $fallbackOutput = & shutdown.exe /h 2>&1
        if ($LASTEXITCODE -ne 0) {
            $hibernateFailure = "SetSuspendState error: $nativeError; shutdown.exe /h: $(($fallbackOutput | Out-String).Trim())"
            Write-WatchdogLog "Both hibernation methods failed ($hibernateFailure); forcing a safety shutdown."

            $shutdownOutput = & shutdown.exe /s /f /t 0 /d p:0:0 /c "Transit Mode thermal watchdog emergency" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Emergency hibernation and shutdown failed. $hibernateFailure; shutdown.exe /s: $(($shutdownOutput | Out-String).Trim())"
            }

            # Windows accepted the forced shutdown request. It can terminate this
            # process before another durable status update would be meaningful.
            exit 0
        }

        # shutdown.exe has accepted the request. Keep the durable status as "hibernating".
        exit 0
    }

    # SetSuspendState returns here after the machine resumes.
    Write-WatchdogLog "System resumed after emergency hibernation. Transit Mode still requires 'off'."
    Write-WatchdogStatus `
        -State "resumed-after-emergency" `
        -CpuTemperatureC $CpuTemperatureC `
        -Sensors $Sensors `
        -Reason $Reason
}

function Invoke-Probe {
    param([Parameter(Mandatory)]$Computer)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Output "  Process: Windows PowerShell $($PSVersionTable.PSVersion), $([IntPtr]::Size * 8)-bit"
    Write-Output "  Administrator: $isAdministrator"
    Write-Output "  PawnIO visible to LibreHardwareMonitor: $(Get-PawnIoDescription)"

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupGraceSeconds)
    do {
        $reading = Read-CpuTemperature -Computer $Computer
        if ($null -ne $reading) {
            Write-Output ("CPU temperature: {0:N1} C" -f $reading.MaximumC)
            foreach ($sensor in $reading.Readings) {
                Write-Output ("  {0}: {1:N1} C [{2}]" -f $sensor.Name, $sensor.ValueC, $sensor.Identifier)
            }
            return
        }

        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $inventory = @(Get-CpuSensorInventory -Computer $Computer)
    $inventoryText = if ($inventory.Count -eq 0) {
        "no CPU temperature sensors were exposed"
    }
    else {
        $inventory -join "; "
    }

    throw "No valid CPU temperature appeared within $StartupGraceSeconds seconds. Raw temperature sensors: $inventoryText."
}

if (($Action -eq "run") -and [string]::IsNullOrWhiteSpace($ExpectedScheme)) {
    throw "ExpectedScheme is required for watchdog mode."
}

if ($Action -eq "run") {
    $expectedSchemeGuid = [guid]::Empty
    if (-not [guid]::TryParse($ExpectedScheme, [ref]$expectedSchemeGuid)) {
        throw "ExpectedScheme is not a valid GUID."
    }
}

$computer = $null
$monitoringEstablished = $false

try {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    if ($Action -eq "run") {
        Remove-ExpiredThermalLogs
    }
    Import-SensorLibrary
    $computer = New-CpuMonitor

    if ($Action -eq "probe") {
        Invoke-Probe -Computer $computer
        return
    }

    $ExpectedScheme = $ExpectedScheme.ToLowerInvariant()
    $startupDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupGraceSeconds)
    $reading = $null

    do {
        try {
            $reading = Read-CpuTemperature -Computer $computer
        }
        catch {
            Write-WatchdogLog "Sensor startup attempt failed: $($_.Exception.Message)"
        }

        if ($null -ne $reading) {
            break
        }

        Write-WatchdogStatus -State "starting" -Reason "Waiting for a valid CPU temperature."
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $startupDeadline)

    if ($null -eq $reading) {
        throw "No valid CPU temperature appeared within $StartupGraceSeconds seconds."
    }

    if ((Get-ActiveSchemeGuid) -ne $ExpectedScheme) {
        throw "The expected Transit Mode power scheme is not active."
    }

    $monitoringEstablished = $true
    $startedAt = [DateTimeOffset]::UtcNow
    $lastLoopAt = $startedAt
    $lastPeriodicLogAt = [DateTimeOffset]::MinValue
    $hotSince = $null
    $missingSince = $null

    Write-WatchdogLog ("Watchdog started. CPU={0:N1} C; sustained={1} C/{2}s; critical={3} C." -f $reading.MaximumC, $SustainedTemperatureC, $SustainedTemperatureTime, $CriticalTemperatureC)

    while ($true) {
        $now = [DateTimeOffset]::UtcNow
        $loopGap = ($now - $lastLoopAt).TotalSeconds
        $lastLoopAt = $now

        if ($loopGap -gt $ResumeGapSeconds) {
            $hotSince = $null
            $missingSince = $null
            Write-WatchdogLog ("Long scheduling gap detected ({0:N0}s); thermal timers reset." -f $loopGap)
        }

        if ((Get-ActiveSchemeGuid) -ne $ExpectedScheme) {
            Invoke-EmergencyHibernate -Reason "The Transit Mode power scheme stopped being active."
            exit 0
        }

        try {
            $reading = Read-CpuTemperature -Computer $computer
        }
        catch {
            $reading = $null
            Write-WatchdogLog "Sensor update failed: $($_.Exception.Message)"
        }

        if ($null -eq $reading) {
            if ($null -eq $missingSince) {
                $missingSince = $now
            }

            $missingSeconds = ($now - $missingSince).TotalSeconds
            Write-WatchdogStatus -State "sensor-missing" -Reason ("No valid CPU temperature for {0:N0}s." -f $missingSeconds)
            Write-ThermalSample -State "sensor-missing"

            if ($missingSeconds -ge $MissingSensorGraceSeconds) {
                Invoke-EmergencyHibernate -Reason ("CPU temperature monitoring was unavailable for {0:N0} seconds." -f $missingSeconds)
                exit 0
            }
        }
        else {
            $missingSince = $null
            $temperature = [double]$reading.MaximumC

            $previousHotSince = $hotSince
            $decision = Get-ThermalDecision -TemperatureC $temperature -Now $now -HotSince $hotSince
            $hotSince = $decision.HotSince

            if (($null -eq $previousHotSince) -and ($null -ne $hotSince)) {
                Write-WatchdogLog ("CPU crossed the sustained threshold: {0:N1} C." -f $temperature)
            }

            if ($decision.Action -eq "hibernate") {
                Write-ThermalSample `
                    -CpuTemperatureC $temperature `
                    -State $decision.State `
                    -HotSeconds $decision.HotSeconds
                Invoke-EmergencyHibernate `
                    -Reason $decision.Reason `
                    -CpuTemperatureC $temperature `
                    -Sensors $reading.Sensors
                exit 0
            }

            Write-WatchdogStatus `
                -State $decision.State `
                -CpuTemperatureC $temperature `
                -Sensors $reading.Sensors `
                -HotSeconds $decision.HotSeconds
            Write-ThermalSample `
                -CpuTemperatureC $temperature `
                -State $decision.State `
                -HotSeconds $decision.HotSeconds

            if (($now - $lastPeriodicLogAt).TotalSeconds -ge 60) {
                Write-WatchdogLog ("CPU={0:N1} C; state={1}." -f $temperature, $decision.State)
                $lastPeriodicLogAt = $now
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
catch {
    $message = $_.Exception.Message
    Write-WatchdogLog "FATAL: $message"

    if (($Action -eq "run") -and ($monitoringEstablished -or (Test-RecoveryStateRequiresFailSafe))) {
        try {
            Invoke-EmergencyHibernate -Reason "The temperature watchdog failed: $message"
            exit 0
        }
        catch {
            Write-WatchdogLog "HIBERNATION FAILED: $($_.Exception.Message)"
            try {
                Write-WatchdogStatus -State "failed" -Reason $_.Exception.Message
            }
            catch {
                # The task must still exit nonzero so Task Scheduler can restart it.
            }
            exit 2
        }
    }

    try {
        Write-WatchdogStatus -State "failed" -Reason $message
    }
    catch {
        # The caller will also detect a missing/stale readiness file.
    }
    throw
}
finally {
    if ($null -ne $computer) {
        $computer.Close()
    }
}
