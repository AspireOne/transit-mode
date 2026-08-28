# transit-mode.ps1
# Temporary, reversible low-power mode with a fail-safe temperature watchdog.
# Does not modify Lenovo Fn+Q/Vantage or RyzenAdj/firmware limits.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("on", "off", "status", "diagnose")]
    [string]$Action = "status"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Transit profile ---------------------------------------------------------

$CpuMinPercent = 5
$CpuMaxPercent = 50
$CpuEppPercent = 100
$CpuBoostMode  = 0     # 0 = disabled
$LidAction     = 0     # 0 = do nothing
$SleepTimeout  = 0     # seconds; 0 = never idle-sleep

# ---- Storage -----------------------------------------------------------------

$StateDir  = Join-Path $env:ProgramData "TransitMode"
$StateFile = Join-Path $StateDir "state.json"

$WatchdogTaskName        = "Transit Mode Watchdog"
$WatchdogSourceScript    = Join-Path $PSScriptRoot "transit-watchdog.ps1"
$WatchdogInstalledScript = Join-Path $StateDir "transit-watchdog.ps1"
$WatchdogStatusFile      = Join-Path $StateDir "watchdog-status.json"
$WatchdogLogFile         = Join-Path $StateDir "watchdog.log"
$ThermalLogPattern       = Join-Path $StateDir "thermal-YYYY-MM-DD.csv"
$DiagnosticFile          = Join-Path $StateDir "diagnostic.txt"
$WatchdogStartupTimeout  = 40

$SensorVersion     = "0.9.6"
$SensorDir         = Join-Path $StateDir "lib\v$SensorVersion"
$SensorArchiveUrl  = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v$SensorVersion/LibreHardwareMonitor.zip"
$SensorArchiveHash = "086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001"
$PawnIoVersion      = [version]"2.2.0"
$PawnIoInstallerUrl = "https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe"
$PawnIoInstallerHash = "1f519a22e47187f70a1379a48ca604981c4fcf694f4e65b734aaa74a9fba3032"
$SensorFileHashes  = [ordered]@{
    "LibreHardwareMonitorLib.dll"                = "6ebc194316536ba61af5be24508ad9fcbb2ecc685e716c12e787c79530f66bf0"
    "BlackSharp.Core.dll"                        = "cafb93afcc8d8a367e21f619673d05c06887d8964867fed1371f02ded1cd3e23"
    "DiskInfoToolkit.dll"                        = "1acbf51b3c10c51c986cf43021680d34a2e38d9a5ba652bcfa9a1b5f7fc09800"
    "HidSharp.dll"                               = "d86690efde30ea9179f669320f39148853793b743a98b531afeaf30598e22f54"
    "RAMSPDToolkit-NDD.dll"                      = "b6882354c7c8ec186617e421507743dbfae09c5c1fc24cef76a1d0c0c26651de"
    "System.Buffers.dll"                         = "2d78d770c9cb997199154ae8c018b9f1d1efbc86729f7264dde6dbad2a12cac3"
    "System.Memory.dll"                          = "d5e8e4866f9cfa66f7765660f84b210198893e55335487afe5ebda342c0e913d"
    "System.Numerics.Vectors.dll"                = "20c2fa81b8c70d651099d762954f285fd4f942e63b2d7217c145dab8d4b2f4c9"
    "System.Runtime.CompilerServices.Unsafe.dll" = "08cbd7278b66f1e68425a82d4b97181a4130d93e3dd91831407aba7212ccdacf"
}

# ---- Power setting GUIDs -----------------------------------------------------
# Using documented GUIDs directly avoids relying on localized display names.

$SubProcessor = "54533251-82be-4824-96c1-47b60b740d00"
$SubSleep     = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
$SubButtons   = "4f971e89-eebd-4455-a8de-9e59040e7347"

