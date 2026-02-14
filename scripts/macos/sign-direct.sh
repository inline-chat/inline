#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [[ -f "${ROOT_DIR}/scripts/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ROOT_DIR}/scripts/.env"
  set +a
fi

DERIVED_DATA=${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirect"}
APP_PATH=${APP_PATH:-"${DERIVED_DATA}/Build/Products/Release/Inline.app"}
ENTITLEMENTS_PATH=${ENTITLEMENTS_PATH:-"${ROOT_DIR}/apple/InlineMac/InlineMacDirect.entitlements"}
OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-direct"}
MACOS_PROVISIONING_PROFILE_BASE64=${MACOS_PROVISIONING_PROFILE_BASE64:-""}
MACOS_PROVISIONING_PROFILE_PATH=${MACOS_PROVISIONING_PROFILE_PATH:-""}
SIGN_RETRY_COUNT=${SIGN_RETRY_COUNT:-3}
SIGN_RETRY_DELAY_SECONDS=${SIGN_RETRY_DELAY_SECONDS:-2}
EFFECTIVE_ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH}"

usage() {
  cat <<'EOF'
Usage: sign-direct.sh [options]

Signs an existing Inline macOS app bundle (including Sparkle helpers/frameworks).

Options:
  --app-path <path>                      Path to Inline.app
  --derived-data <path>                  Xcode derived data (used when --app-path is omitted)
  --entitlements-path <path>             Entitlements plist path
  --output-dir <path>                    Output/temp dir for generated entitlements/profile
  --retry-count <n>                      Timestamp signing retry count (default: 3)
  --retry-delay-seconds <n>              Retry delay in seconds (default: 2)
  --provisioning-profile-path <path>     Provisioning profile file path (optional)
  -h, --help                             Show help

Required env:
  MACOS_CERTIFICATE_NAME

Optional env:
  MACOS_PROVISIONING_PROFILE_BASE64
  MACOS_PROVISIONING_PROFILE_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      shift 2
      ;;
    --entitlements-path)
      ENTITLEMENTS_PATH="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --retry-count)
      SIGN_RETRY_COUNT="${2:-}"
      shift 2
      ;;
    --retry-delay-seconds)
      SIGN_RETRY_DELAY_SECONDS="${2:-}"
      shift 2
      ;;
    --provisioning-profile-path)
      MACOS_PROVISIONING_PROFILE_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${MACOS_CERTIFICATE_NAME:-}" ]]; then
  echo "MACOS_CERTIFICATE_NAME is required" >&2
  exit 1
fi

