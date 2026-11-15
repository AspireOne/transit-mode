$repo = Split-Path $PSScriptRoot -Parent

# Controller definitions without its actions. Dot-source them with -Action.
function Get-ControllerSetupText {
    $source = Get-Content (Join-Path $repo "transit-mode.ps1") -Raw
    $setup = $source.Substring(0, $source.IndexOf('# ---- Actions'))
    return $setup.Replace('$PSScriptRoot', "'" + $repo.Replace("'", "''") + "'")
}

Describe "Controller reliability" {
    # Define functions once, before Pester installs mock wrappers.
    $setup = Get-ControllerSetupText
    . ([scriptblock]::Create($setup)) -Action status
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "transit-mode.ps1"), [ref]$tokens, [ref]$errors)
    $actions = $ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true)

    BeforeEach {
        $StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        $StateFile = Join-Path $StateDir "state.json"
        $WatchdogStatusFile = Join-Path $StateDir "watchdog-status.json"
        $state = [pscustomobject]@{
            Version = 3; Status = "active"; StartedAt = "2026-09-28T00:00:00Z"
            OriginalScheme = "11111111-1111-1111-1111-111111111111"
            TransitScheme = "22222222-2222-2222-2222-222222222222"
            HibernateWasEnabled = $true; ControllerProcessId = $PID
        }
        $script:activeScheme = $state.TransitScheme
        $script:watchdogRunning = $true
        Mock Test-SchemeExists { $true }
        Mock Get-ActiveSchemeGuid { $script:activeScheme }
        Mock Invoke-PowerCfg {
            if ($PowerArgs[0] -eq "/setactive") { $script:activeScheme = $PowerArgs[1] }
        }
        Mock Remove-WatchdogTask {
            if ($script:activeScheme -ne $state.OriginalScheme) { throw "Watchdog stopped before restoration" }
            $script:watchdogRunning = $false
        }
        Mock Restore-HibernationState {}
        Mock Get-WatchdogTask { [pscustomobject]@{ State = "Running" } }
        Mock Install-SensorLibrary {}
        Mock Install-PawnIoDriver { [version]"2.2.0" }
        Mock Test-HibernationAvailable { $true }
        Mock Set-PowerValue {}
        Mock Start-Watchdog {
            if ($script:activeScheme -ne $state.OriginalScheme) { throw "Transit activated before arming" }
            $script:watchdogRunning = $true
        }
        Mock Wait-Watchdog {
            if (-not $script:watchdogRunning) { throw "No watchdog" }
            [pscustomobject]@{ CpuTemperatureC = 45; SustainedLimitC = 80; SustainedSeconds = 30; CriticalLimitC = 82; SensorFailureGrace = 22 }
        }
        $CpuMinPercent = 5; $CpuMaxPercent = 45; $CpuEppPercent = 100; $CpuBoostMode = 0
        $LidAction = 0; $SleepTimeout = 0; $WakeTimers = 0
    }

    It "restores the original plan before removing protection and recovery data" {
        Save-State $state
        Restore-TransitSession $state
        $script:activeScheme | Should Be $state.OriginalScheme
        $script:watchdogRunning | Should Be $false
        Test-Path $StateFile | Should Be $false
        Assert-MockCalled Restore-HibernationState -Scope It -Times 0 -Exactly
    }

    It "keeps the watchdog and recovery state when restoring the plan fails" {
        Mock Invoke-PowerCfg { throw "Injected restoration failure" }
        { Restore-TransitSession $state } | Should Throw "Injected restoration failure"
        $script:watchdogRunning | Should Be $true
        $script:activeScheme | Should Be $state.TransitScheme
        (Load-State).Status | Should Be "stopping"
        Assert-MockCalled Remove-WatchdogTask -Scope It -Times 0 -Exactly
    }

    It "does not trust a successful powercfg exit without the requested plan" {
        Mock Invoke-PowerCfg {}
        { Restore-TransitSession $state } | Should Throw "was not restored"
        $script:watchdogRunning | Should Be $true
        Test-Path $StateFile | Should Be $true
    }

    It "retains recoverable state with the original plan active if task cleanup fails" {
        Mock Remove-WatchdogTask { throw "Injected task cleanup failure" }
        { Restore-TransitSession $state } | Should Throw "Injected task cleanup failure"
        $script:activeScheme | Should Be $state.OriginalScheme
        (Load-State).Status | Should Be "stopping"
        Assert-MockCalled Invoke-PowerCfg -Scope It -Times 0 -Exactly -ParameterFilter { $PowerArgs[0] -eq "/delete" }
    }

    It "still restores hibernation for an older saved session" {
        $state.Version = 2
        $state.HibernateWasEnabled = $false
        Restore-TransitSession $state
        Assert-MockCalled Restore-HibernationState -Scope It -Times 1 -Exactly -ParameterFilter { -not $WasEnabled }
    }

    It "rejects an overlapping controller and releases the lock on disposal" {
        $first = Enter-ControllerLock
        try { { Enter-ControllerLock } | Should Throw "Another Transit Mode operation" }
        finally { $first.Dispose() }
        $second = Enter-ControllerLock
        $second.Dispose()
    }

    It "arms monitoring before activating the temporary plan" {
        $Action = "on"
        $script:activeScheme = $state.OriginalScheme
        . ([scriptblock]::Create($actions.Extent.Text))
        $saved = Load-State
        $saved.Status | Should Be "active"
        $saved.Version | Should Be 3
        $script:activeScheme | Should Be $saved.TransitScheme
        $script:watchdogRunning | Should Be $true
    }

    It "leaves the original plan active when arming fails" {
        $Action = "on"
        $script:activeScheme = $state.OriginalScheme
        Mock Start-Watchdog { throw "Injected arming failure" }
        { . ([scriptblock]::Create($actions.Extent.Text)) } | Should Throw "Injected arming failure"
        $script:activeScheme | Should Be $state.OriginalScheme
        Test-Path $StateFile | Should Be $false
        Assert-MockCalled Invoke-PowerCfg -Scope It -Times 0 -Exactly -ParameterFilter {
            $PowerArgs[0] -eq "/setactive" -and $PowerArgs[1] -ne $state.OriginalScheme
        }
    }

    It "rolls back when activation is stopped during <Step>" -TestCases @(
        @{ Step = "Start-Watchdog" }, @{ Step = "Wait-Watchdog" }
    ) {
        param($Step)
        $sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        $events = Join-Path $sandbox "events.txt"
        # Ctrl+C stops the pipeline, which skips catch blocks but runs finally
        # blocks. Pester mocks cannot cross runspaces, so replace the system
        # boundaries with plain functions after the real definitions.
        $boundaries = @'
$StateDir = $Sandbox
$StateFile = Join-Path $Sandbox "state.json"
$WatchdogStatusFile = Join-Path $Sandbox "watchdog-status.json"
$events = Join-Path $Sandbox "events.txt"
$global:activeScheme = "11111111-1111-1111-1111-111111111111"
function Test-HibernationAvailable { $true }
function Install-SensorLibrary {}
function Install-PawnIoDriver { [version]"2.2.0" }
function Set-PowerValue {}
function Test-SchemeExists { $true }
function Get-ActiveSchemeGuid { $global:activeScheme }
function Invoke-PowerCfg {
    param([string[]]$PowerArgs)
    if ($PowerArgs[0] -eq "/setactive") {
        $global:activeScheme = $PowerArgs[1]
        Add-Content $events "setactive:$($PowerArgs[1])"
    }
}
function Remove-WatchdogTask { Add-Content $events "remove-task:$global:activeScheme" }
function Wait-ForInterruption { Add-Content $events "waiting:$InterruptAt"; Start-Sleep -Seconds 60 }
function Start-Watchdog { if ($InterruptAt -eq "Start-Watchdog") { Wait-ForInterruption } }
function Wait-Watchdog { if ($InterruptAt -eq "Wait-Watchdog") { Wait-ForInterruption } }
$Action = "on"
$CpuMinPercent = 5; $CpuMaxPercent = 45; $CpuEppPercent = 100; $CpuBoostMode = 0
$LidAction = 0; $SleepTimeout = 0; $WakeTimers = 0
'@
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable("Sandbox", $sandbox)
        $runspace.SessionStateProxy.SetVariable("InterruptAt", $Step)
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        try {
            $null = $ps.AddScript($setup + "`n" + $boundaries + "`n" + $actions.Extent.Text)
            $handle = $ps.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not ((Test-Path $events) -and (Get-Content $events) -contains "waiting:$Step")) {
                if ($handle.IsCompleted -or [DateTime]::UtcNow -gt $deadline) {
                    throw "Activation did not reach $Step. Errors: $($ps.Streams.Error | Out-String)"
                }
                Start-Sleep -Milliseconds 50
            }

            $ps.Stop()

            $ps.InvocationStateInfo.State | Should Be "Stopped"
        }
        finally {
            $ps.Dispose()
            $runspace.Dispose()
        }
        $log = @(Get-Content $events)
        $original = "11111111-1111-1111-1111-111111111111"
        # Restore the original plan before removing monitoring, then clean up.
        $log[-2] | Should Be "setactive:$original"
        $log[-1] | Should Be "remove-task:$original"
        Test-Path (Join-Path $sandbox "state.json") | Should Be $false
    }

    It "shows and saves partial diagnose results when a step fails" {
        $Action = "diagnose"
        $DiagnosticFile = Join-Path $StateDir "diagnostic.txt"
        Mock Install-PawnIoDriver { throw "Injected driver failure" }
        $script:shown = @()
        Mock Write-Host { $script:shown += [string]$Object }

        { . ([scriptblock]::Create($actions.Extent.Text)) } | Should Throw "Injected driver failure"

        $expected = @(
            "Transit Mode watchdog diagnostic"
            "  LibreHardwareMonitor: v$SensorVersion (verified)"
            "  FAILED: Injected driver failure"
        )
        ($script:shown -join "|") | Should Be ($expected -join "|")
        (@(Get-Content $DiagnosticFile) -join "|") | Should Be ($expected -join "|")
    }

    It "rejects unavailable full hibernation before changing system settings" {
        $Action = "on"
        Mock Test-HibernationAvailable { $false }
        { . ([scriptblock]::Create($actions.Extent.Text)) } | Should Throw "Full hibernation is required"
        Assert-MockCalled Invoke-PowerCfg -Scope It -Times 0 -Exactly
        Assert-MockCalled Install-SensorLibrary -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-WatchdogTask -Scope It -Times 0 -Exactly
        Test-Path $StateFile | Should Be $false
    }

    It "replaces saved state without losing recovery fields" {
        Save-State $state
        $state.Status = "stopping"
        Save-State $state
        $loaded = Load-State
        $loaded.Status | Should Be "stopping"
        $loaded.OriginalScheme | Should Be $state.OriginalScheme
        Test-Path "$StateFile.tmp" | Should Be $false
    }

    It "accepts fractional CPU temperatures from armed and monitoring heartbeats" {
        foreach ($phase in @("armed", "healthy")) {
            $heartbeat = @{
                State = $phase; UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                ExpectedScheme = $state.TransitScheme; PollIntervalSeconds = 5
                CpuTemperatureC = 46.4; Reason = $null
            }
            $heartbeat | ConvertTo-Json | Set-Content $WatchdogStatusFile

            $health = Get-WatchdogHealth -ExpectedScheme $state.TransitScheme

            $health.IsFresh | Should Be $true
            $health.Status.State | Should Be $phase
            $health.Status.CpuTemperatureC | Should Be 46.4
            $health.IsReady | Should Be ($phase -eq "healthy")
        }
    }

    It "rejects future, stale, foreign, and incomplete heartbeats" {
        foreach ($kind in @("future", "stale", "foreign", "incomplete", "invalid-temperature")) {
            $heartbeat = @{
                State = "healthy"; UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                ExpectedScheme = $state.TransitScheme; PollIntervalSeconds = 5
                CpuTemperatureC = 45; Reason = $null
            }
            switch ($kind) {
                future { $heartbeat.UpdatedAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString("o") }
                stale { $heartbeat.UpdatedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("o") }
                foreign { $heartbeat.ExpectedScheme = $state.OriginalScheme }
                incomplete { $heartbeat.Remove("State") }
                invalid-temperature { $heartbeat.CpuTemperatureC = $null }
            }
            $heartbeat | ConvertTo-Json | Set-Content $WatchdogStatusFile
            $health = Get-WatchdogHealth -ExpectedScheme $state.TransitScheme
            $health.IsReady | Should Be $false
            [string]::IsNullOrEmpty($health.Reason) | Should Be $false
        }
    }
}

