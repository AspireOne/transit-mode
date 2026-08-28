# Transit Mode — Research Resources

Research snapshot: 2026-08-27.

This file preserves the source trail behind the current design so the project does not need to rediscover the same Windows/Lenovo/AMD behavior later.

## Hardware

### Lenovo IdeaPad Slim 5 15ARP10 / type 83J3

Lenovo's support portal identifies the machine as **IdeaPad Slim 5 15ARP10, Type 83J3**.

- [Lenovo Support — IdeaPad Slim 5 15ARP10, Type 83J3](https://pcsupport.lenovo.com/cz/cs/products/laptops-and-netbooks/ideapad-s-series-netbooks/ideapad-slim-5-15arp10/83j3)
- [Lenovo Support — Guides & Manuals for 83J3](https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/ideapad-s-series-netbooks/ideapad-slim-5-15arp10/83j3/83j30032kr/document-userguide)

Lenovo's user guide for this generation describes **System operation modes** selectable through Lenovo Vantage/Smart Engine/PC Manager or `Fn + Q`. Lenovo states that maximum attainable performance, power consumption, and heat-sink fan speed limits vary by operation mode; the modes include High Performance, Auto/Balance, and Power Saving/Quiet.

The Lenovo support portal above is the canonical entry point for the model-specific manual. A searchable extracted copy of the same generation's guide is also useful when the support site's dynamic document viewer is awkward:

- [IdeaPad Slim 5 (13″/15″, 10) User Guide — searchable extracted copy](https://www.scribd.com/document/918255119/Slim5-1315arp-Ug-En)

Key consequence: **Fn+Q Power Saving/Quiet is a real platform-level knob**, not merely a Windows UI preference. It can affect platform power and fan policy. We currently leave it untouched because exact automated state restoration has not yet been established.

### AMD Ryzen 7 7735HS

AMD's official specifications:

- 8 cores / 16 threads
- Zen 3+
- codename Rembrandt-R
- base 3.2 GHz
- boost up to 4.75 GHz
- default/configurable TDP 35–54 W
- Radeon 680M integrated graphics, 12 graphics cores, up to 2200 MHz
- maximum operating temperature (Tjmax) 95 °C
- not unlocked for overclocking

Sources:

- [AMD — Ryzen 7 7735HS official product page](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7735hs.html)
- [AMD — Ryzen 7000 mobile quick reference](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/ryzen-consumer-master-quick-reference-competitive.pdf)

Relevant inference: the Radeon 680M is integrated into the APU, so there is no need to design Transit Mode around a separate high-power discrete GPU for this configuration. A package-power control applied through the Ryzen SMU can potentially constrain CPU and iGPU activity within the same platform envelope.

## Windows power-plan controls

### `powercfg`

Microsoft documents `powercfg` as the supported command-line interface for power schemes, including querying/activating schemes and setting AC/DC indexes.

- [Microsoft Learn — Powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)

This enables the project's safest reversibility architecture:

```text
active plan A
    ↓ duplicate
temporary Transit plan T
    ↓ modify + activate
...
off
    ↓
reactivate untouched A
    ↓
delete T
```

The original plan does not need to be reconstructed because it is never edited.

### Lid close action

Microsoft's `LIDACTION` setting:

- GUID: `5ca83367-6e45-459f-a27b-476b1d01c936`
- `0` = Do Nothing
- `1` = Sleep
- `2` = Hibernate
- `3` = Shut Down

Source:

- [Microsoft Learn — Lid switch close action](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/power-button-and-lid-settings-lid-switch-close-action)

Current Transit Mode:

```text
LIDACTION → 0
```

### Sleep idle timeout

`STANDBYIDLE` specifies seconds before automatic idle sleep. `0` means **Never idle to sleep**.

- GUID: `29f6c1db-86da-48c5-9fdb-f2b67b1f44da`

Source:

- [Microsoft Learn — Sleep idle timeout](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/sleep-settings-sleep-idle-timeout)

Current Transit Mode:

```text
STANDBYIDLE → 0
```

### Processor boost

`PERFBOOSTMODE` determines processor boost behavior.

- GUID: `be337238-0d82-4146-a960-4f3749d470c7`
- `0` = Disabled
- higher values enable/aggressively request boost depending on the processor control model

Sources:

- [Microsoft Learn — PERFBOOSTMODE](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfboostmode)
- [Microsoft Learn — Windows power/performance tuning overview](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning)

Current Transit Mode:

```text
PERFBOOSTMODE → 0
```

### Energy Performance Preference / EPP

`PERFEPP` controls energy-versus-performance preference on CPPC systems.

- range: `0–100`
- `0` favors performance
- `100` favors energy savings

Source:

- [Microsoft Learn — PerfEnergyPreference / PERFEPP](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference)

Current Transit Mode:

```text
PERFEPP → 100
```

### Minimum / maximum processor performance

Windows exposes minimum and maximum processor performance as percentages of maximum performance.

Aliases:

- `PROCTHROTTLEMIN`
- `PROCTHROTTLEMAX`

Sources:

- [Microsoft Learn — power/performance tuning, minimum and maximum processor state](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning)
- [Microsoft Learn — processor performance-state static configuration overview](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/static-configuration-options-for-the-performance-state-engine)

Current Transit Mode:

```text
PROCTHROTTLEMIN → 5%
PROCTHROTTLEMAX → 50%
```

The 5% minimum is intentional: because Transit Mode clones an arbitrary active plan, this prevents an inherited high minimum (e.g. a High Performance-style configuration) from conflicting with the new maximum.

### Hard maximum frequency

`PROCFREQMAX` / `PROCFREQMAX1` can cap maximum processor performance by frequency in MHz rather than percentage.

Source:

- [Microsoft Learn — MaxFrequency / PROCFREQMAX](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-maxfrequency)

Potential future control; not currently enabled.

### Core parking

`CPMAXCORES` defines the maximum percentage of logical processors that may be unparked simultaneously.

Example from Microsoft: on 16 logical processors, 50% means at most eight logical processors unparked.

Sources:

- [Microsoft Learn — Core parking static options](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/static-configuration-options-for-core-parking)
- [Microsoft Learn — CPMaxCores](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-core-parking-cpmaxcores)

Potential future control; not currently enabled because more available low-clock cores may be more efficient than forcing fewer cores to run harder.

## Modern Standby and why it is not the solution

Modern Standby is a system sleep model, not a low-power "normal desktop execution" mode.

Microsoft documents that the Desktop Activity Moderator pauses desktop applications during Modern Standby. Desktop apps are prevented from continuing normal arbitrary execution after the system enters the low-power standby phases.

Sources:

- [Microsoft Learn — Modern Standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby)
- [Microsoft Learn — Integrating apps with Modern Standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/integrating-apps-with-modern-standby)
- [Microsoft Learn — Prepare software for Modern Standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/prepare-software-for-modern-standby)
- [Microsoft Learn — Windows desktop app lifecycle](https://learn.microsoft.com/en-us/windows/apps/develop/launch/app-lifecycle)

Consequence: Codex must keep the machine in the ordinary awake state. Transit Mode therefore deliberately uses `lid close → do nothing` rather than trying to make sleep execute Codex.

## Windows Energy Saver

Windows 11 24H2+ Energy Saver reduces system/app energy consumption and background work. Microsoft notes effects such as reduced background activity, reduced display brightness, and altered synchronization/update behavior.

Source:

- [Microsoft Learn — Energy Saver](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/energy-saver)

Potentially useful, but not currently automated because it is a broader global state outside the temporary cloned power scheme. Exact restoration should be implemented before Transit Mode changes it.

## Power requests

Windows exposes power requests such as:

- `PowerRequestSystemRequired`
- `PowerRequestExecutionRequired`

They can prevent automatic idle sleep or communicate that execution should continue.

Sources:

- [Microsoft Learn — PowerSetRequest](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-powersetrequest)
- [Microsoft Learn — powercfg `/requests`](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)

These are not required by v1 because Transit Mode directly sets idle sleep to never. They also do not turn an explicit sleep/lid-sleep transition into normal desktop execution.

## Per-process efficiency and CPU containment

### EcoQoS / Efficiency Mode

Windows supports `PROCESS_POWER_THROTTLING_EXECUTION_SPEED`. Opting a process into it classifies the workload as EcoQoS and tells Windows to favor power-efficient scheduling/performance states; Microsoft explicitly describes reduced heat/fan noise and longer battery life as goals.

Sources:

- [Microsoft Learn — SetProcessInformation / ProcessPowerThrottling](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)
- [Microsoft Learn — Quality of Service](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service)

Potential future feature: launch Codex itself as EcoQoS during Transit Mode.

### Windows Job Objects

Job Objects support CPU rate control.

`JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP` is a hard CPU-cycle limit for the processes in the job. `CpuRate` is expressed as percent × 100; e.g. `2000` means 20% of CPU capacity.

Source:

- [Microsoft Learn — JOBOBJECT_CPU_RATE_CONTROL_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_cpu_rate_control_information)

This is attractive for a future `transit-mode run codex`/launcher because a job can contain a process tree and prevent builds/tests spawned by Codex from consuming unrestricted CPU.

### Process affinity

Windows exposes `SetProcessAffinityMask`, restricting a process to selected logical processors. Affinity is inherited by child processes in normal cases.

Source:

- [Microsoft Learn — SetProcessAffinityMask](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask)

Affinity is a weaker thermal control than a power limit or Job Object CPU-rate cap. It limits where work can run, not how much power those processors may consume.

### Windows containers as corroboration for CPU-rate controls

Microsoft's container resource-control documentation maps CPU-percentage constraints to the same Job Object hard-cap mechanism for shared-kernel Windows containers.

- [Microsoft Learn — Implementing Windows container resource controls](https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/resource-controls)

## RyzenAdj / direct AMD APU control

RyzenAdj exposes mobile Ryzen SMU power-management controls including:

- `--stapm-limit` — sustained power limit, mW
- `--fast-limit` — PPT FAST / actual/short power limit, mW
- `--slow-limit` — PPT SLOW / average power limit, mW
- `--tctl-temp` — Tctl temperature limit, °C
- `--max-gfxclk` — maximum graphics clock
- `--apu-skin-temp` — APU skin temperature limit where supported
- current/EDC/TDC and other lower-level controls

Sources:

- [GitHub — FlyGoat/RyzenAdj](https://github.com/FlyGoat/RyzenAdj)
- [RyzenAdj README](https://github.com/FlyGoat/RyzenAdj/blob/master/README.md)
- [RyzenAdj Options wiki](https://github-wiki-see.page/m/FlyGoat/RyzenAdj/wiki/Options)

Example documented by RyzenAdj:

```text
--stapm-limit=45000
--fast-limit=45000
--slow-limit=45000
--tctl-temp=90
```

### Critical reversibility caveat

RyzenAdj's own FAQ says:

- values do not persist through reboot;
- changing AC/DC state or an OEM energy-saving mode can cause vendor-defined limits to overwrite RyzenAdj values;
- some devices rewrite limits periodically;
- `--info` can show current power-metric values;
- there is **no general reset-to-default operation without restart**, because RyzenAdj cannot know the actual firmware-defined defaults after the platform or other software has changed them.

Source:

- [RyzenAdj FAQ](https://github-wiki-see.page/m/FlyGoat/RyzenAdj/wiki/FAQ)

This is why direct PPT/STAPM control is **deferred**, despite being technically the best way to impose a literal wattage ceiling. It conflicts with the project's requirement that `transit-mode off` restore exactly the pre-Transit state.

RyzenAdj's own Windows readjust-service example also exists specifically to reapply settings after power-slider or AC-line changes:

- [RyzenAdj `readjustService.ps1`](https://github.com/FlyGoat/RyzenAdj/blob/master/win32/readjustService.ps1)

That reinforces the overwrite caveat.

## Monitoring

### Libre Hardware Monitor

Libre Hardware Monitor can monitor temperatures, fan speeds, voltages, load and clocks. Its `LibreHardwareMonitorLib` library can be embedded in a .NET application and can read AMD CPU, GPU, storage and other hardware sensors when supported by the platform.

Sources:

- [GitHub — LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
- [LibreHardwareMonitor 0.9.6 release](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/tag/v0.9.6)
- [LibreHardwareMonitor AMD 17h CPU sensor implementation](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Cpu/Amd17Cpu.cs)
- [LibreHardwareMonitor PawnIO implementation](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/PawnIo/PawnIo.cs)
- [Official PawnIO releases](https://github.com/namazso/PawnIO.Setup/releases)
- [Microsoft — `Win32_TemperatureProbe`](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-temperatureprobe)
- [Microsoft — `SetSuspendState`](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate)
- [Microsoft — system power states and hibernation-file sizes](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states)
- [Microsoft — scheduled-task restart-on-failure settings](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-restartonfailure-settingstype-element)

This is the current watchdog sensor source. Version 0.9.6 is pinned by release archive hash, and the required extracted DLLs are individually verified before use. Its AMD temperature implementation reads SMN registers through PawnIO, so the script installs the separately signed PawnIO 2.2.0 driver after verifying its installer. Microsoft documents that the generic WMI temperature class does not populate real-time readings, so it is not used as a fallback.

Current heartbeat/log fields:

```text
timestamp
CPU Tctl/Tdie temperature
watchdog state
hot duration
active Transit scheme
emergency/failure reason
```

### HWiNFO

HWiNFO64 Pro supports command-line sensor logging with configurable polling intervals and CSV/JSON output.

Source:

- [HWiNFO forum — supported HWiNFO64 Pro command-line parameters](https://www.hwinfo.com/forum/threads/supported-command-line-parameters-in-hwinfo64-pro.8549/)

Useful alternative if its exposed sensors are materially better on this Lenovo, though Libre Hardware Monitor is easier to integrate programmatically.

## Original remote-execution alternatives

These sources are retained because they motivated the local Transit Mode approach.

### Codex session resume

Current Codex supports resuming persisted threads/sessions. The Codex app-server API exposes `thread/resume`, and the CLI has a `resume` command.

Sources:

- [OpenAI Codex GitHub — app-server thread/resume documentation](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [OpenAI Codex GitHub — CLI resume implementation](https://github.com/openai/codex/blob/main/codex-rs/exec/src/cli.rs)

This shows that conversation state itself is transferable/resumable; it does **not** solve execution-environment migration.

### Parcels

Parcels implements exactly the proposed "ship repo + agent session to another machine" concept. It rsyncs the working tree and `.git`, transfers Codex/other-agent session state, and resumes remotely in tmux. It explicitly requires the target to have SSH, rsync, tmux and the relevant agent CLI.

Source:

- [GitHub — 0xSero/parcels](https://github.com/0xSero/parcels)

Why it was not chosen: copying the repository/session does not reproduce arbitrary installed runtimes, system libraries, MCP servers, browsers, credentials, services, OS state, local hardware or machine-specific tools.

### Codex remote control / mobile

OpenAI supports staying connected to active Codex work running across laptops/devboxes/remote environments from mobile.

Source:

- [OpenAI — Work with Codex from anywhere](https://openai.com/index/work-with-codex-from-anywhere/)

This improves remote *control*, but the execution host still needs to remain running. It therefore complements Transit Mode rather than replacing it.

## Current design conclusion

For this project, the hierarchy is:

```text
1. Keep execution on the real laptop
2. Keep Windows fully awake
3. Constrain power using reversible Windows power-plan settings
4. Measure real bag thermals
5. Add watchdog
6. Add stronger OEM/SMU/process controls only where measurement shows a need
7. Never trade exact revertability for a marginal optimization without making that trade explicit
```
