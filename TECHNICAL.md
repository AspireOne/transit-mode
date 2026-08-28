# Transit Mode — Technical Options

## Overview

- **Temporary cloned Windows power plan** — current foundation; highly reversible.
- **CPU boost disable** — current; removes expensive turbo/boost behavior.
- **EPP / efficiency preference** — current; biases CPPC strongly toward efficient operating points.
- **CPU min/max performance state** — current; 5–50% initial envelope.
- **Lid action + idle sleep** — current; keep the machine fully awake with lid closed.
- **Energy Saver** — optional; reduces broader Windows/app background power.
- **Lenovo Fn+Q / Power Saving (Quiet)** — useful OEM-level platform/fan policy; not currently automated.
- **Hard maximum CPU frequency** — optional stronger CPU ceiling.
- **Core parking** — optional; limits how many logical processors may remain unparked.
- **EcoQoS / Efficiency Mode** — optional per-process efficiency hint.
- **Windows Job Objects CPU hard cap** — optional deterministic cap for Codex/process trees.
- **Process affinity / priority** — optional but weaker scheduling controls.
- **WSL cgroup CPUQuota** — optional if the relevant Codex/process tree runs inside WSL.
- **RyzenAdj PPT/STAPM/Tctl controls** — powerful APU watt/temperature limits, but poor exact-revertability.
- **Workload concurrency limits** — optional; constrain Jest/build/test/compiler worker counts.
- **Thermal monitoring + watchdog** — current; fail-safe CPU monitoring with automatic hibernation.
- **Charging/physical airflow policy** — operational control; initially test on battery only.

## Current controls

### Temporary power scheme

The script clones whatever power scheme is active when Transit Mode starts. Only the clone is changed.

```text
original A → clone T → modify/activate T
off        → reactivate A → delete T
```

This is the core reversibility mechanism.

### CPU minimum / maximum performance

Current:

```text
minimum → 5%
maximum → 50%
```

Windows exposes processor min/max performance as percentages. The 5% minimum prevents an inherited High Performance-style minimum from defeating the Transit cap.

This is an indirect performance limit rather than a literal watt limit, but it is simple and reversible.

### Processor boost

Current:

```text
PERFBOOSTMODE → 0 / disabled
```

This prevents the CPU from using boost performance above its nominal range. On a 7735HS this is valuable because high-frequency boost is disproportionately power-expensive.

### Energy Performance Preference

Current:

```text
PERFEPP → 100
```

EPP ranges from 0 (favor performance) to 100 (favor energy savings). It lets the hardware/Windows CPPC logic choose efficient operating points rather than merely imposing a fixed clock.

### Lid / sleep behavior

Current:

```text
lid close → do nothing
idle sleep → never
```

The machine therefore stays in the normal fully-running state. This is intentional: Modern Standby is not sufficient for Codex.

Both AC and DC values are configured so plugging/unplugging power does not silently change Transit behavior.

## Additional Windows controls

### Hard maximum CPU frequency

`PROCFREQMAX` can impose a maximum processor frequency in MHz.

Potential use: add a direct frequency ceiling if the percentage cap proves too vague.

Not enabled initially because boost-off + EPP + max-performance should be tested first.

### Core parking

`CPMAXCORES` can cap the percentage of logical CPUs simultaneously unparked. On the 16-thread 7735HS, 50% would allow at most roughly eight logical processors to be unparked.

Not enabled initially. Under a power-constrained workload, using more cores at lower clocks can be more efficient than forcing fewer cores to work harder.

### Energy Saver

Windows 11 Energy Saver reduces system/app energy use and background activity.

Potentially useful as a second system-wide layer, but it changes behavior beyond the power plan and therefore requires explicit state capture/restoration before being automated.

### Power requests

Windows applications can create `PowerRequestSystemRequired` / `PowerRequestExecutionRequired` requests to keep work running.

Not needed for v1 because Transit Mode explicitly sets idle sleep to never. Power requests also do not provide a magical way to keep normal desktop work executing through an explicit sleep transition.

## Per-process / workload controls

### EcoQoS / Efficiency Mode

Windows can mark a process/thread as EcoQoS using `PROCESS_POWER_THROTTLING_EXECUTION_SPEED`. Windows then favors power-efficient scheduling/frequency choices.

Good fit for Codex/background agents because latency is less important than continued progress.

This is a hint, not a hard CPU ceiling.

### Job Objects CPU hard cap

Windows Job Objects support `JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP`.

This can constrain a process tree to a defined share of processor cycles, e.g. 20% of total CPU capacity. It is much more deterministic than priority/affinity and is attractive for a future launcher that starts Codex inside a constrained Job Object.

Important implementation detail: child processes can be kept in the same job, making this useful for builds/tests spawned by Codex.

### Affinity

Process affinity restricts which logical CPUs a process may execute on.

Useful for reducing available parallelism, but it does not directly limit frequency or power and can sometimes reduce efficiency. Lower priority similarly affects contention rather than creating a real thermal ceiling.

Prefer Job Objects/cgroups if a hard workload cap is wanted.

### WSL cgroups / systemd CPUQuota

If Codex and its tools run inside WSL/systemd, a scope can impose a quota, e.g.:

```bash
systemd-run --user --scope -p CPUQuota=200% codex
```

Conceptually, 200% permits roughly two CPU cores worth of execution time.

