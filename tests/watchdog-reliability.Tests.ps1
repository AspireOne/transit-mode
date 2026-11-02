$repo = Split-Path $PSScriptRoot -Parent

Describe "Watchdog lifecycle in an isolated process" {
    BeforeEach {
        $sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $sandbox | Out-Null
        Copy-Item (Join-Path $repo "transit-config.ps1"), (Join-Path $repo "transit-watchdog.config.json") $sandbox
        $original = "11111111-1111-1111-1111-111111111111"
        $transit = "22222222-2222-2222-2222-222222222222"
        $worker = Get-Content (Join-Path $repo "transit-watchdog.ps1") -Raw
        $worker = $worker.Replace('Join-Path $env:ProgramData "TransitMode"', '$PSScriptRoot')
        # Replace only OS/sensor boundaries, after definitions and before entry.
        # In particular, run the real phase, emergency, timing, and status logic.
        $boundaries = @'
$script:activePlan = $ExpectedScheme
$script:samples = 0
$script:restoreAttempts = 0
$script:case = Get-Content (Join-Path $PSScriptRoot "case.txt") -Raw
$script:case = $script:case.Trim()
$events = Join-Path $PSScriptRoot "events.txt"
function Import-SensorLibrary {}
function New-CpuMonitor {
    $monitor = [pscustomobject]@{}
    $monitor | Add-Member ScriptMethod Close {}
    return $monitor
}
function Read-CpuTemperature {
    param($Computer)
    $script:samples++
    if ($script:case -eq "gap" -and $script:samples -eq 2) {
        [Threading.Thread]::Sleep(3100)
    }
    if ($script:case -in @("missing", "battery-missing-sensor") -and $script:samples -gt 1) { return $null }
    if ($script:case -like "status-*" -and $script:samples -eq 2) {
        Set-Content $WatchdogStatusFile '{"State":"previous"}'
        $script:statusReader = [IO.File]::Open($WatchdogStatusFile,
            [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    }
    $temperature = if ($script:case -eq "armed" -or $script:case -like "battery*" -or $script:case -like "status-*" -or $script:samples -eq 1) { 45 } else { 90 }
    return [pscustomobject]@{ MaximumC = $temperature; Sensors = @("test"); Readings = @() }
}
function Read-SystemPowerStatus {
    if ($script:case -eq "battery-failure") { throw "Injected power-status failure" }
    if ($script:case -like "battery*") {
        return Get-Content (Join-Path $PSScriptRoot "power-status.json") -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{ ACLineStatus = 1; BatteryFlag = 0; BatteryLifePercent = 100 }
}
function powercfg.exe {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    if ($Arguments[0] -eq "/setactive") {
        $script:restoreAttempts++
        if ($script:case -eq "restore-retry" -and $script:restoreAttempts -eq 1) {
            $global:LASTEXITCODE = 1
            return "Injected restore failure"
        }
        $script:activePlan = $Arguments[1]
        Add-Content $events "restored"
    }
    return "Power Scheme GUID: $script:activePlan"
}
function Invoke-NativeHibernate {
    if ($script:case -eq "fallback") { throw "Injected native failure" }
    Add-Content $events "hibernate:$script:activePlan"
    if ($script:case -eq "status-persistent") { $script:statusReader.Dispose() }
}
function shutdown.exe {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    Add-Content $events "fallback:$($Arguments[0]):$script:activePlan"
    $global:LASTEXITCODE = 0
}
function Start-Sleep {
    param($Seconds, $Milliseconds)
    if ($script:case -like "status-*" -and $Milliseconds -gt 0) {
        $status = Get-Content $WatchdogStatusFile -Raw | ConvertFrom-Json
        Add-Content $events "retry:$($status.State)"
        if ($script:case -eq "status-transient") { $script:statusReader.Dispose() }
        return
    }
    if ($script:case -eq "missing") { [Threading.Thread]::Sleep(1050); return }
    if ($script:case -eq "armed" -or $script:case -like "battery*" -or $script:case -like "status-*") {
        $status = Get-Content $WatchdogStatusFile -Raw | ConvertFrom-Json
        Add-Content $events $status.State
        if ($status.State -eq "armed") { $script:activePlan = $ExpectedScheme }
        elseif ($status.State -eq "healthy") {
            $script:activePlan = "11111111-1111-1111-1111-111111111111"
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            $state.Status = "stopping"
            $state | ConvertTo-Json | Set-Content $StateFile
        }
    }
}
if ($script:case -in @("armed", "stopped")) {
    $script:activePlan = "11111111-1111-1111-1111-111111111111"
}
'@
        $worker = $worker.Replace('$computer = $null', $boundaries + "`n" + '$computer = $null')
        Set-Content (Join-Path $sandbox "worker.ps1") $worker
        @{
            Status = "active"; TransitScheme = $transit; OriginalScheme = $original
        } | ConvertTo-Json | Set-Content (Join-Path $sandbox "state.json")
    }

    It "continues monitoring after a reader briefly blocks atomic status replacement" {
        Set-Content (Join-Path $sandbox "case.txt") "status-transient"

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        ($events -join ",") | Should Be "retry:previous,healthy"
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.State | Should Be "healthy"
        $status.CpuTemperatureC | Should Be 45
        $status.ExpectedScheme | Should Be $transit
        @(Get-ChildItem $sandbox -Filter "watchdog-status.json.*.tmp").Count | Should Be 0
        Get-Content (Join-Path $sandbox "watchdog.log") -Raw | Should Match "Status update recovered"
    }

    It "restores and hibernates after bounded retries even if emergency status is also locked" {
        Set-Content (Join-Path $sandbox "case.txt") "status-persistent"

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $retries = @($events | Where-Object { $_ -like "retry:*" })
        $retries.Count | Should BeGreaterThan 0
        ($retries.Count -le 8) | Should Be $true
        @($retries | Where-Object { $_ -ne "retry:previous" }).Count | Should Be 0
        (($events | Where-Object { $_ -notlike "retry:*" }) -join ",") | Should Be "restored,hibernate:$original"
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.State | Should Be "resumed-after-emergency"
        $status.Reason | Should Match "temperature watchdog failed"
        Get-Content (Join-Path $sandbox "watchdog.log") -Raw | Should Match "Status update failed after"
    }

    It "restores and hibernates on battery at <Percent>%" -TestCases @(
        @{ Percent = 6 }, @{ Percent = 5 }, @{ Percent = 0 }
    ) {
        param($Percent)
        Set-Content (Join-Path $sandbox "case.txt") "battery-low"
        @{ ACLineStatus = 0; BatteryFlag = 4; BatteryLifePercent = $Percent } |
            ConvertTo-Json | Set-Content (Join-Path $sandbox "power-status.json")

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "restored"
        $events[1] | Should Be "hibernate:$original"
        $events.Count | Should Be 2
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.State | Should Be "resumed-after-emergency"
        $status.Reason | Should Match "Battery charge reached $Percent%"
        $status.Reason | Should Match "threshold: 6%"
    }

    It "continues monitoring with <Case>" -TestCases @(
        @{ Case = "charge above threshold"; AC = 0; Percent = 7; Flag = 0 },
        @{ Case = "low charge on AC"; AC = 1; Percent = 6; Flag = 8 },
        @{ Case = "empty charge on AC"; AC = 1; Percent = 0; Flag = 0 },
        @{ Case = "unknown power source"; AC = 255; Percent = 6; Flag = 0 },
        @{ Case = "unknown charge"; AC = 0; Percent = 255; Flag = 255 },
        @{ Case = "no battery"; AC = 0; Percent = 0; Flag = 128 }
    ) {
        param($Case, $AC, $Percent, $Flag)
        Set-Content (Join-Path $sandbox "case.txt") "battery-continue"
        @{ ACLineStatus = $AC; BatteryFlag = $Flag; BatteryLifePercent = $Percent } |
            ConvertTo-Json | Set-Content (Join-Path $sandbox "power-status.json")

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events.Count | Should Be 1
        $events[0] | Should Be "healthy"
        (Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json).State | Should Be "healthy"
    }

    It "uses the configured battery threshold even when temperature readings disappear" {
        $configPath = Join-Path $sandbox "transit-watchdog.config.json"
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $config.lowBatteryPercent = 10
        $config | ConvertTo-Json | Set-Content $configPath
        Set-Content (Join-Path $sandbox "case.txt") "battery-missing-sensor"
        @{ ACLineStatus = 0; BatteryFlag = 255; BatteryLifePercent = 10 } |
            ConvertTo-Json | Set-Content (Join-Path $sandbox "power-status.json")

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "restored"
        $events[1] | Should Be "hibernate:$original"
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.Reason | Should Match "Battery charge reached 10%"
        $status.Reason | Should Match "threshold: 10%"
    }

    It "restores and hibernates if the Windows power-status call fails" {
        Set-Content (Join-Path $sandbox "case.txt") "battery-failure"

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit

        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "restored"
        $events[1] | Should Be "hibernate:$original"
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.Reason | Should Match "Injected power-status failure"
    }

    It "restores the original plan before emergency hibernation and exits safely after resume" {
        Set-Content (Join-Path $sandbox "case.txt") "critical"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "restored"
        $events[1] | Should Be "hibernate:$original"
        (Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json).State | Should Be "resumed-after-emergency"
    }

    It "retries protection after resume if original-plan restoration failed" {
        Set-Content (Join-Path $sandbox "case.txt") "restore-retry"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "hibernate:$transit"
        $events[1] | Should Be "restored"
        $events[2] | Should Be "hibernate:$original"
    }

    It "restores the plan before the shutdown.exe hibernation fallback" {
        Set-Content (Join-Path $sandbox "case.txt") "fallback"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "restored"
        $events[1] | Should Be "fallback:/h:$original"
    }

    It "protects activation even if the controller never commits the active state" {
        $statePath = Join-Path $sandbox "state.json"
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.Status = "activating"
        $state | ConvertTo-Json | Set-Content $statePath
        Set-Content (Join-Path $sandbox "case.txt") "armed"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $events = @(Get-Content (Join-Path $sandbox "events.txt"))
        $events[0] | Should Be "armed"
        $events[1] | Should Be "healthy"
        $events.Count | Should Be 2
    }

    It "does not hibernate an already restored session even with broken config" {
        Set-Content (Join-Path $sandbox "case.txt") "stopped"
        Set-Content (Join-Path $sandbox "transit-watchdog.config.json") '{}'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        Test-Path (Join-Path $sandbox "events.txt") | Should Be $false
    }

    It "treats delayed monitoring as an emergency rather than resetting timers" {
        $configPath = Join-Path $sandbox "transit-watchdog.config.json"
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $config.pollIntervalSeconds = 1
        $config.resumeGapSeconds = 2
        $config | ConvertTo-Json | Set-Content $configPath
        Set-Content (Join-Path $sandbox "case.txt") "gap"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.Reason | Should Match "monitoring gap"
        @(Get-Content (Join-Path $sandbox "events.txt"))[0] | Should Be "restored"
    }

    It "restores and hibernates when temperature readings disappear" {
        $configPath = Join-Path $sandbox "transit-watchdog.config.json"
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $config.pollIntervalSeconds = 1
        $config.missingSensorGraceSeconds = 1
        $config | ConvertTo-Json | Set-Content $configPath
        Set-Content (Join-Path $sandbox "case.txt") "missing"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox "worker.ps1") run -ExpectedScheme $transit
        $LASTEXITCODE | Should Be 0
        $status = Get-Content (Join-Path $sandbox "watchdog-status.json") -Raw | ConvertFrom-Json
        $status.Reason | Should Match "monitoring was unavailable"
    }
}

Describe "Native Windows power status" {
    It "reads the real power status without changing power settings" {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "transit-watchdog.ps1"), [ref]$tokens, [ref]$errors)
        foreach ($name in @("Initialize-NativePowerApi", "Read-SystemPowerStatus")) {
            $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
            . ([scriptblock]::Create($function.Extent.Text))
        }

        $status = Read-SystemPowerStatus

        $status | Should Not BeNullOrEmpty
        ($status.ACLineStatus -in @(0, 1, 255)) | Should Be $true
        ($status.BatteryLifePercent -le 100 -or $status.BatteryLifePercent -eq 255) | Should Be $true
    }
}