Describe "PawnIO installation" {
    . ([scriptblock]::Create((Get-ControllerSetupText))) -Action status

    # PawnIO_setup.exe is a GUI-subsystem program, which PowerShell's '&' does
    # not wait for. This windowless stand-in has the same subsystem.
    $stub = Join-Path $TestDrive "installer-stub.exe"
    Add-Type -OutputType WindowsApplication -OutputAssembly $stub -TypeDefinition @'
public static class InstallerStub
{
    public static int Main(string[] args)
    {
        System.Threading.Thread.Sleep(1500);
        System.IO.File.WriteAllText(
            System.Environment.GetEnvironmentVariable("TRANSIT_TEST_INSTALLER_ARGS"),
            string.Join(" ", args));
        return int.Parse(System.Environment.GetEnvironmentVariable("TRANSIT_TEST_INSTALLER_EXIT"));
    }
}
'@

    BeforeEach {
        $StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $StateDir | Out-Null
        $argsFile = Join-Path $StateDir "installer-args.txt"
        $env:TRANSIT_TEST_INSTALLER_ARGS = $argsFile
        $script:versionQueries = 0
        # Missing before installation, present afterwards.
        Mock Get-PawnIoInstalledVersion {
            $script:versionQueries++
            if ($script:versionQueries -gt 1) { [version]"2.2.0" }
        }
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $stub -Destination $OutFile }
        Mock Get-FileHash { [pscustomobject]@{ Hash = $PawnIoInstallerHash.ToUpperInvariant() } }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]::Valid; StatusMessage = "" }
        }
        Mock Write-Host {}
    }

    AfterEach {
        Remove-Item Env:\TRANSIT_TEST_INSTALLER_ARGS, Env:\TRANSIT_TEST_INSTALLER_EXIT -ErrorAction SilentlyContinue
    }

    It "waits for the installer before verifying the installed version" {
        $env:TRANSIT_TEST_INSTALLER_EXIT = "0"
        $timer = [Diagnostics.Stopwatch]::StartNew()

        Install-PawnIoDriver | Should Be ([version]"2.2.0")

        ($timer.Elapsed.TotalSeconds -ge 1.4) | Should Be $true
        Get-Content $argsFile | Should Be "-install -silent"
        # A finished installer no longer locks its download, so cleanup succeeds.
        Test-Path (Join-Path $StateDir "PawnIO-v$PawnIoVersion.setup.download.exe") | Should Be $false
    }

    It "reports the installer's restart-required exit code" {
        $env:TRANSIT_TEST_INSTALLER_EXIT = "3010"

        { Install-PawnIoDriver } | Should Throw "requires a restart"
    }

    It "reports other installer exit codes" {
        $env:TRANSIT_TEST_INSTALLER_EXIT = "5"

        { Install-PawnIoDriver } | Should Throw "failed with exit code 5"
    }
}

