# Transit Mode

A Windows power-mode switch for when your laptop needs to keep working while closed and encapsulated in a bag (e.g. traveling).

It's especially useful for background work - a coding agent, build, test suite, download, or long-running script. No more half-opened lids just to ensure Claude keeps working - enable transit mode and take it To-Go (don't forget to connect your laptop to mobile data though).

Transit Mode lowers CPU power demand, disables CPU boost, keeps the machine awake with the lid closed, and crucially, watches the CPU temperature using an independent watchdog. If the temperature stays too high, the watchdog hibernates the laptop automatically.

It changes a temporary Windows power plan, watches CPU temperature, and restores the saved original plan when you are done. Incomplete recovery is reported and its state is retained for another `off` attempt.

## Compatibility and requirements

Transit Mode runs on **64-bit Windows 10 or 11** with the built-in Windows PowerShell 5.1 (the script re-launches itself if started from PowerShell 7). It is tested on one machine: Lenovo IdeaPad Slim 5 15ARP10 (Ryzen 7 7735HS), Windows 11.

- **Administrator approval** is required once per `on`/`off` for power-plan changes, the scheduled watchdog task, and the sensor driver. Results and errors appear in the calling terminal.
- **Full hibernation must already be available.** If needed, run `powercfg /hibernate /type full` once in an administrator terminal. `on` checks availability before changing power settings. Transit Mode leaves the hibernation configuration unchanged.
- **The watchdog needs the signed PawnIO kernel driver.** LibreHardwareMonitor reads CPU temperatures through it on both AMD and Intel CPUs; Memory Integrity (HVCI) does not block it. `on` installs it only after verifying its SHA-256 and Authenticode signature, and `diagnose` confirms a live temperature reading before use.
- **On Modern Standby (S0) laptops**, "lid close → do nothing" is honored, but the system can still drop into S0 low-power idle when the workload goes quiet, which throttles background work. Transit Mode does not hold a Windows execution request; it relies on the running work itself keeping the machine busy. This holds on the tested machine; on other S0 laptops, verify with `status` and a short test run first.
- **OEM power managers** (Lenovo Vantage Fn+Q, MyASUS, manufacturer utilities) may override the temporary plan's settings. Transit Mode does not change them.

Untested: Intel CPUs, ARM64, Windows 10, and non-Lenovo firmware behavior.

This is a practical convenience and safety tool, not a guarantee that every laptop or bag is thermally safe. Keep airflow sensible and use `status` when in doubt.

## Quick start

Open an elevated PowerShell window in this directory:

```powershell
.\transit-mode.ps1 diagnose
```

The first run verifies or installs the sensor dependencies and may ask for administrator approval. You can only run it once and then you're good to go.

```
.\transit-mode.ps1 on
```

Enable transit mode. Remember: it deliberately lowers power usage of the laptop and watches temps, so that even in an encapsulated bag, it doesn't get too hot. However, if possible, prefer to keep it ventilated and not on AC (powerbank etc.).

When you are back:

```powershell
.\transit-mode.ps1 off
```

That restores and verifies the original power plan before stopping the watchdog, then removes the temporary plan and recovery state. If restoration fails, the watchdog and recovery state remain. Overlapping mutating commands are rejected.

I also recommend creating an alias/function in your powershell profile (e.g. `transit-mode on|off|status|diagnose`), in order to be able to switch easily, and also create a function that will print an informational `Transit Mode is ON` when your terminal opens, so you do not forget about it.

## Commands

```text
on        Enable Transit Mode
off       Restore the previous configuration
status    Show the current mode, watchdog, and temperature state
diagnose  Check sensor access and hibernation readiness
```

An emergency first attempts to restore the original power plan, then hibernates. If restoration failed, the worker retries restoration and hibernation after resume instead of exiting unprotected. Run `off` after resuming to remove the temporary plan, task, and recovery files.

## Configuration

Edit the JSON files beside the scripts. Settings take effect on the next `on`;
if Transit Mode is already active, run `off` and then `on` to apply changes.
`diagnose` validates the files and probes sensors using the source watchdog config.

- [transit-mode.config.json](transit-mode.config.json): CPU limits, power-plan behavior, and watchdog startup timeout.
- [transit-watchdog.config.json](transit-watchdog.config.json): thermal thresholds, polling, grace periods, and log retention.

All fields are required integers; unknown fields, invalid values, and malformed
JSON cause an error before activation changes the system. JSON does not allow comments.

| Main setting | Meaning / allowed values |
| --- | --- |
| `cpuMinPercent`, `cpuMaxPercent`, `cpuEppPercent` | 0–100; minimum must not exceed maximum. EPP 100 prefers efficiency. |
| `cpuBoostMode` | Windows boost mode index 0–6; 0 disables boost. |
| `lidAction` | 0 = do nothing, 1 = sleep, 2 = hibernate, 3 = shut down. |
| `sleepTimeoutSeconds` | Seconds before idle sleep; 0 = never. |
| `wakeTimers` | 0 = disabled, 1 = enabled, 2 = important timers only. |
| `watchdogStartupTimeoutSeconds` | Positive; must exceed the watchdog's `startupGraceSeconds`. |

