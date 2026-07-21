#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/macos/kill-simulator-processes.sh [--dry-run]

Shuts down all booted Apple Simulator devices, then terminates processes owned
by CoreSimulator. Processes that survive a short TERM grace period are killed.

Options:
  --dry-run  Print matching processes without shutting down or killing them.
  -h, --help Show this help.
EOF
}

dry_run=false

case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

# CoreSimulator launches many services with ordinary-looking names such as
# SpringBoard and locationd. Select their known roots by executable path/name,
# then include every descendant instead of matching those generic names.
snapshot_processes() {
  ps -axo pid=,ppid=,command=
}

find_simulator_pids() {
  awk -v self_pid="$$" '
    {
      pid = $1
      ppid = $2
      command = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", command)

      parent[pid] = ppid
      commands[pid] = command

      if (command ~ /\/CoreSimulator\.framework\// ||
        command ~ /\/Library\/Developer\/CoreSimulator\// ||
        command ~ /\/Simulator\.app\/Contents\/MacOS\/Simulator([[:space:]]|$)/ ||
        command ~ /(^|\/)SimulatorTrampoline([[:space:]]|$)/ ||
        command ~ /(^|\/)launchd_sim([[:space:]]|$)/ ||
        command ~ /(^|\/)simdiskimaged([[:space:]]|$)/ ||
        command ~ /(^|\/)CoreSimulatorService([[:space:]]|$)/ ||
        command ~ /(^|\/)CoreSimulatorBridge([[:space:]]|$)/ ||
        command ~ /(^|\/)SimStreamProcessorService([[:space:]]|$)/) {
        selected[pid] = 1
      }
    }

    END {
      selected[self_pid] = 0

      # Repeated passes find descendants at any depth without depending on the
      # order returned by ps.
      do {
        changed = 0
        for (pid in parent) {
          if (!selected[pid] && selected[parent[pid]]) {
            selected[pid] = 1
            changed = 1
          }
        }
      } while (changed)

      for (pid in selected) {
        if (selected[pid]) {
          print pid
        }
      }
    }
  '
}

describe_pids() {
  local pid

  for pid in "$@"; do
    ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null || true
  done
}

collect_pids() {
  local pid
  local output

  output="$(snapshot_processes | find_simulator_pids)"
  simulator_pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && simulator_pids+=("$pid")
  done <<< "$output"
}

shutdown_simulators() {
  local simctl_pid
  local attempt

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "warning: xcrun is unavailable; skipping graceful simctl shutdown" >&2
    return
  fi

  echo "Requesting graceful shutdown of all Simulator devices..."
  xcrun simctl shutdown all >/dev/null 2>&1 &
  simctl_pid=$!

  # Do not let a wedged CoreSimulator service hang this emergency helper.
  for attempt in {1..20}; do
    if ! kill -0 "$simctl_pid" 2>/dev/null; then
      wait "$simctl_pid" 2>/dev/null || true
      return
    fi
    sleep 0.25
  done

  echo "simctl did not return after 5 seconds; continuing with process cleanup." >&2
  kill -TERM "$simctl_pid" 2>/dev/null || true
}

terminate_pids() {
  local signal="$1"
  shift
  local pid

  for pid in "$@"; do
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

collect_surviving_pids() {
  local pid

  simulator_pids=()
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      simulator_pids+=("$pid")
    fi
  done
}

collect_pids

if $dry_run; then
  if [[ ${#simulator_pids[@]} -eq 0 ]]; then
    echo "No Simulator-related processes found."
    exit 0
  fi

  echo "Would terminate these Simulator-related processes:"
  describe_pids "${simulator_pids[@]}"
  exit 0
fi

shutdown_simulators
collect_pids

if [[ ${#simulator_pids[@]} -eq 0 ]]; then
  echo "No Simulator-related processes remain."
  exit 0
fi

echo "Sending TERM to these Simulator-related processes:"
describe_pids "${simulator_pids[@]}"
terminate_pids TERM "${simulator_pids[@]}"
terminated_pids=("${simulator_pids[@]}")

for attempt in {1..12}; do
  sleep 0.25
  collect_surviving_pids "${terminated_pids[@]}"
  [[ ${#simulator_pids[@]} -eq 0 ]] && break
done

if [[ ${#simulator_pids[@]} -gt 0 ]]; then
  echo "Force-killing processes that survived the 3-second grace period:"
  describe_pids "${simulator_pids[@]}"
  terminate_pids KILL "${simulator_pids[@]}"
  sleep 0.25
fi

# Catch CoreSimulator services that launchd may have restarted during cleanup.
collect_pids

if [[ ${#simulator_pids[@]} -gt 0 ]]; then
  echo "warning: some Simulator-related processes remain (they may have restarted):" >&2
  describe_pids "${simulator_pids[@]}" >&2
  exit 1
fi

echo "All Simulator-related processes were terminated."