$SettingCpuMin   = "893dee8e-2bef-41e0-89c6-b55d0929964c"
$SettingCpuMax   = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$SettingCpuEpp   = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"
$SettingCpuBoost = "be337238-0d82-4146-a960-4f3749d470c7"
$SettingLid      = "5ca83367-6e45-459f-a27b-476b1d01c936"
$SettingSleep    = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"

# ---- Helpers -----------------------------------------------------------------

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-StateDirectory {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    $directory = Get-Item -LiteralPath $StateDir -Force
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use reparse-point state directory: '$StateDir'."
    }

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $systemSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $usersSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-545")

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid, "FullControl", $inheritance, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $administratorsSid, "FullControl", $inheritance, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid, "ReadAndExecute", $inheritance, $propagation, $allow))

    Set-Acl -LiteralPath $StateDir -AclObject $acl
}

function Restart-InWindowsPowerShell {
    param([switch]$Elevate)

    if (-not $PSCommandPath) {
        throw "Cannot restart because the script path is unavailable."
    }

    $quotedScript = '"' + $PSCommandPath.Replace('"', '\"') + '"'
    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File $quotedScript $Action"

    if (-not $Elevate) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $Action
        exit $LASTEXITCODE
    }

    $launchedAt = [DateTime]::UtcNow
    $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentLine -Wait -PassThru

    if (($Action -eq "diagnose") -and (Test-Path -LiteralPath $DiagnosticFile)) {
        $diagnostic = Get-Item -LiteralPath $DiagnosticFile
        if ($diagnostic.LastWriteTimeUtc -ge $launchedAt.AddSeconds(-1)) {
            Get-Content -LiteralPath $DiagnosticFile
        }
    }

    exit $process.ExitCode
}

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory)]
        [string[]]$PowerArgs
    )

    $output = & powercfg.exe @PowerArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        throw "powercfg failed ($exitCode): powercfg $($PowerArgs -join ' ')`n$message"
    }

    return @{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-ActiveSchemeGuid {
    $result = Invoke-PowerCfg -PowerArgs @("/getactivescheme")
    $text = ($result.Output | Out-String)

    if ($text -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
        return $Matches[0].ToLowerInvariant()
    }

    throw "Could not determine the active power scheme GUID."
}

function Save-State {
    param([Parameter(Mandatory)] $State)

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    $tempFile = "$StateFile.tmp"
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    $State |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $tempFile -Encoding UTF8

    Move-Item -LiteralPath $tempFile -Destination $StateFile -Force
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }

    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Assert-RecoveryState -State $state
    return $state
}

function Assert-RecoveryState {
    param([Parameter(Mandatory)]$State)

    foreach ($propertyName in @("Version", "Status", "StartedAt", "OriginalScheme", "TransitScheme")) {
        if ($null -eq $State.PSObject.Properties[$propertyName]) {
            throw "Recovery state is missing '$propertyName': $StateFile"
        }
    }

    if ([int]$State.Version -notin @(1, 2)) {
        throw "Unsupported recovery-state version '$($State.Version)': $StateFile"
    }

    if ([string]$State.Status -notin @("activating", "active")) {
        throw "Invalid recovery-state status '$($State.Status)': $StateFile"
    }

    $originalGuid = [guid]::Empty
    $transitGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$State.OriginalScheme, [ref]$originalGuid)) {
        throw "Recovery state has an invalid original-scheme GUID: $StateFile"
    }
    if (-not [guid]::TryParse([string]$State.TransitScheme, [ref]$transitGuid)) {
        throw "Recovery state has an invalid Transit-scheme GUID: $StateFile"
    }
    if ($originalGuid -eq $transitGuid) {
        throw "Recovery state identifies the same scheme as original and temporary: $StateFile"
    }

    if ([int]$State.Version -ge 2) {
        $hibernateProperty = $State.PSObject.Properties["HibernateWasEnabled"]
        if (($null -eq $hibernateProperty) -or ($hibernateProperty.Value -isnot [bool])) {
            throw "Recovery state has an invalid HibernateWasEnabled value: $StateFile"
        }

        $controllerProperty = $State.PSObject.Properties["ControllerProcessId"]
        if (($null -eq $controllerProperty) -or ([int]$controllerProperty.Value -le 0)) {
            throw "Recovery state has an invalid ControllerProcessId value: $StateFile"
        }
    }
}

