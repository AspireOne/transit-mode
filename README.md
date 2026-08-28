# Transit Mode

A Windows power-mode switch for when your laptop needs to keep working while closed and encapsulated in a bag (e.g. traveling).

It's especially useful for background work - a coding agent, build, test suite, download, or long-running script. No more half-opened lids just to ensure Claude keeps working - enable transit mode and take it To-Go (don't forget to connect your laptop to mobile data though).

Transit Mode lowers CPU power demand, disables CPU boost, keeps the machine awake with the lid closed, and crucially, watches the CPU temperature using an independent watchdog. If the temperature stays too high, the watchdog hibernates the laptop automatically.

It is deliberately boring. It changes a temporary Windows power plan, watches the machine, and 100% restores what it found when you are done.

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

## Requirements

- Windows 11 with PowerShell 5
- Administrator approval when requested (when changing on/off)
- Enough free disk space for a full hibernation file (>12GB?)

This is a practical convenience and safety tool, not a guarantee that every laptop or bag is thermally safe. Keep airflow sensible and use `status` when in doubt.
