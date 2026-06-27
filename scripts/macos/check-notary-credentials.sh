#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="${NOTARY_CHECK_ENV_FILE:-"${ROOT_DIR}/scripts/.env"}"
LOAD_ENV=1
TIMEOUT_SECONDS=60

usage() {
  cat <<'USAGE'
Usage: check-notary-credentials.sh [--no-env-file] [--timeout SECONDS]

Validates the notarization credentials that build-direct.sh would use.
If scripts/.env exists, it is loaded without printing it.

Auth selection matches build-direct.sh:
  - APPLE_NOTARIZATION_KEY uses API key auth.
  - Otherwise APPLE_ID, APPLE_PASSWORD, and APPLE_TEAM_ID use Apple ID auth.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-env-file)
      LOAD_ENV=0
      shift
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --timeout" >&2
        exit 2
      fi
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT_SECONDS}" -lt 1 ]]; then
  echo "Invalid --timeout value: ${TIMEOUT_SECONDS}" >&2
  exit 2
fi

if [[ "${LOAD_ENV}" == "1" && -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}" >/dev/null
  set +a
fi

run_with_timeout() {
  local seconds="$1"
  shift

  "$@" &
  local pid=$!
  local marker
  marker=$(mktemp "${TMPDIR:-/tmp}/inline-notary-timeout.XXXXXX")
  rm -f "${marker}"

  (
    sleep "${seconds}"
    if kill "${pid}" >/dev/null 2>&1; then
      : > "${marker}"
    fi
  ) &
  local timer_pid=$!

  wait "${pid}"
  local ec=$?
  kill "${timer_pid}" >/dev/null 2>&1 || true
  wait "${timer_pid}" >/dev/null 2>&1 || true

  if [[ -f "${marker}" ]]; then
    rm -f "${marker}"
    return 124
  fi
  return "${ec}"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

missing_env() {
  local missing=()
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("${name}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Missing notarization credential env var(s): ${missing[*]}" >&2
    exit 1
  fi
}

fail_check() {
  local method="$1"
  local code="$2"
  if [[ "${code}" == "124" ]]; then
    echo "Notarization credential check timed out (${method})." >&2
  else
    echo "Notarization credential check failed (${method})." >&2
  fi
  echo "No credentials were printed. Verify the configured Apple credentials and team access." >&2
  exit 1
}

need_cmd xcrun

if [[ -n "${APPLE_NOTARIZATION_KEY:-}" ]]; then
  missing_env APPLE_NOTARIZATION_KEY_ID APPLE_NOTARIZATION_ISSUER

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/inline-notary-check.XXXXXX")
  key_path="${tmp_dir}/AuthKey.p8"
  cleanup() {
    rm -rf "${tmp_dir}"
  }
  trap cleanup EXIT

  umask 077
  printf '%s\n' "${APPLE_NOTARIZATION_KEY}" > "${key_path}"

  set +e
  run_with_timeout "${TIMEOUT_SECONDS}" \
    env -u APPLE_NOTARIZATION_KEY -u APPLE_PASSWORD \
    xcrun notarytool history \
      --key "${key_path}" \
      --key-id "${APPLE_NOTARIZATION_KEY_ID}" \
      --issuer "${APPLE_NOTARIZATION_ISSUER}" \
      --output-format json \
      --no-progress >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "${ec}" -eq 0 ]]; then
    echo "Notarization credentials are valid (API key)."
    exit 0
  fi
  fail_check "API key" "${ec}"
fi

missing_env APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID
need_cmd expect

set +e
NOTARY_CHECK_TIMEOUT_SECONDS="${TIMEOUT_SECONDS}" expect -c '
log_user 0
set timeout $env(NOTARY_CHECK_TIMEOUT_SECONDS)
spawn env -u APPLE_PASSWORD xcrun notarytool history --apple-id $env(APPLE_ID) --team-id $env(APPLE_TEAM_ID) --output-format json --no-progress
expect {
  -re "(?i)(password|app-specific).*:" { send -- "$env(APPLE_PASSWORD)\r"; exp_continue }
  eof { catch wait result; exit [lindex $result 3] }
  timeout { exit 124 }
}
' >/dev/null 2>&1
ec=$?
set -e

if [[ "${ec}" -eq 0 ]]; then
  echo "Notarization credentials are valid (Apple ID)."
  exit 0
fi
fail_check "Apple ID" "${ec}"
