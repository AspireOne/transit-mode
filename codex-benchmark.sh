#!/usr/bin/env bash

# A repeatable, 15-minute approximation of a Codex frontend session.
# Run this inside WSL; it works only in a disposable git worktree.

set -uo pipefail

PROJECT="${CODEX_BENCHMARK_PROJECT:-$HOME/dev/optia/VK/frontend}"
DURATION_SECONDS=900
MODE="${1:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
DEV_PORT=41731

# Non-interactive WSL can inherit Windows pnpm ahead of NVM. The Windows shim
# cannot operate in the Linux /tmp worktree, so select the installed Node 24
# toolchain used by this project.
NVM_NODE_ROOT="${NVM_DIR:-$HOME/.nvm}/versions/node"
NODE_DIR="$(find "$NVM_NODE_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'v24.*' 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "$NODE_DIR" || ! -x "$NODE_DIR/bin/node" || ! -x "$NODE_DIR/bin/pnpm" ]]; then
    echo "A Linux NVM Node 24 installation with pnpm is required." >&2
    exit 1
fi
export PATH="$NODE_DIR/bin:$PATH"

usage() {
    echo "Usage: $0 normal|transit [duration-minutes]"
    echo "Example: $0 transit"
}

if [[ "$MODE" != "normal" && "$MODE" != "transit" ]]; then
    usage >&2
    exit 2
fi

if [[ -n "${2:-}" ]]; then
    if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "Duration must be a positive whole number of minutes." >&2
        exit 2
    fi
    duration_minutes="$2"
    DURATION_SECONDS=$((duration_minutes * 60))
fi

for command in git pnpm curl rg timeout setsid powershell.exe powercfg.exe; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is unavailable in WSL: $command" >&2
        exit 1
    fi
done

