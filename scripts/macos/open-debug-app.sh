#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

PROJECT=${PROJECT:-"${ROOT_DIR}/apple/Inline.xcodeproj"}
SCHEME=${SCHEME:-"Inline (macOS)"}
CONFIGURATION=${CONFIGURATION:-Debug}
DESTINATION=${DESTINATION:-"platform=macOS"}
APP_NAME=${APP_NAME:-"Inline Debug"}
LOG_PATH=${LOG_PATH:-"${ROOT_DIR}/.tmp/macos-debug-$(date +%Y%m%d-%H%M%S).log"}

build=1
stop=1
open_app=1
verify=1
verbose=0
settings_file=$(mktemp)

cleanup() {
  rm -f "${settings_file}"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: open-debug-app.sh [options]

Builds and opens the regular Xcode Debug macOS app without launching Xcode.

Options:
  --no-build        Open the most recent Debug build without rebuilding
  --no-stop         Do not stop an already-running Inline Debug process
  --no-open         Build and resolve the app path, but do not launch it
  --no-verify       Do not verify that the process is running after launch
  --verbose         Show full command output
  -h, --help        Show help

Environment:
  PROJECT           Xcode project path
  SCHEME            Xcode scheme (default: Inline (macOS))
  CONFIGURATION     Build configuration (default: Debug)
  DESTINATION       xcodebuild destination (default: platform=macOS)
  APP_NAME          Process/app name (default: Inline Debug)
  LOG_PATH          Non-verbose command log path (default: .tmp/macos-debug-<timestamp>.log)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      build=0
      shift
      ;;
    --no-stop)
      stop=0
      shift
      ;;
    --no-open)
      open_app=0
      verify=0
      shift
      ;;
    --no-verify)
      verify=0
      shift
      ;;
    --verbose)
      verbose=1
      shift
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

if [[ "${verbose}" != "1" ]]; then
  mkdir -p "$(dirname "${LOG_PATH}")"
  : >"${LOG_PATH}"
  echo "Log: ${LOG_PATH}"
fi

xcode_args=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "${DESTINATION}"
)

log() {
  if [[ "${verbose}" == "1" ]]; then
    echo "$@"
  fi
}

run_cmd() {
  local desc="$1"
  shift

  if [[ "${verbose}" == "1" ]]; then
    echo "${desc}..."
    "$@"
    return
  fi

  {
    echo
    echo "### ${desc}"
    printf '$'
    printf ' %q' "$@"
    echo
  } >>"${LOG_PATH}"

  if ! "$@" >>"${LOG_PATH}" 2>&1; then
    echo "${desc} failed. Log: ${LOG_PATH}" >&2
    tail -n 120 "${LOG_PATH}" >&2 || true
    return 1
  fi
}

try_cmd() {
  local desc="$1"
  shift

  if [[ "${verbose}" == "1" ]]; then
    echo "${desc}..."
    "$@"
    return
  fi

  {
    echo
    echo "### ${desc}"
    printf '$'
    printf ' %q' "$@"
    echo
  } >>"${LOG_PATH}"

  "$@" >>"${LOG_PATH}" 2>&1
}

capture_cmd() {
  local desc="$1"
  local output_path="$2"
  shift 2

  if [[ "${verbose}" == "1" ]]; then
    echo "${desc}..."
    "$@" | tee "${output_path}"
    return
  fi

  {
    echo
    echo "### ${desc}"
    printf '$'
    printf ' %q' "$@"
    echo
  } >>"${LOG_PATH}"

  if ! "$@" >"${output_path}" 2>>"${LOG_PATH}"; then
    cat "${output_path}" >>"${LOG_PATH}" 2>/dev/null || true
    echo "${desc} failed. Log: ${LOG_PATH}" >&2
    tail -n 120 "${LOG_PATH}" >&2 || true
    return 1
  fi

  cat "${output_path}" >>"${LOG_PATH}"
}

build_setting() {
  local key="$1"

  awk -F ' = ' -v key="${key}" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' "${settings_file}"
}

pids_for_app() {
  /usr/bin/pgrep -x "${APP_NAME}" 2>/dev/null || true
}

