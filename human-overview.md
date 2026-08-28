Transit Mode

CPU minimum state → 5%
CPU maximum state → 50%
CPU energy preference (EPP) → 100 / max efficiency
CPU boost → disabled
Lid close → do nothing
Idle sleep → never
AC + battery → same Transit settings
Watchdog → CPU temperature every 5 seconds
History → every reading in C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv (30 days)
Sensor access → verified LibreHardwareMonitor 0.9.6 + signed PawnIO 2.2.0 driver
Hibernate → 90 °C immediately, 80 °C hot band for 30 seconds, or 30 seconds without a sensor

on  → verify dependencies/storage → enable hibernation if needed → activate cloned plan → require healthy watchdog
off → stop watchdog → restore untouched plan → restore hibernation setting → clean up

Emergency → hibernate first → leave Transit plan/recovery state intact → run off after resuming
Emergency wake behavior → suppress wake events/timers while entering hibernation
Last resort → force shutdown only if both hibernation methods fail; unsaved work can be lost

Does not touch → Lenovo Fn+Q/Vantage, Energy Saver, RyzenAdj/firmware limits
Does not monitor → battery or chassis temperature; do not charge inside a bag
Leaves installed → PawnIO driver (shared sensor dependency)

