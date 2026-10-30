$repo = Split-Path $PSScriptRoot -Parent

Describe "Controller reliability" {
    # Define functions once, before Pester installs mock wrappers.
    $source = Get-Content (Join-Path $repo "transit-mode.ps1") -Raw
    $setup = $source.Substring(0, $source.IndexOf('# ---- Actions'))
    $setup = $setup.Replace('$PSScriptRoot', "'" + $repo.Replace("'", "''") + "'")
    . ([scriptblock]::Create($setup)) -Action status
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
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
