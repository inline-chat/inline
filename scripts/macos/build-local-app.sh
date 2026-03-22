#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

SPARKLE_VERSION=${SPARKLE_VERSION:-2.7.3}
SCHEME=${SCHEME:-"Inline (macOS)"}
CHANNEL=${CHANNEL:-stable}
APPCAST_URL=${APPCAST_URL:-"https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"}
SPARKLE_SCHEDULED_CHECK_INTERVAL=${SPARKLE_SCHEDULED_CHECK_INTERVAL:-3600}
SPARKLE_DIR=${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle"}
DERIVED_DATA=${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirectLocal"}
APP_PATH=${APP_PATH:-"${DERIVED_DATA}/Build/Products/Release/Inline.app"}
OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-local-app"}
BUILD_LOG_PATH="${OUTPUT_DIR}/xcodebuild.log"

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" && -n "${MACOS_SPARKLE_PUBLIC_KEY:-}" ]]; then
  SPARKLE_PUBLIC_KEY="${MACOS_SPARKLE_PUBLIC_KEY}"
fi

usage() {
  cat <<'EOF'
Usage: build-local-app.sh [options]

Builds a local Sparkle-enabled Inline.app for testing without signing, DMG
creation, notarization, or upload steps.

Options:
  --channel <stable|beta>         Update channel to embed in Info.plist
  --derived-data <path>           Xcode derived data path
  --app-path <path>               App bundle output path
  --sparkle-dir <path>            Sparkle download/cache directory
  --scheme <name>                 Xcode scheme (default: Inline (macOS))
  -h, --help                      Show help

Optional env:
  SPARKLE_PUBLIC_KEY              Embedded into SUPublicEDKey when set
  MACOS_SPARKLE_PUBLIC_KEY        Alias for SPARKLE_PUBLIC_KEY
  APPCAST_URL                     Override Sparkle feed URL
  SPARKLE_SCHEDULED_CHECK_INTERVAL Override Sparkle check interval in seconds
EOF
}

resolve_path() {
  local value="$1"
  if [[ "${value}" == /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${ROOT_DIR}/${value}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      if [[ "${CHANNEL}" != "stable" && "${CHANNEL}" != "beta" ]]; then
        echo "Invalid --channel: ${CHANNEL}" >&2
        exit 1
      fi
      APPCAST_URL="https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="$(resolve_path "${2:-}")"
      APP_PATH="${DERIVED_DATA}/Build/Products/Release/Inline.app"
      shift 2
      ;;
    --app-path)
      APP_PATH="$(resolve_path "${2:-}")"
      shift 2
      ;;
    --sparkle-dir)
      SPARKLE_DIR="$(resolve_path "${2:-}")"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
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

for cmd in xcodebuild curl unzip rsync git; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

mkdir -p "${SPARKLE_DIR}" "${OUTPUT_DIR}"

if [[ ! -f "${SPARKLE_DIR}/Sparkle.xcframework/Info.plist" ]]; then
  curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip" \
    -o "${SPARKLE_DIR}/sparkle.zip"
  unzip -o "${SPARKLE_DIR}/sparkle.zip" -d "${SPARKLE_DIR}"
fi

SPARKLE_FRAMEWORK_PATH="${SPARKLE_DIR}/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "${SPARKLE_FRAMEWORK_PATH}" ]]; then
  echo "Sparkle framework path not found: ${SPARKLE_FRAMEWORK_PATH}" >&2
  exit 1
fi

set +e
swift_conditions='$(inherited) SPARKLE DEBUG_BUILD'

xcodebuild_args=(
  -project "${ROOT_DIR}/apple/Inline.xcodeproj"
  -scheme "${SCHEME}"
  -configuration Release
  -derivedDataPath "${DERIVED_DATA}"
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=${swift_conditions}"
  "FRAMEWORK_SEARCH_PATHS=${SPARKLE_FRAMEWORK_PATH}"
  "OTHER_LDFLAGS=-framework Sparkle"
  "CODE_SIGN_ENTITLEMENTS=InlineMac/InlineMacDirect.entitlements"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_STYLE=Manual
  PROVISIONING_PROFILE_SPECIFIER=
)
xcodebuild_args+=("ASSETCATALOG_COMPILER_APPICON_NAME=InlineDebugAppIcon")

xcodebuild \
  "${xcodebuild_args[@]}" 2>&1 | tee "${BUILD_LOG_PATH}"
xcodebuild_ec=${PIPESTATUS[0]}
set -e
if [[ "${xcodebuild_ec}" -ne 0 ]]; then
  echo "xcodebuild failed with exit code ${xcodebuild_ec}." >&2
  echo "Filtered build errors:" >&2
  if ! grep -E "(: error:|^error:|\\*\\* BUILD FAILED \\*\\*)" "${BUILD_LOG_PATH}" >&2; then
    echo "No explicit error lines found; showing last 80 log lines." >&2
    tail -n 80 "${BUILD_LOG_PATH}" >&2 || true
  fi
  exit "${xcodebuild_ec}"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

PLIST_PATH="${APP_PATH}/Contents/Info.plist"
BUILD_NUMBER=$(git -C "${ROOT_DIR}" rev-list --count HEAD)
INLINE_COMMIT=$(git -C "${ROOT_DIR}" rev-parse --short HEAD)

plist_set_string() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST_PATH}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} \"${value}\"" "${PLIST_PATH}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} string \"${value}\"" "${PLIST_PATH}"
  fi
}

plist_set_bool() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST_PATH}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${PLIST_PATH}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} bool ${value}" "${PLIST_PATH}"
  fi
}

plist_set_integer() {
  local key="$1"
  local value="$2"

  if /usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST_PATH}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${PLIST_PATH}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} integer ${value}" "${PLIST_PATH}"
  fi
}

plist_set_string "CFBundleVersion" "${BUILD_NUMBER}"
plist_set_string "InlineCommit" "${INLINE_COMMIT}"
plist_set_string "CFBundleDisplayName" "Inline Debug"
plist_set_string "CFBundleName" "Inline Debug"
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  plist_set_string "SUPublicEDKey" "${SPARKLE_PUBLIC_KEY}"
else
  echo "SPARKLE_PUBLIC_KEY is not set; leaving SUPublicEDKey unchanged." >&2
fi
plist_set_string "SUFeedURL" "${APPCAST_URL}"
plist_set_bool "SUEnableAutomaticChecks" "true"
plist_set_integer "SUScheduledCheckInterval" "${SPARKLE_SCHEDULED_CHECK_INTERVAL}"

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"
rsync -a --delete "${SPARKLE_FRAMEWORK_PATH}/Sparkle.framework" "${FRAMEWORKS_DIR}/"

if [[ ! -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
  echo "Sparkle framework not found at ${FRAMEWORKS_DIR}/Sparkle.framework" >&2
  exit 1
fi

echo "Local app build complete."
echo "  App: ${APP_PATH}"
echo "  Build log: ${BUILD_LOG_PATH}"
echo "  Debug flavor: enabled (DEBUG_BUILD)"
