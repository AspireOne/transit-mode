# Transit Mode reliability review

Implementation follow-up: [fixes and validation](RESOLUTION.md). The findings
below describe the code as it stood before those changes.

Reviewed 2026-09-28. Scope: controller, watchdog, configuration, scheduled task,
recovery behavior, and existing tests, including the uncommitted permission fix.
This review makes no further production-code changes.

The normal activation/restoration path works. The main weaknesses are incomplete
transitions between protected and unprotected operation, and timing assumptions.
Keep the current small scripts; a framework or service rewrite is not justified.

## Findings

### 1. High: emergency resume leaves the Transit plan without monitoring

Location: `transit-watchdog.ps1:417`, `:599`, `:628`; `transit-mode.ps1:576`.

After the native hibernation call succeeds, the worker writes
`resumed-after-emergency` and its caller exits with code zero. The temporary plan
and active recovery state remain. The task has a boot trigger and failure retries,
but neither provides ongoing monitoring after this successful exit on resume.
The shutdown.exe hibernation fallback also exits successfully without arranging
monitoring on resume.

This behavior is documented as requiring manual `off`, but it is a reliability
gap: the laptop can resume with lid-close and idle-sleep protection disabled while
its temperature monitor is gone. Do not rely on the user remembering recovery.

Evidence: ran the actual worker control flow in a temporary sandbox, replacing
sensor access and the native power call. A simulated critical reading produced
exit code 0, `resumed-after-emergency`, and unchanged active recovery state.
This verifies control flow, not physical hibernation or resume behavior.

Direction: either continue monitoring after resume or automatically restore the
original plan before ending protection. Choose one explicit policy and test it.

### 2. High: failed restoration can leave protection absent or trigger an emergency

Location: `transit-mode.ps1:789`, `:800`, `:875`, `:879`.

`off` removes the watchdog before restoring the original plan. If `/setactive`
fails, the Transit plan remains active with no monitor. Retaining recovery state
allows a later retry but does not protect the laptop in the meantime.

The activation rollback has the opposite failure: it restores the original plan
even if stopping the watchdog failed. A worker that remains alive interprets that
plan change as an emergency and can hibernate the machine during rollback.

Evidence: separate fault-injection tests reproduced both command sequences using
the actual controller action block and doubles only at operation boundaries.

Direction: make leaving Transit Mode an explicit transition. Keep or re-establish
protection when restoring the original plan fails. Coordinate intentional plan
changes with the worker so it does not interpret recovery as an emergency.

### 3. High: scheduling gaps can indefinitely postpone an emergency

Location: `transit-watchdog.ps1:539`, `:545`.

Every loop gap exceeding `resumeGapSeconds` resets both the hot and missing-sensor
timers. A gap does not establish that the system slept: CPU contention or slow
sensor/power API calls can cause it while the laptop remains awake.

Evidence: simulated ten consecutive 21-second gaps with CPU readings of 81 C.
The actual gap-handling block and thermal decision function kept returning
`continue`, although the configured hot-band allowance is only 30 seconds.
Repeated missing readings are subject to the same reset.

Direction: do not discard accumulated danger based on an unexplained delay.
Use monotonic elapsed time for intervals and define conservative behavior after
a monitoring gap. If sleep needs different handling, identify it explicitly.

### 4. High: activation has a window with no independent recovery worker

Location: `transit-mode.ps1:763`, `:765`; `Start-Watchdog` at `:542`.

The controller activates the temporary plan before copying, registering, and
starting the watchdog. A terminating exception rolls back, but killing the
controller or losing power in that interval bypasses its catch block. Recovery
state remains on disk; no registered worker is guaranteed to act on it.

Evidence: source-level control-flow review. No real controller was killed while
the laptop was unprotected.

Direction: install an independent recovery mechanism before activating the plan.
Give the worker explicit activation/active/stopping behavior so merely reordering
the current calls does not create false emergencies.

### 5. Medium: concurrent controllers can overwrite recovery state

Location: `transit-mode.ps1:160`, `:710`, `:739`, `:845`.

There is no exclusive lock around controller operations. Two `on` processes can
both pass the missing-state check, then overwrite the same state and `.tmp` file,
replace the same task, or mistake another activation's temporary plan for the
original. An overlapping `on` and `off` can also dismantle each other's work.

Evidence: source-level review of the shared files, task name, and action ordering.
No concurrent activation was performed against the real power settings.

Direction: use one machine-wide exclusive lock for mutating controller commands,
acquired before checking state and released in `finally`. Reject overlapping
operations with a clear message. This is a small change with substantial value.

