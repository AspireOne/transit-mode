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
$WatchdogInstalledConfig = Join-Path $StateDir "transit-watchdog.config.json"

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

$SettingCpuMin     = "893dee8e-2bef-41e0-89c6-b55d0929964c"
$SettingCpuMax     = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$SettingCpuEpp     = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"
$SettingCpuBoost   = "be337238-0d82-4146-a960-4f3749d470c7"
$SettingLid        = "5ca83367-6e45-459f-a27b-476b1d01c936"
$SettingSleep      = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
$SettingWakeTimers = "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d"

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

    if (-not $Elevate) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $Action
        exit $LASTEXITCODE
    }

    $resultFile = [IO.Path]::GetTempFileName()
    try {
        $scriptLiteral = "'" + $PSCommandPath.Replace("'", "''") + "'"
        $resultLiteral = "'" + $resultFile.Replace("'", "''") + "'"
        $command = @"
try {
    & $scriptLiteral $Action *> $resultLiteral
    exit 0
} catch {
    (`$_ | Out-String) + `$_.ScriptStackTrace | Add-Content -LiteralPath $resultLiteral
    exit 1
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $process = Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Wait -PassThru
        $output = Get-Content -LiteralPath $resultFile -Raw
        if ($output) { Write-Host $output.TrimEnd() }
        if ($process.ExitCode -ne 0) {
            throw "Transit Mode '$Action' failed (exit $($process.ExitCode)). See the error above."
        }
    }
    finally {
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

function Enter-ControllerLock {
    try {
        return [IO.File]::Open((Join-Path $StateDir "controller.lock"),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw "Another Transit Mode operation is running, or its lock is unavailable: $($_.Exception.Message)"
    }
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

    if (Test-Path -LiteralPath $StateFile) {
        [IO.File]::Replace($tempFile, $StateFile, [NullString]::Value)
    }
    else {
        [IO.File]::Move($tempFile, $StateFile)
    }
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

    if ([int]$State.Version -notin @(1, 2, 3)) {
        throw "Unsupported recovery-state version '$($State.Version)': $StateFile"
    }

    if ([string]$State.Status -notin @("activating", "active", "stopping")) {
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

function Grant-WatchdogTaskReadAccess {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $task = $scheduler.GetFolder("\").GetTask($WatchdogTaskName)
    # Task Scheduler can return a noncanonical DACL. Preserve its entries and
    # ordering: CommonSecurityDescriptor.AddAccess refuses to edit such ACLs.
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        $task.GetSecurityDescriptor(4))
    $readAccess = [Security.AccessControl.CommonAce]::new(
        [Security.AccessControl.AceFlags]::None,
        [Security.AccessControl.AceQualifier]::AccessAllowed,
        [int]::MinValue,
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        $false, $null)
    $descriptor.DiscretionaryAcl.InsertAce($descriptor.DiscretionaryAcl.Count, $readAccess)
    $task.SetSecurityDescriptor(
        $descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::Access), 0)
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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "transit-config.ps1") -Destination $StateDir -Force
    # Serialize the validated in-memory settings, not a possibly edited source file.
    $WatchdogConfig | ConvertTo-Json | Set-Content -LiteralPath $WatchdogInstalledConfig -Encoding UTF8
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

    Grant-WatchdogTaskReadAccess
    Start-ScheduledTask -TaskName $WatchdogTaskName

    return Wait-Watchdog -TransitScheme $TransitScheme -States @("armed")
}

function Wait-Watchdog {
    param([string]$TransitScheme, [string[]]$States)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $health = Get-WatchdogHealth -ExpectedScheme $TransitScheme
        if ($health.IsFresh -and $null -ne $health.Task -and
            $health.Task.State -eq "Running" -and $health.Status.State -in $States) {
            return $health.Status
        }
        if ($null -ne $health.Status -and $health.Status.State -in @("failed", "hibernating", "resumed-after-emergency")) {
            throw "Watchdog startup failed: $($health.Status.Reason)"
        }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt $WatchdogStartupTimeout)

    throw "Watchdog did not reach '$($States -join ', ')' within $WatchdogStartupTimeout seconds. $($health.Reason)"
}

function Restore-TransitSession {
    param([Parameter(Mandatory)]$State)

    if (-not (Test-SchemeExists $State.OriginalScheme)) {
        throw "Original power scheme '$($State.OriginalScheme)' no longer exists. Recovery state retained at: $StateFile"
    }
    $State.Status = "stopping"
    Save-State $State
    # The worker keeps monitoring while Transit is active, and exits when the
    # saved original plan is restored. Never stop it before restoring that plan.
    Invoke-PowerCfg -PowerArgs @("/setactive", $State.OriginalScheme) | Out-Null
    if ((Get-ActiveSchemeGuid) -ne $State.OriginalScheme) {
        throw "Original power scheme was not restored. Watchdog and recovery state retained."
    }
    Remove-WatchdogTask
    if (Test-SchemeExists $State.TransitScheme) {
        Invoke-PowerCfg -PowerArgs @("/delete", $State.TransitScheme) | Out-Null
    }
    # New sessions never change hibernation. Preserve recovery for older sessions.
    if ([int]$State.Version -lt 3) {
        Restore-HibernationState -WasEnabled (Get-StateHibernateWasEnabled $State)
    }
    Remove-StateArtifacts
}

function Get-WatchdogHealth {
    param([string]$ExpectedScheme)

    $task = $null
    $status = $null
    $isFresh = $false
    $reason = "Watchdog status is missing."
    try { $task = Get-WatchdogTask } catch { }
    if (Test-Path -LiteralPath $WatchdogStatusFile) {
        try {
            $status = Get-Content -LiteralPath $WatchdogStatusFile -Raw | ConvertFrom-Json
            foreach ($name in @("UpdatedAt", "State", "ExpectedScheme", "PollIntervalSeconds", "CpuTemperatureC", "Reason")) {
                if ($null -eq $status.PSObject.Properties[$name]) { throw "Status is missing '$name'." }
            }
            $interval = $status.PollIntervalSeconds
            if (($interval -isnot [int] -and $interval -isnot [long]) -or $interval -le 0) {
                throw "Status has an invalid polling interval."
            }
            if ($status.State -notin @("starting", "armed", "healthy", "hot", "sensor-missing", "hibernating", "resumed-after-emergency", "failed")) {
                throw "Status has an invalid watchdog state."
            }
            if ($status.State -in @("armed", "healthy", "hot")) {
                $temperature = $status.CpuTemperatureC
                if (($temperature -isnot [int] -and $temperature -isnot [long] -and $temperature -isnot [double]) -or
                    [double]::IsNaN($temperature) -or $temperature -le 0 -or $temperature -gt 200) {
                    throw "Status has no valid CPU temperature."
                }
            }
            $updatedAt = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$status.UpdatedAt, [ref]$updatedAt)) {
                throw "Status has an invalid timestamp."
            }
            if (-not $ExpectedScheme -or $status.ExpectedScheme -ne $ExpectedScheme) {
                throw "Status does not belong to the current Transit session."
            }
            $age = ([DateTimeOffset]::UtcNow - $updatedAt).TotalSeconds
            $isFresh = $age -ge 0 -and $age -le ([double]$interval * 3)
            $reason = if ($isFresh) { "Watchdog is not reporting healthy monitoring." } else { "Watchdog heartbeat is stale or future-dated." }
        }
        catch {
            $status = $null
            $reason = "Invalid watchdog status: $($_.Exception.Message)"
        }
    }
    $isReady = $null -ne $task -and $task.State -eq "Running" -and
        $isFresh -and $null -ne $status -and $status.State -in @("healthy", "hot")
    if ($isReady) { $reason = $null }
    return [pscustomobject]@{
        Task = $task; Status = $status; IsFresh = $isFresh; IsReady = $isReady; Reason = $reason
    }
}

# ---- Actions -----------------------------------------------------------------

# Recovery and status must work even when editable configuration is broken.
if ($Action -in @("on", "diagnose")) {
    . (Join-Path $PSScriptRoot "transit-config.ps1")
    $ModeConfig = Read-TransitConfig -Path (Join-Path $PSScriptRoot "transit-mode.config.json") -Kind mode
    $WatchdogConfig = Read-TransitConfig -Path (Join-Path $PSScriptRoot "transit-watchdog.config.json") -Kind watchdog
    Assert-TransitStartupTiming -Mode $ModeConfig -Watchdog $WatchdogConfig

    $CpuMinPercent = $ModeConfig.cpuMinPercent
    $CpuMaxPercent = $ModeConfig.cpuMaxPercent
    $CpuEppPercent = $ModeConfig.cpuEppPercent
    $CpuBoostMode = $ModeConfig.cpuBoostMode
    $LidAction = $ModeConfig.lidAction
    $SleepTimeout = $ModeConfig.sleepTimeoutSeconds
    $WakeTimers = $ModeConfig.wakeTimers
    $WatchdogStartupTimeout = $ModeConfig.watchdogStartupTimeoutSeconds
}

if ($PSVersionTable.PSEdition -ne "Desktop") {
    Restart-InWindowsPowerShell -Elevate:($Action -ne "status" -and -not (Test-IsAdministrator))
}
if ($Action -ne "status" -and -not (Test-IsAdministrator)) {
    Restart-InWindowsPowerShell -Elevate
}

$controllerLock = $null
try {
    if ($Action -ne "status") {
        Initialize-StateDirectory
        $controllerLock = Enter-ControllerLock
    }
switch ($Action) {
    "on" {
        if (Test-Path -LiteralPath $StateFile) {
            throw "Transit Mode already has recovery state. Run 'transit-mode off' first."
        }

        if (-not (Test-HibernationAvailable)) {
            throw "Full hibernation is required. In an administrator terminal run 'powercfg /hibernate /type full', then retry. Transit Mode does not change this setting."
        }
        Remove-WatchdogTask
        Install-SensorLibrary
        $pawnIoInstalledVersion = Install-PawnIoDriver

        $originalScheme = Get-ActiveSchemeGuid
        $transitScheme  = [guid]::NewGuid().ToString()

        # Recovery information is persisted BEFORE the temporary plan is activated.
        $state = [ordered]@{
            Version             = 3
            Status              = "activating"
            StartedAt           = (Get-Date).ToString("o")
            OriginalScheme      = $originalScheme
            TransitScheme       = $transitScheme
            HibernateWasEnabled = $true
            WatchdogTask        = $WatchdogTaskName
            ControllerProcessId = $PID
        }
        Save-State $state

        try {
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
            Set-PowerValue $transitScheme $SubButtons   $SettingLid        $LidAction
            Set-PowerValue $transitScheme $SubSleep     $SettingSleep      $SleepTimeout
            Set-PowerValue $transitScheme $SubSleep     $SettingWakeTimers $WakeTimers

            # Arm independent monitoring before changing the active plan.
            Start-Watchdog -TransitScheme $transitScheme | Out-Null
            Invoke-PowerCfg -PowerArgs @("/setactive", $transitScheme) | Out-Null
            $watchdogStatus = Wait-Watchdog -TransitScheme $transitScheme -States @("healthy", "hot")

            $state.Status = "active"
            Save-State $state

            Write-Host ""
            Write-Host "Transit Mode: ON" -ForegroundColor Green
            Write-Host "  CPU min state  -> $CpuMinPercent%"
            Write-Host "  CPU max state  -> $CpuMaxPercent%"
            Write-Host "  CPU EPP        -> $CpuEppPercent"
            Write-Host "  CPU boost mode -> $CpuBoostMode (0 = disabled)"
            Write-Host "  Lid action     -> $LidAction (0 = do nothing)"
            Write-Host "  Idle sleep     -> $SleepTimeout seconds (0 = never)"
            Write-Host "  Wake timers    -> $WakeTimers (0 = disabled)"
            Write-Host "  Watchdog       -> $($watchdogStatus.CpuTemperatureC) C"
            Write-Host "  Sensor driver  -> PawnIO v$pawnIoInstalledVersion"
            Write-Host "  Hibernates     -> $($watchdogStatus.SustainedLimitC) C hot band for $($watchdogStatus.SustainedSeconds) s / $($watchdogStatus.CriticalLimitC) C immediately / sensor missing $($watchdogStatus.SensorFailureGrace) s"
            Write-Host ""
            Write-Host "Original scheme preserved: $originalScheme"
        }
        catch {
            $activationError = $_
            try { Restore-TransitSession -State $state }
            catch {
                Write-Warning "Automatic rollback was incomplete: $($_.Exception.Message). Recovery state retained at: $StateFile"
            }
            throw $activationError
        }
    }

    "off" {
        $state = Load-State
        if ($null -eq $state) {
            Remove-WatchdogTask
            Write-Host "Transit Mode: OFF"
            return
        }

        Restore-TransitSession -State $state

        Write-Host ""
        Write-Host "Transit Mode: OFF" -ForegroundColor Green
        Write-Host "  Original power scheme restored."
        Write-Host "  Temporary Transit Mode scheme deleted."
        Write-Host "  Watchdog task removed."
        Write-Host "  Hibernation configuration preserved (legacy sessions restored)."
        Write-Host "  Recovery state removed."
        Write-Host "  Thermal history retained: $ThermalLogPattern"
    }

    "status" {
        $state = Load-State
        $activeScheme = Get-ActiveSchemeGuid
        $expectedScheme = if ($null -ne $state) { [string]$state.TransitScheme } else { $null }
        $watchdog = Get-WatchdogHealth -ExpectedScheme $expectedScheme

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
            Write-Host "Watchdog status:  $($watchdog.Reason)"
        }

        Write-Host "Recovery file:    $StateFile"
        Write-Host "Watchdog log:     $WatchdogLogFile"
        Write-Host "Thermal history:  $ThermalLogPattern"

        if (-not $isProtected) {
            exit 2
        }
    }

    "diagnose" {
        $diagnosticLines = @(
            "Transit Mode watchdog diagnostic"
        )

        try {
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

}
finally {
    if ($null -ne $controllerLock) { $controllerLock.Dispose() }
}
