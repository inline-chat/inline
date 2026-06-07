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

pid_for_app() {
  /usr/bin/pgrep -x "${APP_NAME}" 2>/dev/null | /usr/bin/head -n 1 || true
}

wait_until_stopped() {
  local i

  for i in {1..30}; do
    if [[ -z "$(pid_for_app)" ]]; then
      return 0
    fi

    sleep 0.2
  done

  return 1
}

wait_until_running() {
  local i
  local pid

  for i in {1..40}; do
    pid="$(pid_for_app)"
    if [[ -n "${pid}" ]]; then
      echo "${pid}"
      return 0
    fi

    sleep 0.25
  done

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

if [[ "${stop}" == "1" && -n "$(pid_for_app)" ]]; then
  log "Stopping existing ${APP_NAME}..."
  run_cmd "Stop existing ${APP_NAME}" /usr/bin/pkill -x "${APP_NAME}" || true

  if ! wait_until_stopped; then
    echo "${APP_NAME} did not stop in time. Close it and retry, or pass --no-stop to reuse it." >&2
    exit 1
  fi
fi

log "Opening ${APP_NAME}..."
run_cmd "Open ${APP_NAME}" /usr/bin/open "${app_path}"

if [[ "${verify}" == "1" ]]; then
  pid="$(wait_until_running)"
  log "${APP_NAME} is running (pid ${pid})."
fi
