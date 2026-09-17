# Shared JSON loading and validation. This file has no system side effects.

function Read-TransitConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet("mode", "watchdog")][string]$Kind
    )

    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if (-not $json.TrimStart().StartsWith("{")) {
            throw "Expected a JSON object."
        }
        $config = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($config -isnot [pscustomobject]) {
            throw "Expected a JSON object."
        }
    }
    catch {
        throw "Cannot read configuration '$Path': $($_.Exception.Message)"
    }

    $ranges = if ($Kind -eq "mode") {
        [ordered]@{
            cpuMinPercent = @(0, 100)
            cpuMaxPercent = @(0, 100)
            cpuEppPercent = @(0, 100)
            cpuBoostMode = @(0, 6)
            lidAction = @(0, 3)
            sleepTimeoutSeconds = @(0, [int]::MaxValue)
            wakeTimers = @(0, 2)
            watchdogStartupTimeoutSeconds = @(1, [int]::MaxValue)
        }
    }
    else {
        [ordered]@{
            pollIntervalSeconds = @(1, [int]::MaxValue)
            sustainedTemperatureC = @(1, 200)
            sustainedTemperatureTimeSeconds = @(1, [int]::MaxValue)
            temperatureResetC = @(1, 200)
            criticalTemperatureC = @(1, 200)
            missingSensorGraceSeconds = @(1, [int]::MaxValue)
            startupGraceSeconds = @(1, [int]::MaxValue)
            resumeGapSeconds = @(1, [int]::MaxValue)
            thermalLogRetentionDays = @(1, 36500)
        }
    }

    foreach ($property in $config.PSObject.Properties) {
        if (-not $ranges.Contains($property.Name)) {
            throw "Unknown setting '$($property.Name)' in '$Path'."
        }
    }
    foreach ($name in $ranges.Keys) {
        $property = $config.PSObject.Properties[$name]
        if ($null -eq $property) {
            throw "Missing setting '$name' in '$Path'."
        }
        $value = $property.Value
        $range = $ranges[$name]
        if (($value -isnot [int] -and $value -isnot [long]) -or
            $value -lt $range[0] -or $value -gt $range[1]) {
            throw "Setting '$name' in '$Path' must be an integer from $($range[0]) to $($range[1])."
        }
    }

    if ($Kind -eq "mode") {
        if ($config.cpuMinPercent -gt $config.cpuMaxPercent) {
            throw "Configuration '$Path': cpuMinPercent must not exceed cpuMaxPercent."
        }
    }
    else {
        if ($config.temperatureResetC -ge $config.sustainedTemperatureC -or
            $config.sustainedTemperatureC -ge $config.criticalTemperatureC) {
            throw "Configuration '$Path': require temperatureResetC < sustainedTemperatureC < criticalTemperatureC."
        }
        if ($config.pollIntervalSeconds -gt $config.sustainedTemperatureTimeSeconds -or
            $config.pollIntervalSeconds -gt $config.missingSensorGraceSeconds -or
            $config.pollIntervalSeconds -ge $config.resumeGapSeconds) {
            throw "Configuration '$Path': pollIntervalSeconds must not exceed either sustainedTemperatureTimeSeconds or missingSensorGraceSeconds, and must be less than resumeGapSeconds."
        }
    }
    return $config
}

function Assert-TransitStartupTiming {
    param([Parameter(Mandatory)]$Mode, [Parameter(Mandatory)]$Watchdog)

    if ($Mode.watchdogStartupTimeoutSeconds -le $Watchdog.startupGraceSeconds) {
        throw "watchdogStartupTimeoutSeconds must exceed the watchdog's startupGraceSeconds."
    }
}
