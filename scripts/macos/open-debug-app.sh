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
rich_text_testbook=0
rich_text_testbook_preflight=0
rich_text_testbook_report=""
rich_text_testbook_report_only=0
rich_text_testbook_snapshot=""
rich_text_testbook_snapshot_only=0
rich_text_testbook_window_report=""
rich_text_testbook_active_report=""
rich_text_testbook_active_report_only=0
rich_text_testbook_only=0
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
  --rich-text-testbook
                   Open the DEBUG rich text testbook window after launch
  --rich-text-testbook-only
                   Open only the DEBUG rich text testbook without normal app startup
  --rich-text-testbook-preflight
                   Write the default rich text report and contact-sheet artifacts, validate them, and exit
  --rich-text-testbook-report <path>
                   Write the DEBUG deterministic rich text testbook gate report
  --rich-text-testbook-report-only
                   Write the rich text testbook report and exit without opening the app window
  --rich-text-testbook-snapshot <path>
                   Write a DEBUG rich text testbook visual snapshot PNG
  --rich-text-testbook-snapshot-only
                   Write the rich text testbook snapshot and exit without opening the app window
  --rich-text-testbook-window-report <path>
                   Open the isolated DEBUG rich text testbook and write AppKit window state
  --rich-text-testbook-active-report <path>
                   Write the DEBUG inactive-window mouseDown diagnostic report
  --rich-text-testbook-active-report-only
                   Run the inactive-window mouseDown diagnostic and exit without LaunchServices/open
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
    --rich-text-testbook)
      rich_text_testbook=1
      shift
      ;;
    --rich-text-testbook-only)
      rich_text_testbook=1
      rich_text_testbook_only=1
      shift
      ;;
    --rich-text-testbook-preflight)
      rich_text_testbook=1
      rich_text_testbook_preflight=1
      rich_text_testbook_report_only=1
      rich_text_testbook_snapshot_only=1
      shift
      ;;
    --rich-text-testbook-report)
      if [[ $# -lt 2 ]]; then
        echo "--rich-text-testbook-report requires a path" >&2
        usage >&2
        exit 1
      fi
      rich_text_testbook=1
      rich_text_testbook_report="$2"
      shift 2
      ;;
    --rich-text-testbook-report-only)
      rich_text_testbook_report_only=1
      shift
      ;;
    --rich-text-testbook-snapshot)
      if [[ $# -lt 2 ]]; then
        echo "--rich-text-testbook-snapshot requires a path" >&2
        usage >&2
        exit 1
      fi
      rich_text_testbook=1
      rich_text_testbook_snapshot="$2"
      shift 2
      ;;
    --rich-text-testbook-snapshot-only)
      rich_text_testbook_snapshot_only=1
      shift
      ;;
    --rich-text-testbook-window-report)
      if [[ $# -lt 2 ]]; then
        echo "--rich-text-testbook-window-report requires a path" >&2
        usage >&2
        exit 1
      fi
      rich_text_testbook=1
      rich_text_testbook_only=1
      rich_text_testbook_window_report="$2"
      shift 2
      ;;
    --rich-text-testbook-active-report)
      if [[ $# -lt 2 ]]; then
        echo "--rich-text-testbook-active-report requires a path" >&2
        usage >&2
        exit 1
      fi
      rich_text_testbook=1
      rich_text_testbook_only=1
      rich_text_testbook_active_report="$2"
      shift 2
      ;;
    --rich-text-testbook-active-report-only)
      rich_text_testbook_active_report_only=1
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

window_report_value() {
  local key="$1"
  local path="$2"

  awk -F '=' -v key="${key}" '$1 == key { print $2; exit }' "${path}" 2>/dev/null || true
}

wait_until_window_report() {
  local path="$1"
  local expected_pid="$2"
  local i
  local report_pid
  local window_count
  local visible_window

  for i in {1..40}; do
    if [[ -f "${path}" ]]; then
      report_pid="$(window_report_value "process_id" "${path}")"
      window_count="$(window_report_value "window_count" "${path}")"
      visible_window="$(awk '/^window\[[0-9]+\]\./ && /visible=true/ { print "1"; exit }' "${path}" 2>/dev/null || true)"

      if [[ "${report_pid}" == "${expected_pid}" ]] && [[ "${window_count}" =~ ^[0-9]+$ ]] && (( window_count > 0 )) && [[ "${visible_window}" == "1" ]]; then
        if [[ "${verbose}" == "1" ]]; then
          echo "Rich text testbook window report:"
          cat "${path}"
        else
          {
            echo
            echo "### Rich text testbook window report"
            cat "${path}"
          } >>"${LOG_PATH}"
        fi
        return 0
      fi
    fi

    sleep 0.25
  done

  if [[ "${verbose}" != "1" && -f "${path}" ]]; then
    {
      echo
      echo "### Invalid rich text testbook window report"
      cat "${path}"
    } >>"${LOG_PATH}" || true
  fi

  return 1
}

active_report_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="${key}" '$1 == key { print $2; exit }' "${path}" 2>/dev/null || true
}

require_report_value() {
  local path="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(active_report_value "${key}" "${path}")"
  if [[ "${actual}" == "${expected}" ]]; then
    return 0
  fi

  echo "Rich text testbook report expected ${key}=${expected}, got ${actual:-<missing>}: ${path}" >&2
  return 1
}

require_report_contains() {
  local path="$1"
  local key="$2"
  local needle="$3"

  if awk -F= -v key="${key}" -v needle="${needle}" '$1 == key && index($0, needle) > 0 { found = 1 } END { exit found ? 0 : 1 }' "${path}" 2>/dev/null; then
    return 0
  fi

  echo "Rich text testbook report missing ${key} containing ${needle}: ${path}" >&2
  return 1
}

validate_requested_snapshot() {
  local path="$1"

  if [[ ! -s "${path}" ]]; then
    echo "Rich text testbook snapshot was not written or is empty: ${path}" >&2
    return 1
  fi

  if ! /usr/bin/file "${path}" | grep -q 'PNG image data'; then
    echo "Rich text testbook snapshot is not a PNG: ${path}" >&2
    /usr/bin/file "${path}" >&2 || true
    return 1
  fi
}

validate_rich_text_report() {
  local path="$1"

  if [[ ! -f "${path}" ]]; then
    echo "Rich text testbook report was not written: ${path}" >&2
    return 1
  fi

  if ! head -n 1 "${path}" | grep -q '^testbook gate ok'; then
    echo "Rich text testbook report did not start with a gate-ok line: ${path}" >&2
    head -n 20 "${path}" >&2 || true
    return 1
  fi

  if ! require_report_value "${path}" "failure_count" "0" ||
     ! require_report_value "${path}" "layout_failure_count" "0" ||
     ! require_report_value "${path}" "renderer_failure_count" "0" ||
     ! require_report_value "${path}" "live_row_failure_count" "0" ||
     ! require_report_value "${path}" "renderer_summary" "renderer gate ok" ||
     ! require_report_contains "${path}" "layout_summary" "layout gate ok" ||
     ! require_report_contains "${path}" "renderer_selection" "copy gate ok" ||
     ! require_report_contains "${path}" "renderer_selection" "plain + RTF" ||
     ! require_report_contains "${path}" "renderer_context_menus" "required 8/8" ||
     ! require_report_contains "${path}" "renderer_context_copy_actions" "required 3/3" ||
     ! require_report_contains "${path}" "renderer_media_clicks" "clickDispatchSource 0" ||
     ! require_report_contains "${path}" "renderer_media_clicks" "clickClosesPreview 0" ||
     ! require_report_contains "${path}" "renderer_media_clicks" "imageSourceMenu 0" ||
     ! require_report_contains "${path}" "renderer_media_clicks" "imageSourceCopy 0" ||
     ! require_report_contains "${path}" "renderer_visual_smoke" "visual smoke 4/4" ||
     ! require_report_contains "${path}" "renderer_drag_selection" "markers ok" ||
     ! require_report_contains "${path}" "renderer_spoiler_clicks" "revealed=true" ||
     ! require_report_contains "${path}" "live_row_summary" "live row gate ok" ||
     ! require_report_contains "${path}" "live_row_draft_streaming_summary" "draft streaming gate ok" ||
     ! require_report_contains "${path}" "live_row_controller_summary" "controller gate ok" ||
     ! require_report_contains "${path}" "live_row_visual_smoke_summary" "visual smoke gate ok"; then
    echo "Rich text testbook report failed: ${path}" >&2
    head -n 80 "${path}" >&2 || true
    return 1
  fi
}

wait_until_active_report() {
  local path="$1"
  local expected_pid="$2"
  local i
  local report_pid
  local failure_count

  for i in {1..40}; do
    if [[ -f "${path}" ]]; then
      report_pid="$(active_report_value "process_id" "${path}")"
      failure_count="$(active_report_value "active_failure_count" "${path}")"

      if [[ "${report_pid}" == "${expected_pid}" ]] && [[ "${failure_count}" == "0" ]]; then
        if [[ "${verbose}" == "1" ]]; then
          echo "Rich text testbook active interaction report:"
          cat "${path}"
        else
          {
            echo
            echo "### Rich text testbook active interaction report"
            cat "${path}"
          } >>"${LOG_PATH}"
        fi
        return 0
      fi
    fi

    sleep 0.25
  done

  if [[ "${verbose}" != "1" && -f "${path}" ]]; then
    {
      echo
      echo "### Invalid rich text testbook active interaction report"
      cat "${path}"
    } >>"${LOG_PATH}" || true
  fi

  return 1
}

open_debug_app() {
  local attempt
  local -a open_args=()
  local -a launch_args=()

  if [[ "${stop}" == "1" ]]; then
    open_args=(-n)
  fi
  if [[ "${rich_text_testbook}" == "1" ]]; then
    launch_args=(--args -ApplePersistenceIgnoreState YES)
    if [[ "${rich_text_testbook_only}" == "1" ]]; then
      launch_args+=(--rich-text-testbook-only)
    else
      launch_args+=(--rich-text-testbook)
    fi
  fi
  if [[ -n "${rich_text_testbook_report}" ]]; then
    launch_args+=(--rich-text-testbook-report "${rich_text_testbook_report}")
  fi
  if [[ -n "${rich_text_testbook_snapshot}" ]]; then
    launch_args+=(--rich-text-testbook-snapshot "${rich_text_testbook_snapshot}")
  fi
  if [[ -n "${rich_text_testbook_window_report}" ]]; then
    launch_args+=(--rich-text-testbook-window-report "${rich_text_testbook_window_report}")
  fi
  if [[ -n "${rich_text_testbook_active_report}" ]]; then
    launch_args+=(--rich-text-testbook-active-report "${rich_text_testbook_active_report}")
  fi

  for attempt in 1 2 3; do
    if (( ${#launch_args[@]} > 0 )); then
      if try_cmd "Open ${APP_NAME} (attempt ${attempt})" /usr/bin/open "${open_args[@]}" "${app_path}" "${launch_args[@]}"; then
        return 0
      fi
    else
      if try_cmd "Open ${APP_NAME} (attempt ${attempt})" /usr/bin/open "${open_args[@]}" "${app_path}"; then
        return 0
      fi
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
executable_path="$(build_setting EXECUTABLE_PATH)"

if [[ -z "${products_dir}" || -z "${product_name}" || -z "${executable_path}" ]]; then
  echo "Could not resolve Debug app path from xcodebuild settings." >&2
  exit 1
fi

app_path="${products_dir}/${product_name}"
app_executable_path="${products_dir}/${executable_path}"

if [[ ! -d "${app_path}" ]]; then
  echo "Debug app was not found at: ${app_path}" >&2
  echo "Run without --no-build to create it." >&2
  exit 1
fi

if [[ "${rich_text_testbook_preflight}" == "1" ]]; then
  preflight_stamp="${RICH_TEXT_TESTBOOK_STAMP:-$(date +%Y%m%d-%H%M%S)}"
  preflight_dir="${RICH_TEXT_TESTBOOK_ARTIFACT_DIR:-${HOME}/Library/Containers/chat.inline.InlineMac.debug/Data/tmp}"
  if [[ -z "${rich_text_testbook_report}" ]]; then
    rich_text_testbook_report="${preflight_dir}/inline-rich-text-testbook-report-preflight-${preflight_stamp}.txt"
  fi
  if [[ -z "${rich_text_testbook_snapshot}" ]]; then
    rich_text_testbook_snapshot="${preflight_dir}/rich-text-testbook-snapshot-preflight-${preflight_stamp}.png"
  fi
fi

if [[ -n "${rich_text_testbook_report}" && "${rich_text_testbook_report}" != /* ]]; then
  rich_text_testbook_report="${ROOT_DIR}/${rich_text_testbook_report}"
fi
if [[ -n "${rich_text_testbook_snapshot}" && "${rich_text_testbook_snapshot}" != /* ]]; then
  rich_text_testbook_snapshot="${ROOT_DIR}/${rich_text_testbook_snapshot}"
fi
if [[ -n "${rich_text_testbook_window_report}" && "${rich_text_testbook_window_report}" != /* ]]; then
  rich_text_testbook_window_report="${ROOT_DIR}/${rich_text_testbook_window_report}"
fi
if [[ -n "${rich_text_testbook_active_report}" && "${rich_text_testbook_active_report}" != /* ]]; then
  rich_text_testbook_active_report="${ROOT_DIR}/${rich_text_testbook_active_report}"
fi

if [[ "${rich_text_testbook_report_only}" == "1" && -z "${rich_text_testbook_report}" ]]; then
  echo "--rich-text-testbook-report-only requires --rich-text-testbook-report <path>" >&2
  exit 1
fi
if [[ "${rich_text_testbook_snapshot_only}" == "1" && -z "${rich_text_testbook_snapshot}" ]]; then
  echo "--rich-text-testbook-snapshot-only requires --rich-text-testbook-snapshot <path>" >&2
  exit 1
fi
if [[ "${rich_text_testbook_active_report_only}" == "1" && -z "${rich_text_testbook_active_report}" ]]; then
  echo "--rich-text-testbook-active-report-only requires --rich-text-testbook-active-report <path>" >&2
  exit 1
fi
if [[ -n "${rich_text_testbook_active_report}" && "${rich_text_testbook_active_report_only}" != "1" ]]; then
  echo "--rich-text-testbook-active-report currently requires --rich-text-testbook-active-report-only; active-window pointer review is manual." >&2
  exit 1
fi

log "Debug app: ${app_path}"

if [[ -n "${rich_text_testbook_report}" ]]; then
  mkdir -p "$(dirname "${rich_text_testbook_report}")"
fi
if [[ -n "${rich_text_testbook_snapshot}" ]]; then
  mkdir -p "$(dirname "${rich_text_testbook_snapshot}")"
fi
if [[ -n "${rich_text_testbook_window_report}" ]]; then
  mkdir -p "$(dirname "${rich_text_testbook_window_report}")"
fi
if [[ -n "${rich_text_testbook_active_report}" ]]; then
  mkdir -p "$(dirname "${rich_text_testbook_active_report}")"
fi

if [[ "${rich_text_testbook_report_only}" == "1" || "${rich_text_testbook_snapshot_only}" == "1" || "${rich_text_testbook_active_report_only}" == "1" ]]; then
  artifact_args=()
  if [[ -n "${rich_text_testbook_active_report}" ]]; then
    artifact_args+=(-ApplePersistenceIgnoreState YES)
  fi
  if [[ -n "${rich_text_testbook_report}" ]]; then
    artifact_args+=(--rich-text-testbook-report "${rich_text_testbook_report}")
  fi
  if [[ "${rich_text_testbook_report_only}" == "1" ]]; then
    artifact_args+=(--rich-text-testbook-report-only)
  fi
  if [[ -n "${rich_text_testbook_snapshot}" ]]; then
    artifact_args+=(--rich-text-testbook-snapshot "${rich_text_testbook_snapshot}")
  fi
  if [[ "${rich_text_testbook_snapshot_only}" == "1" ]]; then
    artifact_args+=(--rich-text-testbook-snapshot-only)
  fi
  if [[ -n "${rich_text_testbook_active_report}" ]]; then
    artifact_args+=(--rich-text-testbook-only --rich-text-testbook-active-report "${rich_text_testbook_active_report}")
  fi
  if [[ "${rich_text_testbook_active_report_only}" == "1" ]]; then
    artifact_args+=(--rich-text-testbook-active-report-only)
  fi
  run_cmd "Run rich text testbook artifacts" \
    "${app_executable_path}" \
    "${artifact_args[@]}"
  if [[ -n "${rich_text_testbook_report}" ]]; then
    validate_rich_text_report "${rich_text_testbook_report}"
  fi
  if [[ -n "${rich_text_testbook_snapshot}" ]]; then
    validate_requested_snapshot "${rich_text_testbook_snapshot}"
  fi
  if [[ -n "${rich_text_testbook_active_report}" ]]; then
    active_failure_count="$(active_report_value "active_failure_count" "${rich_text_testbook_active_report}")"
    if [[ "${active_failure_count}" != "0" ]]; then
      echo "Rich text testbook active interaction report failed: ${rich_text_testbook_active_report}" >&2
      if [[ -f "${rich_text_testbook_active_report}" ]]; then
        cat "${rich_text_testbook_active_report}" >&2
      fi
      exit 1
    fi
  fi
  if [[ "${rich_text_testbook_preflight}" == "1" ]]; then
    echo "Rich text testbook preflight passed."
    echo "Report: ${rich_text_testbook_report}"
    echo "Snapshot: ${rich_text_testbook_snapshot}"
  fi
  exit 0
fi

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

  if [[ -n "${rich_text_testbook_window_report}" ]]; then
    if wait_until_window_report "${rich_text_testbook_window_report}" "${pid}"; then
      log "Rich text testbook window report verified: ${rich_text_testbook_window_report}"
    else
      echo "Rich text testbook window report did not prove a visible window for pid ${pid}: ${rich_text_testbook_window_report}" >&2
      if [[ "${verbose}" != "1" ]]; then
        tail -n 120 "${LOG_PATH}" >&2 || true
      fi
      exit 1
    fi
  fi
  if [[ -n "${rich_text_testbook_active_report}" ]]; then
    if wait_until_active_report "${rich_text_testbook_active_report}" "${pid}"; then
      log "Rich text testbook active interaction report verified: ${rich_text_testbook_active_report}"
    else
      echo "Rich text testbook active interaction report failed for pid ${pid}: ${rich_text_testbook_active_report}" >&2
      if [[ "${verbose}" != "1" ]]; then
        tail -n 120 "${LOG_PATH}" >&2 || true
      fi
      exit 1
    fi
  fi
fi
