#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOG_PATH=${LOG_PATH:-"${ROOT_DIR}/.tmp/macos-grid-$(date +%Y%m%d-%H%M%S).log"}
history="2m"
grid_only=1
with_livekit=0

usage() {
  cat <<'EOF'
Usage: stream-grid-logs.sh [options]

Streams unified logs from both Inline macOS Debug profiles without building or launching either app.

Options:
  --all-inline      Show all Inline-owned app logs instead of only GRID_TRACE events
  --with-livekit    Include LiveKit SDK logs alongside Inline Grid trace events
  --last <duration> Show recent matching logs before streaming (default: 2m; use 0 to skip)
  -h, --help        Show help

Environment:
  LOG_PATH          Saved log path (default: .tmp/macos-grid-<timestamp>.log)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-inline)
      grid_only=0
      shift
      ;;
    --with-livekit)
      with_livekit=1
      shift
      ;;
    --last)
      if [[ $# -lt 2 ]]; then
        echo "--last requires a duration such as 30s, 2m, or 1h" >&2
        exit 1
      fi
      history="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

predicate='(subsystem == "chat.inline.InlineMac.debug" OR subsystem == "chat.inline.InlineMac.debug2" OR subsystem == "InlineMac")'
if [[ "${grid_only}" == "1" ]]; then
  predicate="${predicate} AND (eventMessage CONTAINS[c] \"GRID_TRACE\" OR eventMessage CONTAINS[c] \"GRID_ENGINE\")"
fi
if [[ "${with_livekit}" == "1" ]]; then
  predicate="(${predicate}) OR subsystem == \"io.livekit.sdk\""
fi

mkdir -p "$(dirname "${LOG_PATH}")"
: >"${LOG_PATH}"

echo "Watching Inline Debug + Debug2"
echo "Saving: ${LOG_PATH}"

if [[ "${history}" != "0" ]]; then
  /usr/bin/log show \
    --style compact \
    --debug \
    --last "${history}" \
    --predicate "${predicate}" \
    | tee -a "${LOG_PATH}"
fi

/usr/bin/log stream \
  --style compact \
  --level debug \
  --predicate "${predicate}" \
  | tee -a "${LOG_PATH}"
