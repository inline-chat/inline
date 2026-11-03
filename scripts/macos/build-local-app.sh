#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

source "${ROOT_DIR}/scripts/macos/arch-utils.sh"

SPARKLE_VERSION=${SPARKLE_VERSION:-2.9.3}
SCHEME=${SCHEME:-"Inline (macOS)"}
CONFIGURATION=${CONFIGURATION:-DevBuild}
CHANNEL=${CHANNEL:-stable}
SIGN_BUILD=${SIGN_BUILD:-always}
APPCAST_URL=${APPCAST_URL:-"https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"}
SPARKLE_SCHEDULED_CHECK_INTERVAL=${SPARKLE_SCHEDULED_CHECK_INTERVAL:-3600}
SPARKLE_DIR=${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle/${SPARKLE_VERSION}"}
DERIVED_DATA=${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirectLocal"}
APP_PATH=${APP_PATH:-"${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Inline-Dev.app"}
OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-local-app"}
BUILD_LOG_PATH="${OUTPUT_DIR}/xcodebuild.log"
MACOS_RELEASE_ARCH=${MACOS_RELEASE_ARCH:-arm64}

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" && -n "${MACOS_SPARKLE_PUBLIC_KEY:-}" ]]; then
  SPARKLE_PUBLIC_KEY="${MACOS_SPARKLE_PUBLIC_KEY}"
fi

usage() {
  cat <<'EOF'
Usage: build-local-app.sh [options]

Builds a local Sparkle-enabled Inline.app for testing without DMG creation,
notarization, or upload steps. Local post-build signing is enabled by default.

Options:
  --channel <stable|beta|tip>     Update channel to embed in Info.plist
  --configuration DevBuild        Xcode build configuration (fixed to DevBuild)
  --derived-data <path>           Xcode derived data path
  --app-path <path>               App bundle output path
  --sign                          Require post-build local signing (default)
  --skip-sign                     Skip post-build local signing
  --sparkle-dir <path>            Sparkle download/cache directory
  --scheme <name>                 Xcode scheme (default: Inline (macOS))
  -h, --help                      Show help

Optional env:
  SIGN_BUILD                      auto|always|never (default: always)
  SPARKLE_PUBLIC_KEY              Embedded into SUPublicEDKey when set
  MACOS_SPARKLE_PUBLIC_KEY        Alias for SPARKLE_PUBLIC_KEY
  MACOS_CERTIFICATE_NAME          Signing identity used by sign-direct.sh
                                  (default: first Developer ID or Apple Development identity)
  MACOS_PROVISIONING_PROFILE_BASE64 / _PATH
                                  Profile for APS/keychain entitlements when signing
                                  (default: newest installed profile for the app's bundle ID)
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
      if [[ "${CHANNEL}" != "stable" && "${CHANNEL}" != "beta" && "${CHANNEL}" != "tip" ]]; then
        echo "Invalid --channel: ${CHANNEL}" >&2
        exit 1
      fi
      APPCAST_URL="https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Inline-Dev.app"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="$(resolve_path "${2:-}")"
      APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Inline-Dev.app"
      shift 2
      ;;
    --app-path)
      APP_PATH="$(resolve_path "${2:-}")"
      shift 2
      ;;
    --sign)
      SIGN_BUILD="always"
      shift
      ;;
    --skip-sign)
      SIGN_BUILD="never"
      shift
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

case "${CHANNEL}" in
  stable|beta|tip) ;;
  *)
    echo "Invalid CHANNEL: ${CHANNEL} (expected stable, beta, or tip)" >&2
    exit 1
    ;;
esac

case "${SIGN_BUILD}" in
  auto|always|never) ;;
  *)
    echo "Invalid SIGN_BUILD: ${SIGN_BUILD}" >&2
    exit 1
    ;;
esac

if [[ "${CONFIGURATION}" != "DevBuild" ]]; then
  echo "build-local-app.sh only supports the isolated DevBuild configuration." >&2
  echo "Use Xcode Debug/Debug #2 for regular debug runs." >&2
  exit 1
fi

for cmd in xcodebuild curl unzip rsync git lipo; do
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
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA}"
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=${swift_conditions}"
  "FRAMEWORK_SEARCH_PATHS=${SPARKLE_FRAMEWORK_PATH}"
  "OTHER_LDFLAGS=-framework Sparkle"
  "ARCHS=${MACOS_RELEASE_ARCH}"
  ONLY_ACTIVE_ARCH=NO
  "CODE_SIGN_ENTITLEMENTS=InlineMac/InlineMacDirect.entitlements"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_STYLE=Manual
  PROVISIONING_PROFILE_SPECIFIER=
)
xcodebuild_args+=("ASSETCATALOG_COMPILER_APPICON_NAME=InlineAppIconDebug")

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
plist_set_string "CFBundleDisplayName" "Inline-Dev"
plist_set_string "CFBundleName" "Inline-Dev"
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
macos_thin_bundle_to_arch "${APP_PATH}" "${MACOS_RELEASE_ARCH}"

ENTITLEMENTS_PATH="${ROOT_DIR}/apple/InlineMac/InlineMacDirect.entitlements"