function Remove-StateArtifacts {
    $tempFile = "$StateFile.tmp"

    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }

    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force
    }

    Remove-Item -LiteralPath $WatchdogStatusFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $StateDir -Filter "watchdog-status.json.*.tmp" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $StateDir) {
        $remaining = Get-ChildItem -LiteralPath $StateDir -Force -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item -LiteralPath $StateDir -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-PowerValue {
    param(
        [Parameter(Mandatory)][string]$Scheme,
        [Parameter(Mandatory)][string]$SubGroup,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][int]$Value
    )

    # Configure both AC and DC so behavior does not change if power is connected/disconnected.
    Invoke-PowerCfg -PowerArgs @("/setacvalueindex", $Scheme, $SubGroup, $Setting, "$Value") | Out-Null
    Invoke-PowerCfg -PowerArgs @("/setdcvalueindex", $Scheme, $SubGroup, $Setting, "$Value") | Out-Null
}

function Test-SchemeExists {
    param([Parameter(Mandatory)][string]$Scheme)

    $result = Invoke-PowerCfg -PowerArgs @("/list")
    $text = ($result.Output | Out-String)
    return $text -match [regex]::Escape($Scheme)
}

function Test-SensorFiles {
    foreach ($entry in $SensorFileHashes.GetEnumerator()) {
        $path = Join-Path $SensorDir $entry.Key
        if (-not (Test-Path -LiteralPath $path)) {
            return $false
        }

        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $entry.Value) {
            return $false
        }
    }

    return $true
}