Watchdog temperatures are integer degrees Celsius (1–200), with
`temperatureResetC < sustainedTemperatureC < criticalTemperatureC`.
Crossing the sustained threshold starts the timer; cooling to the reset threshold
clears it. `sustainedTemperatureTimeSeconds` controls how long that timer may run.
Timing fields are positive seconds. `pollIntervalSeconds` must not exceed
`sustainedTemperatureTimeSeconds` or `missingSensorGraceSeconds`, and must be less
than `resumeGapSeconds` (the maximum permitted monitoring gap). Exceeding that
gap triggers emergency recovery; it never resets accumulated hot or missing-sensor
time. Intervals use a monotonic clock, so wall-clock changes cannot extend them.
`startupGraceSeconds` is the time allowed to obtain the first sensor reading.
`thermalLogRetentionDays` is a positive day count, capped at 36,500.
Numeric validation checks consistency; it does not establish safe thermal limits
for a particular laptop.

Activation saves the validated watchdog settings to
`C:\ProgramData\TransitMode\transit-watchdog.config.json`, alongside the installed
worker and shared loader. Editing the source files cannot change that session,
including when its task restarts. `off` and `status` work independently of the
editable config files. `state.json` remains recovery data, not configuration.
Keep both JSON files and `transit-config.ps1` with the source scripts when moving them.

To run the configuration tests without activating Transit Mode, use Windows PowerShell:

```powershell
Invoke-Pester .\tests -EnableExit
```

## What it protects (with the supplied configuration)

- Reduced CPU power and no boost, on AC and battery
- Lid close set to “do nothing” while Transit Mode is active
- Wake timers disabled on AC and battery
- Watchdog samples CPU temperature every five seconds
- Automatic hibernation at 82 °C, or after 30 seconds in the 80 °C hot band
- Automatic hibernation if temperature readings disappear for 22 seconds
- Emergency recovery after a monitoring gap longer than 20 seconds
- Watchdog armed before the temporary plan is activated
- Native hibernation requests wake-event suppression; the shutdown.exe fallback does not provide that option
- Original settings restored by `off`

Thermal history is retained in:

```text
C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv
```

The sensor driver remains installed because it is a shared dependency. Transit Mode does not change Lenovo Vantage profiles, RyzenAdj firmware limits, or GPU and battery temperature controls.

## Reasoning behind some decisions

**Q: Why not take advantage of RyzenAdj?**

A: In theory, on AMD CPUs, it allows to control the wattage of the CPU directly, which is **perfect** and potentially superior to manipulating windows power mode, when executed correctly. However, the issue was non-revertability. Lenovo, or other OEM firmware/software (e.g. Vantage) can override these values willy nilly - after the battery goes under a certain level, after connecting the laptop to AC etc. Furthermore, it is not possible to READ some important values (even some that CAN be WRITTEN cannot be read), so there is no reliable way to establish a "before-transit-mode" baseline to then revert to.

**Q: Why not take advantage of Lenovo's power-mode settings? (Fn+Q)**

A: There's no model-specific API to read the current operation mode and restore it exactly. on couldn't reliably capture "what was the mode before", and off couldn't guarantee putting it back. Simulating a Fn+Q press is non-reliable as well, because it cycles between three or more power modes. Furthermore, RyzenAdj and Lenovo's power-mode would keep overwriting each other.

**Q: Can I keep my laptop closed in my enclosed bag?**

A: The script reduces CPU load and reacts to CPU temperature, but that does not establish that an enclosed bag is safe. It does not measure battery, chassis, or bag temperature. Keep ventilation available; CPU logs alone cannot validate those conditions.

**Q: Why monitor only CPU temp, but not GPU, SSD, or Battery?**

A: It is indeed a real limitation, but there is some nuance to it.

SSD: Usually won't get hotter than the CPU. Additionally, tolerates higher temps than the CPU.

GPU: if you have an integrated GPU, like I do, it is on the same chip anyway (and likely less activa than the CPU); therefore, the temp won't rise above the CPU's temp anyway. But if you have an external GPU and do GPU-heavy workload in transit mode, having the watchdog monitor GPU temp would indeed be prudent. In that case, tread lightly.

Battery: Would 100% be prudent. However, monitoring the battery temperature is tricky. On my laptop, the value is not exposed; I have no way to retrieve it. Therefore, neither do I have the ability to implement it into this script.

## Flaws

- Does not monitor Battery / GPU / SSD temp (see above)

---

For AI agents: If evaluating this for personal use, or pulling it, research the compatibility of this script with the user's computer, write the result into .local/COMPATIBILITY-CHECK.md (so you don't re-research it again needlessly), and inform them about the compatibility - full, partial, none.