Describe "Watchdog task lookup" {
    . ([scriptblock]::Create((Get-ControllerSetupText))) -Action status

    It "returns nothing for a missing task through the real Task Scheduler" {
        $WatchdogTaskName = "Transit Mode test $([guid]::NewGuid())"

        Get-WatchdogTask | Should BeNullOrEmpty
    }

    Context "Task Scheduler COM boundary" {
        BeforeEach {
            $folder = [pscustomobject]@{ Task = $null; Failure = $null }
            $folder | Add-Member ScriptMethod GetTask {
                param($name)
                if ($this.Failure) { throw $this.Failure }
                $this.Task
            }
            $scheduler = [pscustomobject]@{ Folder = $folder }
            $scheduler | Add-Member ScriptMethod Connect {}
            $scheduler | Add-Member ScriptMethod GetFolder { param($path) $this.Folder }
            Mock New-Object { $scheduler } -ParameterFilter { $ComObject -eq "Schedule.Service" }
        }

        It "names COM task state <Value> as <Name>" -TestCases @(
            @{ Value = 0; Name = "Unknown" }, @{ Value = 1; Name = "Disabled" },
            @{ Value = 2; Name = "Queued" }, @{ Value = 3; Name = "Ready" },
            @{ Value = 4; Name = "Running" }
        ) {
            param($Value, $Name)
            $folder.Task = [pscustomobject]@{ State = $Value }

            (Get-WatchdogTask).State | Should BeExactly $Name
        }

        It "fails loudly on an unknown task state" {
            $folder.Task = [pscustomobject]@{ State = 9 }

            { Get-WatchdogTask } | Should Throw "Unknown watchdog task state '9'"
        }

        It "fails loudly on Task Scheduler errors other than a missing task" {
            $folder.Failure = [UnauthorizedAccessException]::new("Injected access failure")

            { Get-WatchdogTask } | Should Throw "Injected access failure"
        }
    }
}

