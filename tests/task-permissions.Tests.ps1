$repo = Split-Path $PSScriptRoot -Parent

Describe "Watchdog task read access" {
    BeforeEach {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repo "transit-mode.ps1"), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Grant-WatchdogTaskReadAccess"
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        $WatchdogTaskName = "Transit Mode Watchdog"

        # Only the Task Scheduler COM boundary is replaced; ACL editing is real.
        $task = [pscustomobject]@{ Descriptor = "D:(A;;FA;;;SY)(D;;FW;;;BU)"; Saved = $null }
        $task | Add-Member ScriptMethod GetSecurityDescriptor { param($sections) $this.Descriptor }
        $task | Add-Member ScriptMethod SetSecurityDescriptor { param($sddl, $flags) $this.Saved = $sddl }
        $folder = [pscustomobject]@{ Task = $task }
        $folder | Add-Member ScriptMethod GetTask { param($name) $this.Task }
        $scheduler = [pscustomobject]@{ Folder = $folder }
        $scheduler | Add-Member ScriptMethod Connect {}
        $scheduler | Add-Member ScriptMethod GetFolder { param($path) $this.Folder }
        Mock New-Object { $scheduler } -ParameterFilter { $ComObject -eq "Schedule.Service" }
    }

    It "grants the current user read access while preserving a noncanonical task DACL" {
        $before = [Security.AccessControl.RawSecurityDescriptor]::new($task.Descriptor)
        ([Security.AccessControl.CommonSecurityDescriptor]::new(
            $false, $false, $task.Descriptor)).IsDiscretionaryAclCanonical | Should Be $false

        Grant-WatchdogTaskReadAccess

        $after = [Security.AccessControl.RawSecurityDescriptor]::new($task.Saved)
        $after.DiscretionaryAcl.Count | Should Be 3
        # Existing allow and deny entries must retain both their contents and order.
        for ($index = 0; $index -lt $before.DiscretionaryAcl.Count; $index++) {
            $after.DiscretionaryAcl[$index].Equals($before.DiscretionaryAcl[$index]) | Should Be $true
        }
        $grant = $after.DiscretionaryAcl[2]
        $grant.SecurityIdentifier.Value | Should Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $grant.AceQualifier | Should Be ([Security.AccessControl.AceQualifier]::AccessAllowed)
        $grant.AccessMask | Should Be ([int]::MinValue)
        $grant.AceFlags | Should Be ([Security.AccessControl.AceFlags]::None)
    }
}
