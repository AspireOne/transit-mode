# Codex-style benchmark

`codex-benchmark.sh` runs a repeatable approximation of frontend work for 15 minutes. It creates a disposable worktree of `$HOME/dev/optia/VK/frontend`, starts its dev server, repeatedly edits fixed TypeScript fixtures, requests the changed module, waits 15 seconds to represent API thinking time, then runs ESLint, a scoped Vitest test, and `pnpm check`.

The live frontend checkout and its uncommitted changes are not modified. The disposable worktree shares its existing `node_modules`, so the benchmark represents the normal warm development environment.

Set `CODEX_BENCHMARK_PROJECT` if your checkout is elsewhere.

Run from WSL:

```bash
cd /mnt/c/Users/matej/dev/transit-mode
./codex-benchmark.sh normal
./codex-benchmark.sh transit
```

The mode is verified against `transit-mode.ps1` before starting, preventing accidentally mislabeled results. To make a short experimental run, pass a whole number of minutes:

```bash
./codex-benchmark.sh normal 2
```

Results are written under `benchmark-results/<timestamp>-<mode>/`:

- `summary.txt` contains the mode, runtime, completed cycles, commit, and active power scheme.
- `timings.csv` contains one readable row per operation.
- `commands.log` and `server.log` contain details needed when a step fails.

Compare `Completed cycles` first, then compare corresponding step durations. Alternate modes (`normal`, `transit`, `normal`, `transit`) and keep charger state, background programs, and starting temperature comparable. The first pair is best treated as warm-up. Transit Mode temperatures remain in `C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv`; timestamps align with `timings.csv`.
