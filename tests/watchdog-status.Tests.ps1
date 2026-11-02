$repo = Split-Path $PSScriptRoot -Parent

Describe "Watchdog status publication errors" {
    $source = Get-Content (Join-Path $repo "transit-watchdog.ps1") -Raw
    $setup = $source.Substring(0, $source.IndexOf('$computer = $null'))
    . ([scriptblock]::Create($setup)) -Action probe

    BeforeEach {
        $StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $StateDir | Out-Null
        $WatchdogStatusFile = Join-Path $StateDir "watchdog-status.json"
        $WatchdogLogFile = Join-Path $StateDir "watchdog.log"
        Set-Content $WatchdogStatusFile '{"State":"previous"}'
        $script:injectPublicationError = $true

        # Force rare native errors at the filesystem boundary. Lifecycle tests
        # separately exercise File.Replace against a real Windows file lock.
        Mock Test-Path {
            if ($script:injectPublicationError) {
                throw [IO.IOException]::new("Injected native publication error",
                    (-2147024896 + $script:nativeError))
            }
            return [IO.File]::Exists($LiteralPath)
        } -ParameterFilter { $LiteralPath -eq $WatchdogStatusFile }
        Mock Start-Sleep { $script:injectPublicationError = $false }
    }

    It "recovers from transient Win32 error <Code>" -TestCases @(
        @{ Code = 32 }, @{ Code = 33 }, @{ Code = 1175 }
    ) {
        param($Code)
        $script:nativeError = $Code

        Write-WatchdogStatus -State "healthy" -CpuTemperatureC 45

        $status = Get-Content $WatchdogStatusFile -Raw | ConvertFrom-Json
        $status.State | Should Be "healthy"
        $status.CpuTemperatureC | Should Be 45
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
            $Milliseconds -gt 0 -and $Milliseconds -le 100
        }
        Get-Content $WatchdogLogFile -Raw | Should Match "Win32 $Code"
    }

    It "immediately propagates non-retryable Win32 error <Code>" -TestCases @(
        @{ Code = 5 }, @{ Code = 112 }, @{ Code = 1176 }, @{ Code = 1177 }
    ) {
        param($Code)
        $script:nativeError = $Code
        $failure = $null

        try { Write-WatchdogStatus -State "healthy" -CpuTemperatureC 45 }
        catch { $failure = $_ }

        $failure | Should Not BeNullOrEmpty
        ($failure.Exception.GetBaseException().HResult -band 0xffff) | Should Be $Code
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        (Get-Content $WatchdogStatusFile -Raw | ConvertFrom-Json).State | Should Be "previous"
    }
}
