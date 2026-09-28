# Reliability fixes

Implemented 2026-09-28 following [the audit](REVIEW.md).

## Decisions

Keep the controller, worker, and configuration loader separate. Share restoration
within the controller; avoid adding a service or a general state-machine framework.

The controller saves `activating`, `active`, or `stopping` recovery state. The
worker decides what to do from both that state and the actual active power plan:

| Actual plan | Saved state | Worker behavior |
| --- | --- | --- |
| Transit | Any valid lifecycle state | Monitor temperature |
| Original | Activating | Stay armed for activation |
| Original | Active or stopping | Exit; the original plan has been restored |
| Another plan | Any | Emergency recovery |

This keeps monitoring through a failed `off` and through activation even if the
controller dies before marking the session active. The worker is registered and
armed before the controller activates Transit. It also runs after a reboot.

Full hibernation is now a prerequisite. This machine already has it enabled.
For setup elsewhere, run `powercfg /hibernate /type full` in an administrator
terminal. New sessions do not change hibernation settings; recovery of existing
version 1/2 sessions remains supported. Version 3 saves only lifecycle information
and the original/temporary plan identities.

## Findings addressed

| Finding | Change |
| --- | --- |
| Unprotected emergency resume | Restore and verify the original plan before hibernation. If that fails, keep retrying restoration and hibernation after resume rather than exiting. |
| Unsafe recovery ordering | Both rollback and `off` restore and verify the original plan before removing the watchdog. Failed restoration retains monitoring and recovery data. |
| Timers reset by scheduling gaps | Use monotonic elapsed seconds. Exceeding `resumeGapSeconds` triggers emergency recovery instead of clearing danger timers. |
| Activation before worker installation | Start and verify an armed worker first; require a healthy session heartbeat after activating Transit. |
| Concurrent controllers | Hold one exclusive file lock across mutating commands; dispose it in `finally`. |
| Unreliable health reporting | Validate required fields, state and temperature, session identity, running task, and nonnegative bounded heartbeat age. Invalid data produces an unhealthy reason. |
| Loss of reduced-hibernation configuration | Stop changing hibernation for new sessions; require full hibernation beforehand. |
| Disappearing elevated errors | Capture elevated output and errors and display them in the calling terminal. |
| Missing explicit shutdown privilege | Enable `SeShutdownPrivilege` with checked native calls before `SetSuspendState`. |

Additional changes: use atomic replacement for existing recovery/heartbeat files;
keep diagnostic probes from overwriting a live worker's status on failure;
preserve task permissions when adding read access to a noncanonical ACL; load
controller definitions only once per test scope so Pester mock wrappers survive.

The emergency policy briefly restores normal CPU settings before requesting
hibernation. This restores normal lid/sleep behavior for the subsequent resume.
`off` still removes the remaining temporary plan, task, and recovery files.

## Validation

- Windows PowerShell 5.1, built-in Pester 3.4: 33 tests passed.
- Regression coverage includes arming order, failed arming, restoration failure,
  incorrect powercfg success, task cleanup failure, legacy state, overlapping
  controllers, atomic state replacement, and invalid/future/foreign heartbeats.
- Separate worker processes exercise the actual worker control flow with sensor
  and OS boundaries replaced: critical temperature, failed emergency restoration,
  hibernation fallback, activation with no final controller commit, already
  restored sessions, delayed monitoring, and missing sensors.
- Real `transit-mode on` succeeded; unelevated `status` reported a running healthy
  watchdog and a live CPU reading. `off` restored the original Balanced plan and
  removed recovery state and the watchdog task.
- A second real `on` while active failed as expected, and its elevated error and
  stack trace appeared in the original terminal.
- Native declarations compiled under Windows PowerShell. PowerShell parser checks
  passed. No project lint/static-analysis tool is configured; PSScriptAnalyzer is
  not installed.

The SYSTEM-task probe of runtime shutdown-privilege enabling was rejected by
automatic approval review, which supplied only “blocked by policy.” No alternative
privilege probe was attempted. Physical emergency hibernation/resume and runtime
privilege enabling therefore remain unverified. Simulated emergency tests do not
establish physical power-transition behavior. The native path requests wake-event
suppression; the shutdown.exe fallback has no corresponding option.

Run tests from Windows PowerShell:

```powershell
Invoke-Pester .\tests -EnableExit
```

When launching Windows PowerShell from PowerShell 7, an inherited module path can
make built-in Pester 3 fail to load. The validation command used a Windows-only
module path within the test process:

```powershell
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"
Invoke-Pester .\tests -EnableExit
```
