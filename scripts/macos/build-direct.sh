#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [[ -f "${ROOT_DIR}/scripts/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ROOT_DIR}/scripts/.env"
  set +a
fi

SPARKLE_VERSION=${SPARKLE_VERSION:-2.7.3}
SCHEME=${SCHEME:-"Inline (macOS)"}
CHANNEL=${CHANNEL:-stable}
APPCAST_URL=${APPCAST_URL:-"https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"}
SPARKLE_DIR=${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle"}
DERIVED_DATA=${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirect"}
OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-direct"}
DMG_PATH=${DMG_PATH:-"${OUTPUT_DIR}/Inline.dmg"}
ENTITLEMENTS_PATH=${ENTITLEMENTS_PATH:-"${ROOT_DIR}/apple/InlineMac/InlineMacDirect.entitlements"}
MACOS_PROVISIONING_PROFILE_BASE64=${MACOS_PROVISIONING_PROFILE_BASE64:-""}
MACOS_PROVISIONING_PROFILE_PATH=${MACOS_PROVISIONING_PROFILE_PATH:-""}
OVERWRITE_DMG=${OVERWRITE_DMG:-0}
EFFECTIVE_ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH}"

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" && -n "${MACOS_SPARKLE_PUBLIC_KEY:-}" ]]; then
  SPARKLE_PUBLIC_KEY="${MACOS_SPARKLE_PUBLIC_KEY}"
fi

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  echo "SPARKLE_PUBLIC_KEY is required" >&2
  exit 1
fi

if [[ -z "${MACOS_CERTIFICATE_NAME:-}" ]]; then
  echo "MACOS_CERTIFICATE_NAME is required" >&2
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required (install via npm install --global create-dmg)" >&2
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

mkdir -p "${SPARKLE_DIR}"

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

xcodebuild \
  -project "${ROOT_DIR}/apple/Inline.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="SPARKLE" \
  FRAMEWORK_SEARCH_PATHS="${SPARKLE_FRAMEWORK_PATH}" \
  OTHER_LDFLAGS="-framework Sparkle" \
  CODE_SIGN_ENTITLEMENTS="InlineMac/InlineMacDirect.entitlements" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  PROVISIONING_PROFILE_SPECIFIER=""

APP_PATH="${DERIVED_DATA}/Build/Products/Release/Inline.app"
PLIST_PATH="${APP_PATH}/Contents/Info.plist"
BUILD_NUMBER=$(git -C "${ROOT_DIR}" rev-list --count HEAD)

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

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

plist_set_string "CFBundleVersion" "${BUILD_NUMBER}"
plist_set_string "SUPublicEDKey" "${SPARKLE_PUBLIC_KEY}"
plist_set_string "SUFeedURL" "${APPCAST_URL}"
plist_set_bool "SUEnableAutomaticChecks" "true"

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"
rsync -a "${SPARKLE_FRAMEWORK_PATH}/Sparkle.framework" "${FRAMEWORKS_DIR}/"

SPARKLE_FRAMEWORK="${FRAMEWORKS_DIR}/Sparkle.framework"
if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
  echo "Sparkle framework not found at ${SPARKLE_FRAMEWORK}" >&2
  exit 1
fi

if [[ -n "${MACOS_PROVISIONING_PROFILE_BASE64}" || -n "${MACOS_PROVISIONING_PROFILE_PATH}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  PROFILE_PATH="${OUTPUT_DIR}/embedded.provisionprofile"
  if [[ -n "${MACOS_PROVISIONING_PROFILE_BASE64}" ]]; then
    if base64 -D >/dev/null 2>&1 <<<""; then
      echo "${MACOS_PROVISIONING_PROFILE_BASE64}" | base64 -D > "${PROFILE_PATH}"
    else
      echo "${MACOS_PROVISIONING_PROFILE_BASE64}" | base64 --decode > "${PROFILE_PATH}"
    fi
  else
    cp "${MACOS_PROVISIONING_PROFILE_PATH}" "${PROFILE_PATH}"
  fi

  PROFILE_PLIST=$(mktemp)
  security cms -D -i "${PROFILE_PATH}" > "${PROFILE_PLIST}"
  PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print :UUID" "${PROFILE_PLIST}")
  PROFILE_TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "${PROFILE_PLIST}")
  PROFILE_APS_ENV=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.aps-environment" "${PROFILE_PLIST}" 2>/dev/null || true)
  rm -f "${PROFILE_PLIST}"
  if [[ -z "${PROFILE_UUID}" || -z "${PROFILE_TEAM_ID}" ]]; then
    echo "Provisioning profile is missing UUID or team identifier." >&2
    exit 1
  fi

  mkdir -p "${HOME}/Library/MobileDevice/Provisioning Profiles"
  cp "${PROFILE_PATH}" "${HOME}/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.provisionprofile"
  cp "${PROFILE_PATH}" "${APP_PATH}/Contents/embedded.provisionprofile"

  EFFECTIVE_ENTITLEMENTS_PATH="${OUTPUT_DIR}/InlineMacDirect.entitlements"
  cp "${ENTITLEMENTS_PATH}" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  APP_PREFIX="${PROFILE_TEAM_ID}."
  perl -pi -e "s/\\$\\(TeamIdentifierPrefix\\)/${APP_PREFIX}/g; s/\\$\\(AppIdentifierPrefix\\)/${APP_PREFIX}/g" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  if [[ -n "${PROFILE_APS_ENV}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment ${PROFILE_APS_ENV}" "${EFFECTIVE_ENTITLEMENTS_PATH}" \
      || /usr/libexec/PlistBuddy -c "Add :com.apple.developer.aps-environment string ${PROFILE_APS_ENV}" "${EFFECTIVE_ENTITLEMENTS_PATH}"
  fi
fi

codesign_path() {
  local path="$1"
  /usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime --timestamp "${path}"
}

codesign_path "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
codesign_path "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
codesign_path "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate"
codesign_path "${SPARKLE_FRAMEWORK}/Versions/B/Updater.app"
codesign_path "${SPARKLE_FRAMEWORK}"

for framework in "${FRAMEWORKS_DIR}"/*.framework; do
  if [[ -d "${framework}" && "${framework}" != "${SPARKLE_FRAMEWORK}" ]]; then
    codesign_path "${framework}"
  fi
done

/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime --timestamp \
  --entitlements "${EFFECTIVE_ENTITLEMENTS_PATH}" \
  "${APP_PATH}"

mkdir -p "${OUTPUT_DIR}"
CREATE_DMG_OUTPUT_DIR="${OUTPUT_DIR}"
if ls "${OUTPUT_DIR}"/*.dmg >/dev/null 2>&1; then
  CREATE_DMG_OUTPUT_DIR=$(mktemp -d "${OUTPUT_DIR}/.create-dmg.XXXXXX")
fi

create-dmg \
  --identity="${MACOS_CERTIFICATE_NAME}" \
  "${APP_PATH}" \
  "${CREATE_DMG_OUTPUT_DIR}"

if [[ -f "${DMG_PATH}" ]]; then
  if [[ "${OVERWRITE_DMG}" == "1" ]]; then
    rm -f "${DMG_PATH}"
  else
    backup_path="${DMG_PATH%.dmg}-$(date +%Y%m%d-%H%M%S).dmg"
    mv -f "${DMG_PATH}" "${backup_path}"
    echo "Existing DMG moved to ${backup_path}"
  fi
fi

if [[ -f "${CREATE_DMG_OUTPUT_DIR}/Inline.dmg" ]]; then
  mv -f "${CREATE_DMG_OUTPUT_DIR}/Inline.dmg" "${DMG_PATH}"
else
  DMG_SOURCE=$(ls -1 "${CREATE_DMG_OUTPUT_DIR}"/*.dmg | head -n 1)
  mv -f "${DMG_SOURCE}" "${DMG_PATH}"
fi

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  NOTARY_PROFILE="inline-notarytool"
  if [[ -n "${APPLE_NOTARIZATION_KEY:-}" ]]; then
    if [[ -z "${APPLE_NOTARIZATION_KEY_ID:-}" || -z "${APPLE_NOTARIZATION_ISSUER:-}" ]]; then
      echo "APPLE_NOTARIZATION_KEY_ID and APPLE_NOTARIZATION_ISSUER are required with APPLE_NOTARIZATION_KEY" >&2
      exit 1
    fi
    echo "${APPLE_NOTARIZATION_KEY}" > "${OUTPUT_DIR}/notarization_key.p8"
    xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
      --key "${OUTPUT_DIR}/notarization_key.p8" \
      --key-id "${APPLE_NOTARIZATION_KEY_ID}" \
      --issuer "${APPLE_NOTARIZATION_ISSUER}"
    rm -f "${OUTPUT_DIR}/notarization_key.p8"
  else
    if [[ -z "${APPLE_ID:-}" || -z "${APPLE_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
      echo "Notarization requires either API key vars (APPLE_NOTARIZATION_KEY, APPLE_NOTARIZATION_KEY_ID, APPLE_NOTARIZATION_ISSUER) or Apple ID vars (APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID)" >&2
      exit 1
    fi
    xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}"
  fi

  submit_output=$(xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json 2>&1)
  echo "${submit_output}"

  submit_parse=$(python3 -c 'import json,sys; text=sys.stdin.read(); start=text.rfind("{"); end=text.rfind("}"); payload=text[start:end+1] if start != -1 and end != -1 and end >= start else ""; data=json.loads(payload) if payload else {}; print("{} {}".format(data.get("status",""), data.get("id","")))' <<<"${submit_output}")
  submit_status=${submit_parse%% *}
  submit_id=${submit_parse#* }
  if [[ "${submit_id}" == "${submit_status}" ]]; then
    submit_id=""
  fi

  if [[ "${submit_status}" != "Accepted" ]]; then
    echo "Notarization failed with status: ${submit_status}" >&2
    if [[ -n "${submit_id}" ]]; then
      xcrun notarytool log "${submit_id}" --keychain-profile "${NOTARY_PROFILE}" || true
    fi
    exit 1
  fi

  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler staple "${APP_PATH}"
fi

echo "Built app: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
