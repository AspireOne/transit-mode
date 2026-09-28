# Transit Mode — Context

## Goal

Keep long-running Codex work running on the laptop while the lid is closed and the laptop is being carried, without moving the repository or development environment elsewhere.

Target machine:

- Lenovo IdeaPad Slim 5 15ARP10, type 83J3
- AMD Ryzen 7 7735HS, 8C/16T, Radeon 680M integrated graphics
- Windows 11 / WSL development environment

The laptop must remain fully awake because Codex and the tools it launches are normal desktop processes. The problem is therefore not "how to make sleep keep executing", but **how to keep the real machine awake while deliberately constraining heat and power**.

## Requirements

- Codex and all child tooling continue normally with the lid closed.
- Arbitrary local repositories and machine-specific tooling must keep working.
- Transit Mode should strongly reduce peak/sustained power.
- Thermal behavior should be measurable and guarded by a fail-safe watchdog.
- `transit-mode on` and `transit-mode off` should be the whole user-facing workflow.
- **Reversibility is critical:** `off` must restore the machine's configuration exactly to its pre-Transit state.
- Experimental/vendor-specific controls should not be added unless they can satisfy that reversibility requirement.

## Alternatives considered

### Permanent VPS development

Technically robust, but it changes the primary development environment. Repositories, credentials, runtimes, local services and PC-specific tooling would need to live remotely. It also cannot handle tasks whose subject is the laptop itself.

**Rejected as the general solution.**

### Live handoff to a VPS

Codex sessions and working trees can be transferred and resumed remotely, and tools such as Parcels demonstrate this. The hard part is reproducing the complete execution environment: installed runtimes, system packages, MCP servers, browsers, Playwright state, credentials, services, Docker state, OS-specific behavior, filesystem paths, etc.

For arbitrary repositories this is too brittle unless the entire development environment is intentionally reproducible.

**Rejected as the general solution.**

### Modern Standby / normal sleep

Not useful. Windows pauses ordinary desktop applications during Modern Standby; Codex cannot continue arbitrary work in a normal sleep state.

**Rejected.**

### Simply use "lid close → do nothing"

This keeps Codex alive, but leaves the laptop free to consume its normal peak power inside an insulated bag.

**Useful foundation, insufficient by itself.**

## Current approach

`transit-mode.ps1` creates a **temporary clone of the currently active Windows power plan** and modifies only that clone:

- CPU minimum state → 5%
- CPU maximum state → 45%
- CPU EPP → 100 / maximum efficiency preference
- CPU boost → disabled
- Lid close → do nothing
- Idle sleep → never
- Wake timers → disabled
- Same policy on AC and battery

The original power plan is never modified.

`on` also starts an independent CPU-temperature watchdog:

- LibreHardwareMonitor 0.9.6 reads the Ryzen `Tctl/Tdie` control temperature.
- The release and extracted DLLs are pinned and SHA-256 verified.
- The signed PawnIO 2.2.0 kernel driver supplies the privileged AMD register access LibreHardwareMonitor requires. Its official installer is pinned by SHA-256 and Authenticode-verified; the shared driver remains installed after `off`.
- A hidden SYSTEM scheduled task supervises the worker, restarts it after failure, and starts it after an unexpected reboot.
- `on` arms the worker before activating the cloned plan, then requires a fresh healthy heartbeat belonging to that session. Mutating commands hold an exclusive controller lock.
- Every five-second sample is appended to a daily `C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv` file. History survives `off`; files older than 30 days are removed when the watchdog starts.
- The machine hibernates immediately at 82 °C, or after entering the 80 °C hot band and failing to cool to 75 °C within 30 seconds.
- Loss of valid sensor readings for 22 seconds, a monitoring gap over 20 seconds, watchdog failure, or activation of a plan other than Transit or the saved original also triggers emergency recovery.
- If both Windows hibernation mechanisms fail during an emergency, an immediate forced shutdown is the final safety fallback and can lose unsaved work.

Full hibernation must be configured before `on`; new sessions never change that setting. Emergency recovery attempts to restore the original power plan before hibernating. If restoration fails, the worker retries after resume rather than exiting with Transit still active. Recovery state remains for `off` to finish cleanup.

On `transit-mode off`, the script:

1. saves the stopping state and restores/verifies the untouched original plan,
2. stops/removes the watchdog and deletes the temporary Transit plan,
3. deletes recovery state only after successful cleanup.

A failed plan restoration leaves monitoring and recovery state intact. Recovery
of legacy sessions still restores their saved hibernation setting.

This gives stronger reversibility than editing the active plan and trying to reconstruct old values later.

## Remaining validation

1. Physical emergency hibernation/resume remains unverified. The real `on` → `status` → `off` lifecycle passed on 2026-09-28; automated tests cover simulated emergency and failed recovery paths. See `docs/features/reliability-audit/RESOLUTION.md`.
2. Run controlled tests: desk open → desk closed → bag open → bag closed.
3. Test both normal Codex activity and deliberately heavy builds/tests.
4. Calibrate the conservative 80/82 °C thresholds downward if chassis or bag temperatures become uncomfortable first.
5. Do not charge inside the bag; the watchdog currently observes CPU temperature, not battery or chassis temperature.
6. Only if Windows-level limits are insufficient, evaluate stronger controls such as Lenovo Power Saving mode or RyzenAdj power limits.
