Transit Mode

CPU minimum state → 5%
CPU maximum state → 45%
CPU energy preference (EPP) → 100 / max efficiency
CPU boost → disabled
Lid close → do nothing
Idle sleep → never
Wake timers → disabled
AC + battery → same Transit settings
Watchdog → CPU temperature every 5 seconds
History → every reading in C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv (30 days)
Sensor access → verified LibreHardwareMonitor 0.9.6 + signed PawnIO 2.2.0 driver
Hibernate → 82 °C immediately, 80 °C hot band for 30 seconds, or 22 seconds without a sensor

on  → require full hibernation → verify dependencies → arm watchdog → activate clone → require healthy heartbeat
off → restore and verify original plan → stop watchdog → clean up; failed restoration keeps monitoring

Emergency → restore original plan → hibernate → run off after resuming to finish cleanup
Failed emergency restoration → retry restoration and hibernation after resume
Monitoring gap → more than 20 seconds triggers emergency recovery; timers use monotonic time
Emergency wake behavior → native path requests wake suppression; shutdown.exe fallback cannot
Last resort → force shutdown only if both hibernation methods fail; unsaved work can be lost

Does not touch → hibernation configuration, Lenovo Fn+Q/Vantage, Energy Saver, RyzenAdj/firmware limits
Concurrent commands → rejected by an exclusive controller lock
Does not monitor → battery or chassis temperature; do not charge inside a bag
Leaves installed → PawnIO driver (shared sensor dependency)
