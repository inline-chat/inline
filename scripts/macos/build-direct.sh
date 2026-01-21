#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SPARKLE_VERSION=${SPARKLE_VERSION:-2.7.3}
SCHEME=${SCHEME:-"Inline (macOS)"}
CHANNEL=${CHANNEL:-stable}
APPCAST_URL=${APPCAST_URL:-"https://public-assets.inline.chat/mac/${CHANNEL}/appcast.xml"}
SPARKLE_DIR=${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle"}
DERIVED_DATA=${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirect"}
OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-direct"}
DMG_PATH=${DMG_PATH:-"${OUTPUT_DIR}/Inline.dmg"}

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

mkdir -p "${SPARKLE_DIR}"

if [[ ! -f "${SPARKLE_DIR}/Sparkle.xcframework/Info.plist" ]]; then
  curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip" \
    -o "${SPARKLE_DIR}/sparkle.zip"
  unzip -o "${SPARKLE_DIR}/sparkle.zip" -d "${SPARKLE_DIR}"
fi

SPARKLE_FRAMEWORK_PATH="${SPARKLE_DIR}/Sparkle.xcframework/macos-arm64_x86_64"

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

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST_PATH}"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_KEY}" "${PLIST_PATH}"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL ${APPCAST_URL}" "${PLIST_PATH}"

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"
rsync -a "${SPARKLE_FRAMEWORK_PATH}/Sparkle.framework" "${FRAMEWORKS_DIR}/"

SPARKLE_FRAMEWORK="${FRAMEWORKS_DIR}/Sparkle.framework"

/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate"
/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "${SPARKLE_FRAMEWORK}/Versions/B/Updater.app"
/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime "${SPARKLE_FRAMEWORK}"

/usr/bin/codesign --verbose -f -s "${MACOS_CERTIFICATE_NAME}" -o runtime --entitlements "${ROOT_DIR}/apple/InlineMac/InlineMacDirect.entitlements" "${APP_PATH}"

mkdir -p "${OUTPUT_DIR}"
create-dmg \
  --identity="${MACOS_CERTIFICATE_NAME}" \
  "${APP_PATH}" \
  "${OUTPUT_DIR}"

if [[ -f "${OUTPUT_DIR}/Inline.dmg" ]]; then
  mv -f "${OUTPUT_DIR}/Inline.dmg" "${DMG_PATH}"
else
  DMG_SOURCE=$(ls -1 "${OUTPUT_DIR}"/*.dmg | head -n 1)
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

  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler staple "${APP_PATH}"
fi

echo "Built app: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
