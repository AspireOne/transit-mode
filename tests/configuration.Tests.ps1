$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo "transit-config.ps1")

Describe "Editable configuration" {
    BeforeEach {
        $mode = Get-Content (Join-Path $repo "transit-mode.config.json") -Raw | ConvertFrom-Json
        $watchdog = Get-Content (Join-Path $repo "transit-watchdog.config.json") -Raw | ConvertFrom-Json
        $path = Join-Path $TestDrive "config.json"
    }

    It "preserves an edited CPU limit" {
        $mode.cpuMaxPercent = 47
        $mode | ConvertTo-Json | Set-Content $path
        (Read-TransitConfig $path mode).cpuMaxPercent | Should Be 47
    }

    It "rejects missing files, malformed JSON, and non-object roots" {
        { Read-TransitConfig (Join-Path $TestDrive "absent.json") mode } | Should Throw
        foreach ($json in @('{', 'null', '[]', '[{}]')) {
            Set-Content $path $json
            { Read-TransitConfig $path mode } | Should Throw
        }
    }

    It "rejects missing and misspelled settings" {
        $mode.PSObject.Properties.Remove("cpuMaxPercent")
        $mode | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path mode } | Should Throw "cpuMaxPercent"
        $mode | Add-Member NoteProperty cpuMaxPercent 45
        $mode | Add-Member NoteProperty cpuMaxPercnet 45
        $mode | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path mode } | Should Throw "cpuMaxPercnet"
    }

    It "rejects coercible or out-of-range CPU values" {
        foreach ($value in @("45", $true, $null, 45.5, -1, 101)) {
            $mode.cpuMaxPercent = $value
            $mode | ConvertTo-Json | Set-Content $path
            { Read-TransitConfig $path mode } | Should Throw "cpuMaxPercent"
        }
    }

    It "preserves an edited low-battery threshold" {
        $watchdog.lowBatteryPercent = 10
        $watchdog | ConvertTo-Json | Set-Content $path
        (Read-TransitConfig $path watchdog).lowBatteryPercent | Should Be 10
    }

    It "requires a valid integer low-battery threshold" {
        foreach ($value in @("6", $true, $null, 6.5, 0, 101)) {
            $watchdog.lowBatteryPercent = $value
            $watchdog | ConvertTo-Json | Set-Content $path
            { Read-TransitConfig $path watchdog } | Should Throw "lowBatteryPercent"
        }
        $watchdog.PSObject.Properties.Remove("lowBatteryPercent")
        $watchdog | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path watchdog } | Should Throw "lowBatteryPercent"
    }

    It "rejects a CPU minimum above the maximum" {
        $mode.cpuMinPercent = 60
        $mode.cpuMaxPercent = 45
        $mode | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path mode } | Should Throw "cpuMinPercent"
    }

    It "rejects overlapping thermal thresholds" {
        $watchdog.temperatureResetC = $watchdog.sustainedTemperatureC
        $watchdog | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path watchdog } | Should Throw "temperatureResetC"
        $watchdog.temperatureResetC = 70
        $watchdog.criticalTemperatureC = $watchdog.sustainedTemperatureC
        $watchdog | ConvertTo-Json | Set-Content $path
        { Read-TransitConfig $path watchdog } | Should Throw "criticalTemperatureC"
    }

    It "rejects polling that would reset timers or miss the configured grace period" {
        foreach ($property in @("resumeGapSeconds", "missingSensorGraceSeconds", "sustainedTemperatureTimeSeconds")) {
            $changed = $watchdog | ConvertTo-Json | ConvertFrom-Json
            $changed.$property = 4
            $changed | ConvertTo-Json | Set-Content $path
            { Read-TransitConfig $path watchdog } | Should Throw "pollIntervalSeconds"
        }
    }

    It "requires time for sensor startup before the controller times out" {
        $mode.watchdogStartupTimeoutSeconds = $watchdog.startupGraceSeconds
        { Assert-TransitStartupTiming $mode $watchdog } | Should Throw "watchdogStartupTimeoutSeconds"
    }
}

Describe "Script configuration integration" {
    BeforeEach {
        $sandbox = Join-Path $TestDrive "scripts"
        New-Item $sandbox -ItemType Directory -Force | Out-Null
        Get-ChildItem $repo -File | Where-Object { $_.Name -match '^transit-.*\.(ps1|json)$' } |
            Copy-Item -Destination $sandbox -Force
    }

    It "rejects invalid activation config before system operations" {
        Set-Content (Join-Path $sandbox "transit-mode.config.json") '{}'
        { & (Join-Path $sandbox "transit-mode.ps1") on } | Should Throw "Missing setting"
    }

    It "allows status with no config files or loader" {
        Remove-Item (Join-Path $sandbox "transit-mode.config.json")
        Remove-Item (Join-Path $sandbox "transit-watchdog.config.json")
        Remove-Item (Join-Path $sandbox "transit-config.ps1")
        # Status only reads the real system; it must not need tuning files.
        { & (Join-Path $sandbox "transit-mode.ps1") status } | Should Not Throw
    }

    It "uses edited thresholds in thermal decisions" {
        # Load the pure decision function without starting the hardware worker.
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "transit-watchdog.ps1"), [ref]$tokens, [ref]$errors)
        $decision = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-ThermalDecision" }, $false)
        . ([scriptblock]::Create($decision.Extent.Text))
        $configPath = Join-Path $sandbox "transit-watchdog.config.json"
        $edited = Get-Content $configPath -Raw | ConvertFrom-Json
        $edited.criticalTemperatureC = 85
        $edited | ConvertTo-Json | Set-Content $configPath
        $config = Read-TransitConfig $configPath watchdog
        $CriticalTemperatureC = $config.criticalTemperatureC
        $SustainedTemperatureC = $config.sustainedTemperatureC
        $TemperatureResetC = $config.temperatureResetC
        $SustainedTemperatureTime = $config.sustainedTemperatureTimeSeconds
        $now = 100.0
        (Get-ThermalDecision 84 $now $null).Action | Should Be "continue"
        (Get-ThermalDecision 85 $now $null).Action | Should Be "hibernate"
        (Get-ThermalDecision 78 $now ($now - 30)).Action | Should Be "hibernate"
        (Get-ThermalDecision 75 $now ($now - 30)).Action | Should Be "continue"
    }
}