if [[ "$(command -v pnpm)" == /mnt/c/* ]]; then
    echo "pnpm resolved to a Windows executable; a Linux pnpm is required." >&2
    exit 1
fi

if [[ ! -d "$PROJECT/.git" && ! -f "$PROJECT/.git" ]]; then
    echo "Frontend git checkout not found: $PROJECT" >&2
    exit 1
fi

if [[ ! -d "$PROJECT/node_modules" ]]; then
    echo "Frontend dependencies are missing: $PROJECT/node_modules" >&2
    exit 1
fi

# Refuse mislabeled comparisons. "normal" specifically means Transit Mode is off.
TRANSIT_SCRIPT_WINDOWS="$(wslpath -w "$SCRIPT_DIR/transit-mode.ps1")"
TRANSIT_STATUS="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TRANSIT_SCRIPT_WINDOWS" status 2>&1 | tr -d '\r')"
if grep -q '^Transit Mode: ON' <<<"$TRANSIT_STATUS"; then
    DETECTED_MODE="transit"
elif grep -q '^Transit Mode: OFF' <<<"$TRANSIT_STATUS"; then
    DETECTED_MODE="normal"
else
    echo "Transit Mode is neither safely ON nor OFF; resolve its status before benchmarking." >&2
    printf '%s\n' "$TRANSIT_STATUS" >&2
    exit 1
fi

if [[ "$MODE" != "$DETECTED_MODE" ]]; then
    echo "Requested '$MODE', but the machine is currently '$DETECTED_MODE'." >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"
RUN_ID="$(date +'%Y-%m-%d_%H-%M-%S')-$MODE"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
mkdir "$RUN_DIR"
TIMINGS="$RUN_DIR/timings.csv"
COMMAND_LOG="$RUN_DIR/commands.log"
SERVER_LOG="$RUN_DIR/server.log"
SUMMARY="$RUN_DIR/summary.txt"
printf 'timestamp,cycle,step,duration_seconds,exit_code,result\n' >"$TIMINGS"

TEMP_ROOT="$(mktemp -d -t transit-codex-benchmark.XXXXXX)"
WORKTREE="$TEMP_ROOT/frontend"
WORKTREE_PROJECT="$WORKTREE/frontend"
SERVER_PID=""
WORKTREE_ADDED=false

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill -TERM -- "-$SERVER_PID" 2>/dev/null || true
        for _ in {1..20}; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$SERVER_PID" 2>/dev/null || true
    fi
    if [[ "$WORKTREE_ADDED" == true ]]; then
        git -C "$PROJECT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    fi
    rmdir "$TEMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

START_EPOCH="$(date +%s)"
DEADLINE=$((START_EPOCH + DURATION_SECONDS))
COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
POWER_SCHEME="$(powercfg.exe /getactivescheme 2>&1 | tr -d '\r' | sed 's/^[[:space:]]*//')"

log_result() {
    local cycle="$1" step="$2" started_ns="$3" exit_code="$4" result="$5"
    local ended_ns duration
    ended_ns="$(date +%s%N)"
    duration="$(awk -v start="$started_ns" -v end="$ended_ns" 'BEGIN { printf "%.3f", (end-start)/1000000000 }')"
    printf '%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$cycle" "$step" "$duration" "$exit_code" "$result" >>"$TIMINGS"
    printf '  %-18s %8ss  %s\n' "$step" "$duration" "$result"
}

run_step() {
    local cycle="$1" step="$2"
    shift 2
    local now remaining started_ns exit_code result
    now="$(date +%s)"
    remaining=$((DEADLINE - now))
    if ((remaining <= 0)); then
        return 124
    fi

    started_ns="$(date +%s%N)"
    {
        printf '\n===== cycle %s: %s (%s) =====\n' "$cycle" "$step" "$(date --iso-8601=seconds)"
        timeout --kill-after=5s "${remaining}s" "$@"
    } >>"$COMMAND_LOG" 2>&1
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        result="ok"
    elif [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
        result="deadline"
    else
        result="failed"
    fi
    log_result "$cycle" "$step" "$started_ns" "$exit_code" "$result"
    return "$exit_code"
}

write_fixture() {
    local cycle="$1"
    cat >"$WORKTREE_PROJECT/app/transit-benchmark.ts" <<EOF
export const benchmarkSeed = $cycle;

export function summarizeMeasurements(values: readonly number[]): number {
  return values.reduce((total, value) => total + value, benchmarkSeed);
}
EOF

    cat >"$WORKTREE_PROJECT/app/transit-benchmark.test.ts" <<EOF
import { describe, expect, it } from "vitest";

import { benchmarkSeed, summarizeMeasurements } from "./transit-benchmark";

describe("benchmark workload", () => {
  it("summarizes a stable sample", () => {
    expect(summarizeMeasurements([2, 3, 5, 8])).toBe(18 + benchmarkSeed);
  });
});
EOF
}

write_summary() {
    local status="$1" completed_cycles="$2"
    local ended elapsed
    ended="$(date +%s)"
    elapsed=$((ended - START_EPOCH))
    cat >"$SUMMARY" <<EOF
Codex-style frontend benchmark

Result:            $status
Requested mode:    $MODE (verified before start)
Requested runtime: $DURATION_SECONDS seconds
Actual runtime:    $elapsed seconds
Completed cycles:  $completed_cycles
Frontend commit:   $COMMIT
Power scheme:      $POWER_SCHEME

Step timings:      $TIMINGS
Command output:    $COMMAND_LOG
Dev-server output: $SERVER_LOG
Thermal history:   C:\ProgramData\TransitMode\thermal-YYYY-MM-DD.csv
EOF
}

echo "Codex-style frontend benchmark"
echo "  Mode:     $MODE (verified)"
echo "  Runtime:  $DURATION_SECONDS seconds"
echo "  Commit:   ${COMMIT:0:12}"
echo "  Results:  $RUN_DIR"
echo

echo "Preparing disposable worktree..."
setup_started="$(date +%s%N)"
if ! git -C "$PROJECT" worktree add --quiet --detach "$WORKTREE" "$COMMIT" >>"$COMMAND_LOG" 2>&1; then
    log_result 0 setup "$setup_started" 1 failed
    write_summary failed 0
    echo "Could not create the disposable worktree. See $COMMAND_LOG" >&2
    exit 1
fi
WORKTREE_ADDED=true
ln -s "$PROJECT/node_modules" "$WORKTREE_PROJECT/node_modules"
log_result 0 setup "$setup_started" 0 ok

cd "$WORKTREE_PROJECT" || {
    write_summary failed 0
    echo "Could not enter the disposable frontend: $WORKTREE_PROJECT" >&2
    exit 1
}
if ! run_step 0 typegen pnpm typegen; then
    write_summary failed 0
    echo "Initial type generation failed. See $COMMAND_LOG" >&2
    exit 1
fi

write_fixture 0
echo "Starting dev server..."
server_started="$(date +%s%N)"
setsid pnpm exec react-router dev --host 127.0.0.1 --port "$DEV_PORT" --strictPort >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
SERVER_READY=false
for _ in {1..900}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    if curl --fail --silent --output /dev/null "http://127.0.0.1:$DEV_PORT/app/transit-benchmark.ts"; then
        SERVER_READY=true
        break
    fi
    sleep 0.1
done

if [[ "$SERVER_READY" != true ]]; then
    log_result 0 server-start "$server_started" 1 failed
    write_summary failed 0
    echo "Dev server did not become ready. See $SERVER_LOG" >&2
    exit 1
fi
log_result 0 server-start "$server_started" 0 ok

COMPLETED_CYCLES=0
CYCLE=1
FINAL_STATUS="completed"

while (( $(date +%s) < DEADLINE )); do
    echo
    echo "Cycle $CYCLE"

    run_step "$CYCLE" explore bash -c 'rg -l "useQuery|useMutation" app | sort | sed -n "1,40p" >/dev/null && git diff --stat >/dev/null'
    step_status=$?
    if [[ $step_status -ne 0 ]]; then
        [[ $step_status -ne 124 && $step_status -ne 137 ]] && FINAL_STATUS="failed"
        break
    fi

    edit_started="$(date +%s%N)"
    write_fixture "$CYCLE"
    log_result "$CYCLE" edit "$edit_started" 0 ok

    run_step "$CYCLE" vite-request curl --fail --silent --output /dev/null "http://127.0.0.1:$DEV_PORT/app/transit-benchmark.ts?cycle=$CYCLE"
    step_status=$?
    if [[ $step_status -ne 0 ]]; then
        [[ $step_status -ne 124 && $step_status -ne 137 ]] && FINAL_STATUS="failed"
        break
    fi
    run_step "$CYCLE" api-wait sleep 15
    step_status=$?
    [[ $step_status -ne 0 ]] && break

    run_step "$CYCLE" eslint pnpm exec eslint --config eslint.fast.config.js app/transit-benchmark.ts app/transit-benchmark.test.ts
    step_status=$?
    if [[ $step_status -ne 0 ]]; then
        [[ $step_status -ne 124 && $step_status -ne 137 ]] && FINAL_STATUS="failed"
        break
    fi
    run_step "$CYCLE" tests pnpm test -- app/transit-benchmark.test.ts
    step_status=$?
    if [[ $step_status -ne 0 ]]; then
        [[ $step_status -ne 124 && $step_status -ne 137 ]] && FINAL_STATUS="failed"
        break
    fi
    run_step "$CYCLE" project-check pnpm check
    step_status=$?
    if [[ $step_status -ne 0 ]]; then
        [[ $step_status -ne 124 && $step_status -ne 137 ]] && FINAL_STATUS="failed"
        break
    fi

    COMPLETED_CYCLES=$CYCLE
    CYCLE=$((CYCLE + 1))
done

write_summary "$FINAL_STATUS" "$COMPLETED_CYCLES"
echo
echo "Benchmark $FINAL_STATUS: $COMPLETED_CYCLES complete cycle(s)."
echo "Summary: $SUMMARY"

if [[ "$FINAL_STATUS" == "failed" ]]; then
    exit 1
fi