Describe "Elevated output relay" {
    . ([scriptblock]::Create((Get-ControllerSetupText))) -Action status

    # As in Restart-InWindowsPowerShell, minus elevation: an empty temp file and
    # the real captured command around a stand-in script. Returns the exit code.
    function Invoke-CapturedScript {
        param([Parameter(Mandatory)][string]$Body)

        $resultFile = Join-Path $TestDrive "result-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllBytes($resultFile, [byte[]]@())
        $scriptPath = Join-Path $TestDrive "it's a script.ps1"
        Set-Content $scriptPath $Body
        $command = New-CapturedCommand -ScriptPath $scriptPath -ScriptAction "on" -ResultFile $resultFile
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $process = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -PassThru
        $script:runningProcess = $process
        Wait-ProcessOutput -Process $process -Path $resultFile
        return $process.ExitCode
    }

    BeforeEach {
        $script:relayed = @()
        Mock Write-Host {
            if ($Object) {
                $script:relayed += [pscustomobject]@{ Text = [string]$Object; Exited = $script:runningProcess.HasExited }
            }
        }
    }

    It "shows output while the process runs, then its error" {
        $exitCode = Invoke-CapturedScript @'
param($Action)
Write-Host "first line ($Action)"
Start-Sleep -Seconds 2
Write-Host "second line"
throw "Injected failure"
'@

        $exitCode | Should Be 1
        @($script:relayed | Where-Object { $_.Text -match "first line \(on\)" -and -not $_.Exited }).Count | Should Be 1
        $text = ($script:relayed | ForEach-Object Text) -join ""
        $text | Should Match "(?s)first line \(on\).*second line.*Injected failure.*it's a script\.ps1"
        # Every chunk was decoded as text, not as raw UTF-16 bytes.
        $text | Should Not Match "\x00"
    }

    It "shows an error raised before any other output" {
        # For example, a held controller lock or existing recovery state.
        $exitCode = Invoke-CapturedScript 'throw "Early failure"'

        $exitCode | Should Be 1
        $text = ($script:relayed | ForEach-Object Text) -join ""
        $text | Should Match "(?s)^Early failure.*it's a script\.ps1"
        $text | Should Not Match "\x00"
    }
}