Describe "Watchdog installation and recovery" {
    # Load once: redefining functions after Pester mocks them replaces its wrappers.
    # Load controller setup/functions, then mock only system boundaries.
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "transit-mode.ps1"), [ref]$tokens, [ref]$errors)
        $actions = $ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true)
        $setup = $ast.Extent.Text.Substring(0, $ast.Extent.Text.IndexOf('# ---- Actions'))
        $setup = $setup.Replace('$PSScriptRoot', "'" + $repo.Replace("'", "''") + "'")
        . ([scriptblock]::Create($setup)) -Action status
    BeforeEach {
        $StateDir = Join-Path $TestDrive "installed"
        New-Item $StateDir -ItemType Directory -Force | Out-Null
        $StateFile = Join-Path $StateDir "state.json"
        $WatchdogStatusFile = Join-Path $StateDir "watchdog-status.json"
        $WatchdogSourceScript = Join-Path $repo "transit-watchdog.ps1"
        $WatchdogInstalledScript = Join-Path $StateDir "transit-watchdog.ps1"
        $WatchdogInstalledConfig = Join-Path $StateDir "transit-watchdog.config.json"
        $WatchdogConfig = Read-TransitConfig (Join-Path $repo "transit-watchdog.config.json") watchdog
        $WatchdogStartupTimeout = 40
        Mock Remove-WatchdogTask {}
        # Task constructors create in-memory CIM objects; only registration and
        # execution touch Task Scheduler and need doubles.
        Mock Register-ScheduledTask {}
        Mock Grant-WatchdogTaskReadAccess {}
        Mock Get-WatchdogTask { [pscustomobject]@{ State = "Running" } }
    }

    It "installs the validated snapshot and all files needed by the worker" {
        $WatchdogConfig.criticalTemperatureC = 86
        $WatchdogConfig.lowBatteryPercent = 9
        Mock Start-ScheduledTask {
            @{ ExpectedScheme = "test-scheme"; State = "armed"; UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o");
                PollIntervalSeconds = 5; CpuTemperatureC = 45; Reason = $null } |
                ConvertTo-Json | Set-Content $WatchdogStatusFile
        }
        Start-Watchdog -TransitScheme "test-scheme" | Out-Null
        $WatchdogConfig.criticalTemperatureC = 90
        . (Join-Path $StateDir "transit-config.ps1")
        (Read-TransitConfig $WatchdogInstalledConfig watchdog).criticalTemperatureC | Should Be 86
        (Read-TransitConfig $WatchdogInstalledConfig watchdog).lowBatteryPercent | Should Be 9
        Test-Path $WatchdogInstalledScript | Should Be $true
        Assert-MockCalled Register-ScheduledTask -Times 1 -Exactly
        Assert-MockCalled Grant-WatchdogTaskReadAccess -Times 1 -Exactly
    }

    It "uses the running worker's polling interval for health" {
        Mock Get-WatchdogTask { [pscustomobject]@{ State = "Running" } }
        @{
            State = "healthy"
            UpdatedAt = [DateTimeOffset]::UtcNow.AddSeconds(-20).ToString("o")
            PollIntervalSeconds = 10
            ExpectedScheme = "test-scheme"
            CpuTemperatureC = 45
            Reason = $null
        } | ConvertTo-Json | Set-Content $WatchdogStatusFile
        (Get-WatchdogHealth -ExpectedScheme "test-scheme").IsReady | Should Be $true
    }

    It "restores the saved plan without reading editable configuration" {
        $Action = "off"
        Mock Test-IsAdministrator { $true }
        Mock Initialize-StateDirectory {}
        Mock Load-State { [pscustomobject]@{ OriginalScheme = "original"; TransitScheme = "temporary"; HibernateWasEnabled = $true; Version = 3; Status = "active" } }
        Mock Test-SchemeExists { $true }
        Mock Invoke-PowerCfg {}
        Mock Get-ActiveSchemeGuid { "original" }
        Mock Restore-HibernationState {}
        Mock Remove-StateArtifacts {}
        . ([scriptblock]::Create($actions.Extent.Text))
        Assert-MockCalled Invoke-PowerCfg -Times 1 -Exactly -ParameterFilter { $PowerArgs[0] -eq "/setactive" -and $PowerArgs[1] -eq "original" }
        Assert-MockCalled Remove-StateArtifacts -Times 1 -Exactly
    }
}