pid_in_list() {
  local needle="$1"
  local pids="$2"
  local pid

  for pid in ${pids}; do
    if [[ "${pid}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

debugserver_parent_pids() {
  local pids="$1"
  local pid
  local parent
  local args

  for pid in ${pids}; do
    parent="$(/bin/ps -p "${pid}" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')"
    if [[ -z "${parent}" || "${parent}" == "1" ]]; then
      continue
    fi

    args="$(/bin/ps -p "${parent}" -o args= 2>/dev/null || true)"
    if [[ "${args}" == *"/debugserver "* || "${args}" == *" debugserver "* || "${args}" == *"/debugserver" ]]; then
      echo "${parent}"
    fi
  done | /usr/bin/sort -u
}

wait_until_stopped() {
  local attempts="${1:-30}"
  local delay="${2:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    if [[ -z "$(pids_for_app)" ]]; then
      return 0
    fi

    sleep "${delay}"
  done

  return 1
}

stop_existing_app() {
  local app_pids
  local debugger_pids

  app_pids="$(pids_for_app)"
  app_pids="${app_pids:-}"
  if [[ -z "${app_pids}" ]]; then
    return 0
  fi

  log "Stopping existing ${APP_NAME}..."

  run_cmd "Terminate existing ${APP_NAME}" /bin/kill -TERM ${app_pids} || true

  if wait_until_stopped 30 0.2; then
    return 0
  fi

  app_pids="$(pids_for_app)"
  debugger_pids="$(debugserver_parent_pids "${app_pids}")"
  if [[ -n "${debugger_pids}" ]]; then
    run_cmd "Terminate debugserver for ${APP_NAME}" /bin/kill -TERM ${debugger_pids} || true
  fi

  if wait_until_stopped 20 0.2; then
    return 0
  fi

  app_pids="$(pids_for_app)"
  debugger_pids="$(debugserver_parent_pids "${app_pids}")"
  if [[ -n "${debugger_pids}" ]]; then
    run_cmd "Force stop debugserver for ${APP_NAME}" /bin/kill -KILL ${debugger_pids} || true
  fi
  if [[ -n "${app_pids}" ]]; then
    run_cmd "Force stop existing ${APP_NAME}" /bin/kill -KILL ${app_pids} || true
  fi

  if wait_until_stopped 20 0.2; then
    return 0
  fi

  echo "${APP_NAME} did not stop in time after terminate and force-stop attempts. Continuing with a new app instance." >&2
  return 0
}

wait_until_running() {
  local previous_pids="${1:-}"
  local i
  local pid

  for i in {1..40}; do
    for pid in $(pids_for_app); do
      if [[ -z "${previous_pids}" ]] || ! pid_in_list "${pid}" "${previous_pids}"; then
        echo "${pid}"
        return 0
      fi
    done

    sleep 0.25
  done

  return 1
}

open_debug_app() {
  local attempt
  local -a open_args=()

  if [[ "${stop}" == "1" ]]; then
    open_args=(-n)
  fi

  for attempt in 1 2 3; do
    if try_cmd "Open ${APP_NAME} (attempt ${attempt})" /usr/bin/open "${open_args[@]}" "${app_path}"; then
      return 0
    fi

    sleep 0.75
  done

  echo "Open ${APP_NAME} failed. Log: ${LOG_PATH}" >&2
  if [[ "${verbose}" != "1" ]]; then
    tail -n 120 "${LOG_PATH}" >&2 || true
  fi
  return 1
}

if [[ "${build}" == "1" ]]; then
  run_cmd "Build ${SCHEME} (${CONFIGURATION})" xcodebuild "${xcode_args[@]}" build
fi

capture_cmd "Resolve macOS Debug app settings" "${settings_file}" xcodebuild "${xcode_args[@]}" -showBuildSettings

products_dir="$(build_setting BUILT_PRODUCTS_DIR)"
product_name="$(build_setting FULL_PRODUCT_NAME)"

if [[ -z "${products_dir}" || -z "${product_name}" ]]; then
  echo "Could not resolve Debug app path from xcodebuild settings." >&2
  exit 1
fi

app_path="${products_dir}/${product_name}"

if [[ ! -d "${app_path}" ]]; then
  echo "Debug app was not found at: ${app_path}" >&2
  echo "Run without --no-build to create it." >&2
  exit 1
fi

log "Debug app: ${app_path}"

if [[ "${open_app}" != "1" ]]; then
  exit 0
fi

previous_pids=""
if [[ "${stop}" == "1" ]]; then
  previous_pids="$(pids_for_app)"
  stop_existing_app
fi

log "Opening ${APP_NAME}..."
open_debug_app

if [[ "${verify}" == "1" ]]; then
  pid="$(wait_until_running "${previous_pids}")"
  log "${APP_NAME} is running (pid ${pid})."
fi
