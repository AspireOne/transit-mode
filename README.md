# Transit Mode

A Windows power-mode switch for when your laptop needs to keep working while closed and encapsulated in a bag (e.g. traveling).

It's especially useful for background work - a coding agent, build, test suite, download, or long-running script. No more half-opened lids just to ensure Claude keeps working - enable transit mode and take it To-Go (don't forget to connect your laptop to mobile data though).

Transit Mode lowers CPU power demand, disables CPU boost, keeps the machine awake with the lid closed, and crucially, watches the CPU temperature using an independent watchdog. If the temperature stays too high, the watchdog hibernates the laptop automatically.

It is deliberately boring. It changes a temporary Windows power plan, watches the machine, and 100% restores what it found when you are done.

## Compatibility and requirements

Transit Mode runs on **64-bit Windows 10 or 11** with the built-in Windows PowerShell 5.1 (the script re-launches itself if started from PowerShell 7). It is tested on one machine: Lenovo IdeaPad Slim 5 15ARP10 (Ryzen 7 7735HS), Windows 11.

- **Administrator approval** is required once per `on`/`off` for power-plan changes, hibernation, the scheduled watchdog task, and the sensor driver.
- **Hibernation must be supported by the firmware.** `on` enables it when disabled and verifies it afterwards; on machines without S4 it fails with a clear error before changing anything.
- **Enough free space on the system drive for a full hibernation file** — about 40% of installed RAM. `on` checks this up front.
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

That restores the original power plan and hibernation setting, stops the watchdog, and removes the temporary Transit Mode state.

I also recommend creating an alias/function in your powershell profile (e.g. `transit-mode on|off|status|diagnose`), in order to be able to switch easily, and also create a function that will print an informational `Transit Mode is ON` when your terminal opens, so you do not forget about it.

## Commands

```text
on        Enable Transit Mode
off       Restore the previous configuration
status    Show the current mode, watchdog, and temperature state
diagnose  Check sensor access and hibernation readiness
```

If the watchdog has already hibernated the laptop, resume Windows and run `off` once the machine is safely out of the bag.

## What it protects

- Reduced CPU power and no boost, on AC and battery
- Lid close set to “do nothing” while Transit Mode is active
- Watchdog samples CPU temperature every five seconds
- Automatic hibernation at 90 °C, or after 30 seconds in the 80 °C hot band
- Automatic hibernation if temperature readings disappear for 30 seconds
- Wake events suppressed while hibernating
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

A: That's what was the aim of this. Do not prefer it, but do try it. After a trial run, inspect the log file with temps - if they look okay, then you're good. Note: Nothing bad should happen - there is our watchdog, which hibernates the PC if temperatures rise above appropriate, and there's also firmware-level throttling and shutdown controls. The only negative effects would be on battery, but trying it once or a few times should be okay. Don't hold me liable for your battery though :D

---

For AI agents: Research the compatibility of this script with the user's computer, write the result into .local/COMPATIBILITY-CHECK.md (so you don't re-research it again needlessly), and inform them about the compatibility - full, partial, none.