if [[ -n "${DERIVED_DATA}" && -z "${APP_PATH}" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/Inline.app"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found at ${APP_PATH}" >&2
  exit 1
fi

if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "Entitlements file not found: ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi

entitlement_exists() {
  /usr/libexec/PlistBuddy -c "Print :$1" "${ENTITLEMENTS_PATH}" >/dev/null 2>&1
}

if [[ -z "${MACOS_PROVISIONING_PROFILE_BASE64}" && -z "${MACOS_PROVISIONING_PROFILE_PATH}" ]]; then
  if entitlement_exists "com.apple.developer.aps-environment" || entitlement_exists "keychain-access-groups"; then
    echo "MACOS_PROVISIONING_PROFILE_BASE64 or MACOS_PROVISIONING_PROFILE_PATH is required for APS/keychain entitlements." >&2
    exit 1
  fi
fi

if [[ -n "${MACOS_PROVISIONING_PROFILE_PATH}" && ! -f "${MACOS_PROVISIONING_PROFILE_PATH}" ]]; then
  echo "MACOS_PROVISIONING_PROFILE_PATH not found: ${MACOS_PROVISIONING_PROFILE_PATH}" >&2
  exit 1
fi

signature_has_timestamp() {
  local path="$1"
  local signature_details
  signature_details=$(/usr/bin/codesign -dv --verbose=4 "${path}" 2>&1 || true)
  [[ "${signature_details}" == *"Timestamp="* ]]
}

prepare_effective_entitlements() {
  if [[ -z "${MACOS_PROVISIONING_PROFILE_BASE64}" && -z "${MACOS_PROVISIONING_PROFILE_PATH}" ]]; then
    return 0
  fi

  mkdir -p "${OUTPUT_DIR}"
  local profile_path="${OUTPUT_DIR}/embedded.provisionprofile"

  if [[ -n "${MACOS_PROVISIONING_PROFILE_BASE64}" ]]; then
    if base64 -D >/dev/null 2>&1 <<<""; then
      echo "${MACOS_PROVISIONING_PROFILE_BASE64}" | base64 -D > "${profile_path}"
    else
      echo "${MACOS_PROVISIONING_PROFILE_BASE64}" | base64 --decode > "${profile_path}"
    fi
  else
    cp "${MACOS_PROVISIONING_PROFILE_PATH}" "${profile_path}"
  fi

  local profile_plist
  profile_plist=$(mktemp)
  security cms -D -i "${profile_path}" > "${profile_plist}"
  local profile_uuid
  profile_uuid=$(/usr/libexec/PlistBuddy -c "Print :UUID" "${profile_plist}")
  local profile_team_id
  profile_team_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "${profile_plist}")
  local profile_aps_env
  profile_aps_env=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.aps-environment" "${profile_plist}" 2>/dev/null || true)
  rm -f "${profile_plist}"

  if [[ -z "${profile_uuid}" || -z "${profile_team_id}" ]]; then
    echo "Provisioning profile is missing UUID or team identifier." >&2
    exit 1
  fi

  mkdir -p "${HOME}/Library/MobileDevice/Provisioning Profiles"
  cp "${profile_path}" "${HOME}/Library/MobileDevice/Provisioning Profiles/${profile_uuid}.provisionprofile"
  cp "${profile_path}" "${APP_PATH}/Contents/embedded.provisionprofile"

  EFFECTIVE_ENTITLEMENTS_PATH="${OUTPUT_DIR}/InlineMacDirect.entitlements"
  cp "${ENTITLEMENTS_PATH}" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  local app_prefix="${profile_team_id}."
  perl -pi -e "s/\\$\\(TeamIdentifierPrefix\\)/${app_prefix}/g; s/\\$\\(AppIdentifierPrefix\\)/${app_prefix}/g" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  if [[ -n "${profile_aps_env}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment ${profile_aps_env}" "${EFFECTIVE_ENTITLEMENTS_PATH}" \
      || /usr/libexec/PlistBuddy -c "Add :com.apple.developer.aps-environment string ${profile_aps_env}" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  fi
}

codesign_path() {
  local path="$1"
  shift
  local attempts=0
  local sign_output
  local sign_ec
  local -a sign_cmd=(/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime --timestamp)

  if [[ "$#" -gt 0 ]]; then
    sign_cmd+=("$@")
  fi
  sign_cmd+=("${path}")

  while [[ "${attempts}" -lt "${SIGN_RETRY_COUNT}" ]]; do
    set +e
    sign_output=$("${sign_cmd[@]}" 2>&1)
    sign_ec=$?
    set -e

    if [[ "${sign_ec}" -ne 0 ]]; then
      attempts=$((attempts + 1))
      if [[ "${attempts}" -lt "${SIGN_RETRY_COUNT}" ]]; then
        echo "codesign failed for ${path}; retrying (${attempts}/${SIGN_RETRY_COUNT})..." >&2
        echo "${sign_output}" >&2
        sleep "${SIGN_RETRY_DELAY_SECONDS}"
        continue
      fi
      echo "Failed to codesign after ${SIGN_RETRY_COUNT} attempts: ${path}" >&2
      echo "${sign_output}" >&2
      exit 1
    fi

    if signature_has_timestamp "${path}"; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [[ "${attempts}" -lt "${SIGN_RETRY_COUNT}" ]]; then
      echo "Timestamp missing after signing ${path}; retrying (${attempts}/${SIGN_RETRY_COUNT})..." >&2
      sleep "${SIGN_RETRY_DELAY_SECONDS}"
    fi
  done

  echo "Failed to add secure timestamp after ${SIGN_RETRY_COUNT} attempts: ${path}" >&2
  /usr/bin/codesign -dv --verbose=4 "${path}" 2>&1 || true
  exit 1
}

verify_codesign_timestamp() {
  local path="$1"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${path}"
  if ! signature_has_timestamp "${path}"; then
    echo "Code signature missing timestamp: ${path}" >&2
    exit 1
  fi
}

codesign_if_exists() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    codesign_path "${path}"
  fi
}

prepare_effective_entitlements

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
SPARKLE_FRAMEWORK="${FRAMEWORKS_DIR}/Sparkle.framework"

if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
  SPARKLE_CURRENT="${SPARKLE_FRAMEWORK}/Versions/Current"
  codesign_if_exists "${SPARKLE_CURRENT}/XPCServices/Downloader.xpc"
  codesign_if_exists "${SPARKLE_CURRENT}/XPCServices/Installer.xpc"
  codesign_if_exists "${SPARKLE_CURRENT}/Autoupdate"
  codesign_if_exists "${SPARKLE_CURRENT}/Updater.app"
  codesign_path "${SPARKLE_FRAMEWORK}"
fi

if [[ -d "${FRAMEWORKS_DIR}" ]]; then
  for framework in "${FRAMEWORKS_DIR}"/*.framework; do
    if [[ -d "${framework}" && "${framework}" != "${SPARKLE_FRAMEWORK}" ]]; then
      codesign_path "${framework}"
    fi
  done
fi

codesign_path "${APP_PATH}" --entitlements "${EFFECTIVE_ENTITLEMENTS_PATH}"

verify_codesign_timestamp "${APP_PATH}"
find "${APP_PATH}/Contents" -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -print0 \
  | while IFS= read -r -d '' bundle; do
      verify_codesign_timestamp "${bundle}"
    done

echo "Signing complete: ${APP_PATH}"