### 6. Medium: health reporting accepts invalid evidence

Location: `transit-mode.ps1:628`, `:658`, `:666`, `:919`.

Freshness checks only whether age is below a maximum, so a heartbeat dated an hour
in the future remains fresh for that hour. The ready check does not correlate
`ExpectedScheme` with the saved session. A readable JSON object missing `State`
can throw under strict mode instead of returning an unhealthy result.

Evidence: isolated tests reproduced acceptance of a future heartbeat and the
strict-mode failure for a missing property. Missing session correlation was
confirmed by inspection; it was not reproduced through a normal activation.

Direction: validate the few required status fields, require a bounded nonnegative
age, and require the expected session GUID before declaring protection healthy.
Return an explicit unhealthy reason when status data is invalid.

### 7. Medium: hibernation restoration does not preserve every original mode

Location: `transit-mode.ps1:438`, `:470`, `:722`, `:735`.

Only the Boolean result of `IsPwrHibernateAllowed` is saved. Windows also supports
a reduced hibernation file for Fast Startup without full hibernation. That state
cannot be distinguished from hibernation being disabled by the saved Boolean.
After temporarily enabling full hibernation, `off` disables hibernation entirely
when the saved value is false, rather than restoring the reduced configuration.

Evidence: code review against Microsoft's documented full/reduced distinction.
The reduced-file scenario was not applied to the real machine.

Direction: either preserve the relevant hibernation configuration explicitly or
require full hibernation to be configured beforehand. The latter keeps the tool
smaller, if that setup requirement is acceptable.

Reference: [Microsoft system power states](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states).

### 8. Medium: elevated errors are not reliably visible in the calling terminal

Location: `transit-mode.ps1:117`.

The elevated process runs in a separate window and the caller receives only its
exit code. Only `diagnose` retrieves a result file. An `on` or `off` failure can
therefore disappear when the elevated window closes, making recovery harder.

Evidence: source review; reproducing the original permissions error required a
separate transcript wrapper to retain its full error and stack trace.

Direction: relay the elevated operation's result and error to the original
terminal. Keep the result transport small and separate from recovery state.

## Additional verification gap

The native emergency path does not explicitly enable `SeShutdownPrivilege`
before `SetSuspendState`. A temporary SYSTEM task using the same principal and
run level reported that privilege as disabled. Microsoft documents that callers
must have the privilege and describes enabling it with `AdjustTokenPrivileges`.

This is not proof that the actual call fails: the API or loaded code might adjust
privileges internally, and the script has a shutdown.exe fallback. However, the
intended native path and its wake-event suppression remain unverified. Establish
the privilege explicitly and test the real emergency/resume cycle under controlled
conditions before claiming that behavior is reliable.

Reference: [Microsoft SetSuspendState contract](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate).

## Code and test recommendations

- Retain separate controller, watchdog, and configuration-loader responsibilities.
  The current split is understandable; broad extraction would add indirection.
- Make the protection lifecycle explicit before reducing rollback code. The
  central invariant should be that a running Transit plan has a live watchdog or
  an independent recovery action in progress.
- Use one restoration routine once the failure policy is settled. `off` and the
  activation catch block currently implement different recovery semantics.
- Add focused tests for the findings above. Existing tests mainly cover config
  validation, installation, and successful restoration; they do not establish
  watchdog lifecycle or failure-path reliability.
- Isolate script loading in tests. Re-evaluating controller function definitions
  can replace Pester 3 mock wrappers between cases; separate processes avoided
  that problem in this audit. Do not let a test accidentally call real system
  operations because a mock was overwritten.
- Keep sensor versions and their verified hashes intentionally pinned. Duplication
  of a few constants is lower priority than recovery correctness; do not add a
  configuration framework merely to remove it.

## Validation and limits

- Existing suite: 15 passed, 0 failed under Windows PowerShell 5.1/Pester 3.4.
- Five isolated fault reproductions confirmed restoration failure, failed-stop
  rollback, future-heartbeat acceptance, malformed-status failure, and repeated
  gap resets. These tests assert observed defects, not desired passing behavior.
- A separate sandboxed worker run confirmed exit after simulated emergency resume.
- A temporary SYSTEM scheduled task inspected token privileges and was removed.
- No real emergency hibernation, forced shutdown, thermal stress, or controller
  termination was performed. Those outcomes cannot be inferred from unit tests.
- The earlier real on/status/off smoke test succeeded with a healthy sensor.
- Production code and its pre-existing working-tree changes were preserved.

Suggested order: lifecycle and recovery, timer behavior, exclusive controller
lock, trustworthy status, then hibernation restoration and error presentation.