This is useful for containing Linux process trees but does not constrain unrelated Windows-side work.

### Tool-specific worker limits

Many expensive tools expose their own parallelism controls:

- test runners → worker count
- build tools → job count
- compilers → parallel jobs
- Playwright → workers

These are efficient because they prevent excessive work rather than throttling it after scheduling. They are repository/tool-specific, so they are a complement rather than the Transit Mode foundation.

## Lenovo platform controls

### Fn+Q / Power Saving (Quiet)

The 83J3 supports Lenovo operation modes through Vantage/Lenovo software and Fn+Q. Lenovo documents that operation mode changes maximum attainable performance, power consumption, and fan-speed limits.

Power Saving (Quiet) is therefore potentially very useful.

It is not currently automated because we do not yet have a sufficiently trustworthy model-specific API to read the existing mode and restore it exactly. Manual use is safe if the user remembers their prior mode; automatic use conflicts with the project's revertability requirement until proven otherwise.

## AMD APU controls

### RyzenAdj

RyzenAdj can manipulate mobile Ryzen SMU limits including:

```text
STAPM limit       → sustained power
PPT FAST          → short/actual power limit
PPT SLOW          → average power limit
Tctl limit        → temperature ceiling
max GFX clock     → integrated GPU clock ceiling
APU skin temp     → platform skin-temperature control where supported
```

For this laptop, a future conservative experiment could try an APU envelope around 8–15 W rather than relying on Windows performance percentages.

However, RyzenAdj explicitly warns:

- OEM firmware can overwrite values when AC/DC state or power mode changes.
- Some systems periodically rewrite limits.
- It cannot reliably read "real factory defaults".
- There is no general reset-to-default operation without reboot because the defaults are platform/firmware-defined.

Therefore RyzenAdj is **not in v1**. Its power control is excellent; its exact revertability is not.

## GPU

The Ryzen 7 7735HS contains Radeon 680M integrated graphics. This machine does not need a separate dGPU-control strategy for the current configuration.

CPU and iGPU share the APU/platform power budget, so a future RyzenAdj package-power limit would naturally constrain both.

If needed, RyzenAdj also exposes a maximum GFX clock control.

## Monitoring / watchdog

The watchdog uses the LibreHardwareMonitor library to read AMD's CPU `Tctl/Tdie` control sensor. Windows' generic `Win32_TemperatureProbe` is not suitable: Microsoft documents that its real-time `CurrentReading` is not populated. Only CPU monitoring is enabled, which avoids unrelated motherboard/EC probing and keeps the worker small.

Reliability behavior:

- LibreHardwareMonitor 0.9.6 and its required DLLs are downloaded from the official GitHub release, pinned by version, and SHA-256 verified before loading.
- LibreHardwareMonitor's AMD path uses PawnIO to read SMN registers. The controller installs the official signed PawnIO 2.2.0 driver when missing, after verifying both its pinned SHA-256 and Authenticode signature. PawnIO is a shared system dependency and is intentionally not uninstalled by `off`.
- A hidden SYSTEM scheduled task starts the worker, restarts it after an unexpected failure, and has an at-startup trigger for recovery after a reboot.
- `on` waits for a fresh, valid CPU temperature before it reports success. Failure rolls the power plan and hibernation setting back.
- When hibernation is initially disabled, `on` checks that the system drive can hold Windows' full hibernation file before it persists recovery state or changes power configuration. Windows documents the full file's default size as 40% of physical memory.
- The worker samples every five seconds, writes an atomic latest-value heartbeat, and appends every sample—including missing-sensor intervals—to daily `thermal-YYYY-MM-DD.csv` files under `C:\ProgramData\TransitMode`. Thermal history is retained for 30 days. The separate `watchdog.log` records startup, periodic summaries, and exceptional events.
- 90 °C triggers immediate hibernation.
- Crossing 80 °C starts a 30-second hot timer. Cooling to 75 °C resets it; otherwise the system hibernates.
- Thirty seconds without a plausible sensor value triggers hibernation after monitoring has become healthy.
- Unexpected power-plan replacement or a fatal watchdog error triggers hibernation.
- `SetSuspendState(S4)` is primary and disables wake events so a timer cannot resume the laptop while it remains packed away. `shutdown.exe /h` is the state-preserving fallback. If both fail during an emergency, the worker uses an immediate forced shutdown rather than leave a hot, unmonitored machine running; that last resort can lose unsaved work.

These are conservative project thresholds, not manufacturer limits. AMD specifies 95 °C Tjmax for the Ryzen 7 7735HS.

The emergency path does not reactivate the normal plan first because that could re-enable boost while the laptop is already hot. Transit state remains in place after resume until `off` is run.

Current scope is intentionally CPU-only. It does not prove safe battery, SSD, skin, or bag temperature, so initial bag tests remain battery-only and progressive. Do not charge the laptop inside the bag.

## Operational controls

For initial bag testing:

- run on battery only,
- do not charge inside the bag,
- avoid physically blocking the bottom ventilation more than the actual use case requires,
- test progressively,
- deliberately include at least one heavy workload to establish worst-case behavior.

The Ryzen 7 7735HS has an AMD-specified maximum operating temperature (Tjmax) of 95 °C, but Transit Mode should operate comfortably below that; the goal is controlled low-power operation, not reliance on emergency thermal throttling.