function Install-SensorLibrary {
    if (Test-SensorFiles) {
        return
    }

    New-Item -ItemType Directory -Path $SensorDir -Force | Out-Null
    $archiveFile = Join-Path $StateDir "LibreHardwareMonitor-v$SensorVersion.zip.download"
    $previousProgressPreference = $ProgressPreference

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $SensorArchiveUrl -OutFile $archiveFile -UseBasicParsing

        $archiveHash = (Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($archiveHash -ne $SensorArchiveHash) {
            throw "LibreHardwareMonitor archive hash mismatch. Expected $SensorArchiveHash; received $archiveHash."
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($archiveFile)
        try {
            foreach ($entry in $SensorFileHashes.GetEnumerator()) {
                $archiveEntry = $archive.GetEntry($entry.Key)
                if ($null -eq $archiveEntry) {
                    throw "LibreHardwareMonitor archive is missing '$($entry.Key)'."
                }

                $destination = Join-Path $SensorDir $entry.Key
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
                [IO.Compression.ZipFileExtensions]::ExtractToFile($archiveEntry, $destination)
            }
        }
        finally {
            $archive.Dispose()
        }

        if (-not (Test-SensorFiles)) {
            throw "LibreHardwareMonitor files failed post-installation verification."
        }
    }
    finally {
        $ProgressPreference = $previousProgressPreference
        Remove-Item -LiteralPath $archiveFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PawnIoInstalledVersion {
    $uninstallKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO"

    foreach ($view in @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $view
        )

        try {
            $key = $baseKey.OpenSubKey($uninstallKey)
            if ($null -eq $key) {
                continue
            }

            try {
                $installedVersion = [version]::new()
                if ([version]::TryParse([string]$key.GetValue("DisplayVersion"), [ref]$installedVersion)) {
                    return $installedVersion
                }
            }
            finally {
                $key.Dispose()
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    return $null
}

function Install-PawnIoDriver {
    $installedVersion = Get-PawnIoInstalledVersion
    if (($null -ne $installedVersion) -and ($installedVersion -ge $PawnIoVersion)) {
        return $installedVersion
    }

    $installerFile = Join-Path $StateDir "PawnIO-v$PawnIoVersion.setup.download.exe"
    $previousProgressPreference = $ProgressPreference

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $PawnIoInstallerUrl -OutFile $installerFile -UseBasicParsing

        $actualHash = (Get-FileHash -LiteralPath $installerFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $PawnIoInstallerHash) {
            throw "PawnIO installer hash mismatch. Expected $PawnIoInstallerHash; received $actualHash."
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $installerFile
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
            throw "PawnIO installer has no valid Authenticode signature: $($signature.StatusMessage)"
        }

        Write-Host "Installing the signed PawnIO v$PawnIoVersion sensor driver..."
        & $installerFile -install -silent
        $installerExitCode = $LASTEXITCODE

        if ($installerExitCode -eq 3010) {
            throw "PawnIO installed successfully, but Windows requires a restart. Restart, then run 'transit-mode diagnose' again."
        }
        if ($installerExitCode -ne 0) {
            throw "PawnIO installation failed with exit code $installerExitCode."
        }

        $installedVersion = Get-PawnIoInstalledVersion
        if (($null -eq $installedVersion) -or ($installedVersion -lt $PawnIoVersion)) {
            throw "PawnIO v$PawnIoVersion installation completed, but the installed version could not be verified."
        }

        return $installedVersion
    }
    finally {
        $ProgressPreference = $previousProgressPreference
        Remove-Item -LiteralPath $installerFile -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-NativePowerApi {
    if ("TransitModeNativePower" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class TransitModeNativePower
{
    [DllImport("powrprof.dll")]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool IsPwrHibernateAllowed();
}
'@
}

function Test-HibernationAvailable {
    Initialize-NativePowerApi
    return [TransitModeNativePower]::IsPwrHibernateAllowed()
}

function Enable-Hibernation {
    Invoke-PowerCfg -PowerArgs @("/hibernate", "/type", "full") | Out-Null
    if (-not (Test-HibernationAvailable)) {
        throw "Windows still reports hibernation as unavailable after enabling it."
    }
}

function Assert-HibernationStorageAvailable {
    $physicalMemory = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop |
        ForEach-Object { [uint64]$_.Capacity } |
        Measure-Object -Sum).Sum

    if ($physicalMemory -le 0) {
        throw "Could not determine installed physical memory before enabling hibernation."
    }

    $systemRoot = [IO.Path]::GetPathRoot([Environment]::SystemDirectory)
    $drive = [IO.DriveInfo]::new($systemRoot)
    $minimumBytes = [uint64][math]::Ceiling($physicalMemory * 0.40)

    if ([uint64]$drive.AvailableFreeSpace -lt $minimumBytes) {
        $freeGiB = $drive.AvailableFreeSpace / 1GB
        $minimumGiB = $minimumBytes / 1GB
        throw ("Hibernation needs a full hibernation file, but {0} has only {1:N1} GiB free; Windows needs at least about {2:N1} GiB for 40% of installed RAM. Free disk space, then run 'transit-mode on' again." -f $systemRoot, $freeGiB, $minimumGiB)
    }
}

function Restore-HibernationState {
    param([Parameter(Mandatory)][bool]$WasEnabled)

    $isEnabled = Test-HibernationAvailable
    if ($WasEnabled -and (-not $isEnabled)) {
        Enable-Hibernation
    }
    elseif (-not $WasEnabled) {
        # Disable unconditionally: a failed enable can leave the registry flag on
        # even though Windows still reports hibernation as unavailable.
        Invoke-PowerCfg -PowerArgs @("/hibernate", "off") | Out-Null
    }
}

function Get-StateHibernateWasEnabled {
    param([Parameter(Mandatory)]$State)

    $property = $State.PSObject.Properties["HibernateWasEnabled"]
    if ($null -eq $property) {
        # Version 1 did not manage hibernation, so it must not disable it on cleanup.
        return $true
    }

    return [bool]$property.Value
}

function Get-WatchdogTask {
    return Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
}

function Remove-WatchdogTask {
    $task = Get-WatchdogTask
    if ($null -eq $task) {
        return
    }

    if ($task.State -in @("Running", "Queued")) {
        Stop-ScheduledTask -TaskName $WatchdogTaskName

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-WatchdogTask
        } while (($null -ne $task) -and ($task.State -in @("Running", "Queued")) -and ([DateTimeOffset]::UtcNow -lt $deadline))

        if (($null -ne $task) -and ($task.State -in @("Running", "Queued"))) {
            throw "The watchdog task did not stop within 10 seconds."
        }
    }

    Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false
}

function Start-Watchdog {
    param([Parameter(Mandatory)][string]$TransitScheme)

    if (-not (Test-Path -LiteralPath $WatchdogSourceScript)) {
        throw "Watchdog script is missing: '$WatchdogSourceScript'."
    }

    Remove-WatchdogTask
    Remove-Item -LiteralPath $WatchdogInstalledScript -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $WatchdogSourceScript -Destination $WatchdogInstalledScript -Force
    Remove-Item -LiteralPath $WatchdogStatusFile -Force -ErrorAction SilentlyContinue

    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArguments =
        "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchdogInstalledScript`" run -ExpectedScheme $TransitScheme"

    $taskAction = New-ScheduledTaskAction `
        -Execute $powerShellExe `
        -Argument $taskArguments `
        -WorkingDirectory $StateDir
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -Hidden `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $WatchdogTaskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -Description "Failsafe CPU-temperature watchdog for Transit Mode." `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $WatchdogTaskName

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WatchdogStartupTimeout)
    do {
        if (Test-Path -LiteralPath $WatchdogStatusFile) {
            try {
                $status = Get-Content -LiteralPath $WatchdogStatusFile -Raw | ConvertFrom-Json
                if (([string]$status.ExpectedScheme).ToLowerInvariant() -eq $TransitScheme.ToLowerInvariant()) {
                    if ([string]$status.State -in @("healthy", "hot")) {
                        return $status
                    }

                    if ([string]$status.State -eq "failed") {
                        throw "Watchdog startup failed: $($status.Reason)"
                    }
                }
            }
            catch [System.ArgumentException] {
                # The atomic status replacement may briefly race with antivirus/file indexing.
            }
        }

        $task = Get-WatchdogTask
        if (($null -eq $task) -or ($task.State -notin @("Running", "Queued"))) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
            $taskResult = "unknown"
            if ($null -ne $taskInfo) {
                $taskResult = [string]$taskInfo.LastTaskResult
            }
            throw "Watchdog exited before becoming healthy. Task result: $taskResult."
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Watchdog did not report a valid CPU temperature within $WatchdogStartupTimeout seconds."
}

function Get-WatchdogHealth {
    $task = $null
    $status = $null

    try {
        $task = Get-WatchdogTask
    }
    catch {
        # Status remains useful when Task Scheduler details are not readable unelevated.
    }

    if (Test-Path -LiteralPath $WatchdogStatusFile) {
        try {
            $status = Get-Content -LiteralPath $WatchdogStatusFile -Raw | ConvertFrom-Json
        }
        catch {
            # A corrupt or partially unavailable file is reported as unhealthy below.
        }
    }

    $isFresh = $false
    if (($null -ne $status) -and ($null -ne $status.PSObject.Properties["UpdatedAt"])) {
        $updatedAt = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$status.UpdatedAt, [ref]$updatedAt)) {
            $isFresh = ([DateTimeOffset]::UtcNow - $updatedAt.ToUniversalTime()).TotalSeconds -le 15
        }
    }

    return [pscustomobject]@{
        Task    = $task
        Status  = $status
        IsFresh = $isFresh
        IsReady = ($null -ne $task) -and
            ($task.State -eq "Running") -and
            $isFresh -and
            ([string]$status.State -in @("healthy", "hot"))
    }
}

# ---- Actions -----------------------------------------------------------------

switch ($Action) {
    "on" {
        # This read-only check gives a useful error in the caller's terminal and
        # avoids a pointless UAC prompt when hibernation cannot fit on disk.
        if ((-not (Test-IsAdministrator)) -and
            (-not (Test-Path -LiteralPath $StateFile)) -and
            (-not (Test-HibernationAvailable))) {
            Assert-HibernationStorageAvailable
        }

        if ($PSVersionTable.PSEdition -ne "Desktop") {
            Restart-InWindowsPowerShell -Elevate:(-not (Test-IsAdministrator))
        }

        if (-not (Test-IsAdministrator)) {
            Restart-InWindowsPowerShell -Elevate
        }

        Initialize-StateDirectory

        if (Test-Path -LiteralPath $StateFile) {
            throw "Transit Mode already has recovery state. Run 'transit-mode off' first."
        }

        Remove-WatchdogTask
        Install-SensorLibrary
        $pawnIoInstalledVersion = Install-PawnIoDriver

        $originalScheme = Get-ActiveSchemeGuid
        $transitScheme  = [guid]::NewGuid().ToString()
        $hibernateWasEnabled = Test-HibernationAvailable

        if (-not $hibernateWasEnabled) {
            Assert-HibernationStorageAvailable
        }

        # Recovery information is persisted BEFORE the temporary plan is activated.
        $state = [ordered]@{
            Version             = 2
            Status              = "activating"
            StartedAt           = (Get-Date).ToString("o")
            OriginalScheme      = $originalScheme
            TransitScheme       = $transitScheme
            HibernateWasEnabled = $hibernateWasEnabled
            WatchdogTask        = $WatchdogTaskName
            ControllerProcessId = $PID
        }
        Save-State $state

        try {
            if (-not $hibernateWasEnabled) {
                Enable-Hibernation
            }

            Invoke-PowerCfg -PowerArgs @("/duplicatescheme", $originalScheme, $transitScheme) | Out-Null

            Invoke-PowerCfg -PowerArgs @(
                "/changename",
                $transitScheme,
                "Transit Mode",
                "Temporary low-power plan created by transit-mode.ps1"
            ) | Out-Null

            Set-PowerValue $transitScheme $SubProcessor $SettingCpuMin   $CpuMinPercent
            Set-PowerValue $transitScheme $SubProcessor $SettingCpuMax   $CpuMaxPercent
            Set-PowerValue $transitScheme $SubProcessor $SettingCpuEpp   $CpuEppPercent
            Set-PowerValue $transitScheme $SubProcessor $SettingCpuBoost $CpuBoostMode
            Set-PowerValue $transitScheme $SubButtons   $SettingLid      $LidAction
            Set-PowerValue $transitScheme $SubSleep     $SettingSleep    $SleepTimeout

            Invoke-PowerCfg -PowerArgs @("/setactive", $transitScheme) | Out-Null

            $watchdogStatus = Start-Watchdog -TransitScheme $transitScheme

            $state.Status = "active"
            Save-State $state

            Write-Host ""
            Write-Host "Transit Mode: ON" -ForegroundColor Green
            Write-Host "  CPU min state  -> $CpuMinPercent%"
            Write-Host "  CPU max state  -> $CpuMaxPercent%"
            Write-Host "  CPU EPP        -> $CpuEppPercent"
            Write-Host "  CPU boost      -> disabled"
            Write-Host "  Lid close      -> do nothing"
            Write-Host "  Idle sleep     -> never"
            Write-Host "  Watchdog       -> $($watchdogStatus.CpuTemperatureC) C"
            Write-Host "  Sensor driver  -> PawnIO v$pawnIoInstalledVersion"
            Write-Host "  Hibernates     -> 80 C sustained / 90 C immediately / sensor failure"
            Write-Host ""
            Write-Host "Original scheme preserved: $originalScheme"
        }
        catch {
            $activationError = $_
            $rollbackErrors = @()
            $watchdogRemoved = $false
            $originalRestored = $false

            try {
                Remove-WatchdogTask
                $watchdogRemoved = $true
            }
            catch {
                $rollbackErrors += "watchdog cleanup: $($_.Exception.Message)"
            }

            try {
                Invoke-PowerCfg -PowerArgs @("/setactive", $originalScheme) | Out-Null
                $originalRestored = $true
            }
            catch {
                $rollbackErrors += "power-plan restoration: $($_.Exception.Message)"
            }

            if ($originalRestored) {
                try {
                    if (Test-SchemeExists $transitScheme) {
                        Invoke-PowerCfg -PowerArgs @("/delete", $transitScheme) | Out-Null
                    }
                }
                catch {
                    $rollbackErrors += "temporary-plan deletion: $($_.Exception.Message)"
                }
            }

            if ($watchdogRemoved -and $originalRestored) {
                try {
                    Restore-HibernationState -WasEnabled $hibernateWasEnabled
                }
                catch {
                    $rollbackErrors += "hibernation restoration: $($_.Exception.Message)"
                }
            }

            if ($rollbackErrors.Count -eq 0) {
                try {
                    Remove-StateArtifacts
                }
                catch {
                    $rollbackErrors += "state cleanup: $($_.Exception.Message)"
                }
            }

            if ($rollbackErrors.Count -gt 0) {
                Write-Warning "Automatic rollback was incomplete. Recovery state was retained at: $StateFile"
                foreach ($rollbackError in $rollbackErrors) {
                    Write-Warning "  $rollbackError"
                }
            }

            throw $activationError
        }
    }

    "off" {
        if ($PSVersionTable.PSEdition -ne "Desktop") {
            Restart-InWindowsPowerShell -Elevate:(-not (Test-IsAdministrator))
        }

        if (-not (Test-IsAdministrator)) {
            Restart-InWindowsPowerShell -Elevate
        }

        if (Test-Path -LiteralPath $StateDir) {
            Initialize-StateDirectory
        }

        $state = Load-State
        if ($null -eq $state) {
            Remove-WatchdogTask
            Write-Host "Transit Mode: OFF"
            return
        }

        $originalScheme = [string]$state.OriginalScheme
        $transitScheme  = [string]$state.TransitScheme
        $hibernateWasEnabled = Get-StateHibernateWasEnabled -State $state

        if (-not (Test-SchemeExists $originalScheme)) {
            throw "Original power scheme '$originalScheme' no longer exists. Recovery state retained at: $StateFile"
        }

        # Stop monitoring before intentionally changing the protected power plan.
        Remove-WatchdogTask

        # Restore first. Do not delete recovery state unless every cleanup step succeeds.
        Invoke-PowerCfg -PowerArgs @("/setactive", $originalScheme) | Out-Null

        if (Test-SchemeExists $transitScheme) {
            Invoke-PowerCfg -PowerArgs @("/delete", $transitScheme) | Out-Null
        }

        Restore-HibernationState -WasEnabled $hibernateWasEnabled
        Remove-StateArtifacts

        Write-Host ""
        Write-Host "Transit Mode: OFF" -ForegroundColor Green
        Write-Host "  Original power scheme restored."
        Write-Host "  Temporary Transit Mode scheme deleted."
        Write-Host "  Watchdog task removed."
        Write-Host "  Original hibernation setting restored."
        Write-Host "  Recovery state removed."
        Write-Host "  Thermal history retained: $ThermalLogPattern"
    }

    "status" {
        if ($PSVersionTable.PSEdition -ne "Desktop") {
            Restart-InWindowsPowerShell
        }

        $state = Load-State
        $activeScheme = Get-ActiveSchemeGuid
        $watchdog = Get-WatchdogHealth

        if ($null -eq $state) {
            Write-Host "Transit Mode: OFF"
            Write-Host "Active scheme: $activeScheme"
            Write-Host "Thermal history: $ThermalLogPattern"
            if ($null -ne $watchdog.Task) {
                Write-Host "Warning: stale watchdog task exists." -ForegroundColor Yellow
                exit 2
            }
            return
        }

        $isTransitActive = $activeScheme -eq ([string]$state.TransitScheme).ToLowerInvariant()
        $isProtected = $isTransitActive -and $watchdog.IsReady

        if ($isProtected) {
            Write-Host "Transit Mode: ON (WATCHDOG HEALTHY)" -ForegroundColor Green
        }
        elseif (($null -ne $watchdog.Status) -and ([string]$watchdog.Status.State -eq "resumed-after-emergency")) {
            Write-Host "Transit Mode: EMERGENCY HIBERNATION OCCURRED" -ForegroundColor Yellow
        }
        else {
            Write-Host "Transit Mode: UNPROTECTED / RECOVERY REQUIRED" -ForegroundColor Red
        }

        Write-Host "State:            $($state.Status)"
        Write-Host "Started:          $($state.StartedAt)"
        Write-Host "Active scheme:    $activeScheme"
        Write-Host "Original scheme:  $($state.OriginalScheme)"
        Write-Host "Transit scheme:   $($state.TransitScheme)"

        if ($null -ne $watchdog.Task) {
            Write-Host "Watchdog task:    $($watchdog.Task.State)"
        }
        else {
            Write-Host "Watchdog task:    missing"
        }

        if ($null -ne $watchdog.Status) {
            Write-Host "Watchdog state:   $($watchdog.Status.State)"
            Write-Host "CPU temperature:  $($watchdog.Status.CpuTemperatureC) C"
            Write-Host "Last reading:     $($watchdog.Status.UpdatedAt)"
            if ($watchdog.Status.Reason) {
                Write-Host "Watchdog reason:  $($watchdog.Status.Reason)"
            }
        }
        else {
            Write-Host "Watchdog status:  missing"
        }

        Write-Host "Recovery file:    $StateFile"
        Write-Host "Watchdog log:     $WatchdogLogFile"
        Write-Host "Thermal history:  $ThermalLogPattern"

        if (-not $isProtected) {
            exit 2
        }
    }

    "diagnose" {
        if ($PSVersionTable.PSEdition -ne "Desktop") {
            Restart-InWindowsPowerShell -Elevate:(-not (Test-IsAdministrator))
        }

        if (-not (Test-IsAdministrator)) {
            Restart-InWindowsPowerShell -Elevate
        }

        $diagnosticLines = @(
            "Transit Mode watchdog diagnostic"
        )

        try {
            Initialize-StateDirectory

            if (-not (Test-Path -LiteralPath $WatchdogSourceScript)) {
                throw "Watchdog script is missing: '$WatchdogSourceScript'."
            }

            Install-SensorLibrary
            $diagnosticLines += "  LibreHardwareMonitor: v$SensorVersion (verified)"

            $pawnIoInstalledVersion = Install-PawnIoDriver
            $diagnosticLines += "  PawnIO sensor driver: v$pawnIoInstalledVersion (installed)"
            $diagnosticLines += "  Hibernation currently available: $(Test-HibernationAvailable)"
            $diagnosticLines += @(& $WatchdogSourceScript probe)
            $diagnosticLines | Set-Content -LiteralPath $DiagnosticFile -Encoding UTF8
            $diagnosticLines | ForEach-Object { Write-Host $_ }
        }
        catch {
            $diagnosticLines += "  FAILED: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $StateDir) {
                $diagnosticLines | Set-Content -LiteralPath $DiagnosticFile -Encoding UTF8
            }
            throw
        }
    }
}