# Prefers Developer ID, then falls back to the Apple Development identity Xcode installs.
resolve_local_certificate() {
  local identities
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  local kind
  for kind in "Developer ID Application" "Apple Development"; do
    local hash
    hash=$(awk -v kind="\"${kind}:" 'index($0, kind) { print $2; exit }' <<<"${identities}")
    if [[ -n "${hash}" ]]; then
      printf '%s\n' "${hash}"
      return 0
    fi
  done
}

# Finds the newest unexpired installed profile (e.g. Xcode's team profile) for the app's bundle ID.
resolve_local_profile() {
  local bundle_id
  bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${PLIST_PATH}")
  python3 - "${bundle_id}" \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "${HOME}/Library/MobileDevice/Provisioning Profiles" <<'PY'
import datetime, glob, os, plistlib, subprocess, sys

bundle_id, *dirs = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
best = None
for directory in dirs:
    for path in glob.glob(os.path.join(directory, "*.provisionprofile")):
        decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
        if decoded.returncode != 0:
            continue
        profile = plistlib.loads(decoded.stdout)
        app_id = profile.get("Entitlements", {}).get("com.apple.application-identifier", "")
        expires = profile.get("ExpirationDate")
        if expires is None or not app_id.endswith("." + bundle_id):
            continue
        expires = expires.replace(tzinfo=datetime.timezone.utc)
        if expires > now and (best is None or expires > best[0]):
            best = (expires, path)
if best:
    print(best[1])
PY
}

# Matches the entitlements to the profile like Xcode does: adds the app/team identifiers and
# drops developer entitlements the profile doesn't grant, which would otherwise block launch.
prepare_local_entitlements() {
  local profile_path="$1"
  local output_path="${OUTPUT_DIR}/InlineMacDirectLocal.entitlements"
  python3 - "${ENTITLEMENTS_PATH}" "${profile_path}" "${output_path}" <<'PY'
import plistlib, subprocess, sys

entitlements_path, profile_path, output_path = sys.argv[1:]
with open(entitlements_path, "rb") as f:
    entitlements = plistlib.load(f)
decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path], capture_output=True, check=True)
granted = plistlib.loads(decoded.stdout)["Entitlements"]

for key in ("com.apple.application-identifier", "com.apple.developer.team-identifier"):
    entitlements[key] = granted[key]
for key in [k for k in entitlements if k.startswith("com.apple.developer.") and k not in granted]:
    del entitlements[key]
    print(f"Profile does not grant {key}; signing without it.", file=sys.stderr)

with open(output_path, "wb") as f:
    plistlib.dump(entitlements, f)
PY
  printf '%s\n' "${output_path}"
}

sign_local_app() {
  local certificate="${MACOS_CERTIFICATE_NAME:-}"
  if [[ -z "${certificate}" ]]; then
    certificate=$(resolve_local_certificate)
    if [[ -z "${certificate}" ]]; then
      echo "No codesigning identity found; set MACOS_CERTIFICATE_NAME or use --skip-sign." >&2
      exit 1
    fi
    echo "Using codesigning identity ${certificate}." >&2
  fi

  local profile_path="${MACOS_PROVISIONING_PROFILE_PATH:-}"
  local entitlements_path="${ENTITLEMENTS_PATH}"
  if [[ -z "${profile_path}" && -z "${MACOS_PROVISIONING_PROFILE_BASE64:-}" ]]; then
    profile_path=$(resolve_local_profile)
    if [[ -z "${profile_path}" ]]; then
      echo "No installed provisioning profile matches this app; set MACOS_PROVISIONING_PROFILE_PATH" >&2
      echo "or build the DevBuild configuration once in Xcode so it downloads one." >&2
      exit 1
    fi
    echo "Using provisioning profile ${profile_path}." >&2
    entitlements_path=$(prepare_local_entitlements "${profile_path}")
  fi

  MACOS_CERTIFICATE_NAME="${certificate}" \
  MACOS_PROVISIONING_PROFILE_BASE64="${MACOS_PROVISIONING_PROFILE_BASE64:-}" \
  MACOS_PROVISIONING_PROFILE_PATH="${profile_path}" \
    bash "${ROOT_DIR}/scripts/macos/sign-direct.sh" \
      --app-path "${APP_PATH}" \
      --entitlements-path "${entitlements_path}" \
      --output-dir "${OUTPUT_DIR}" \
      --skip-timestamp
}

signed_build="no"
case "${SIGN_BUILD}" in
  always)
    sign_local_app
    signed_build="yes"
    ;;
  auto)
    if [[ -n "${MACOS_CERTIFICATE_NAME:-}" ]]; then
      sign_local_app
      signed_build="yes"
    else
      echo "MACOS_CERTIFICATE_NAME is not set; leaving local app unsigned." >&2
    fi
    ;;
  never)
    echo "Skipping local codesign (--skip-sign)." >&2
    ;;
esac

echo "Local app build complete."
echo "  App: ${APP_PATH}"
echo "  Build log: ${BUILD_LOG_PATH}"
echo "  Debug flavor: enabled (DEBUG_BUILD)"
echo "  Signed: ${signed_build}"
