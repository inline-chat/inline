#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [[ -f "${ROOT_DIR}/scripts/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ROOT_DIR}/scripts/.env"
  set +a
fi

CHANNEL="stable"
DERIVED_DATA="${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirect"}"
APP_PATH="${APP_PATH:-""}"
DMG_PATH="${DMG_PATH:-""}"
SPARKLE_DIR="${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle"}"
RELEASE_TAG="${RELEASE_TAG:-""}"
SKIP_GITHUB_RELEASE="${SKIP_GITHUB_RELEASE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
TEMP_ROOT="${ROOT_DIR}/build/macos-release-tmp"

usage() {
  cat <<'EOF'
Usage: release-local.sh [--channel stable|beta] [--app-path <path>] [--dmg-path <path>] [--derived-data <path>] [--skip-build]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="1"
      shift 1
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

if [[ -z "${CHANNEL}" ]]; then
  echo "Missing --channel value" >&2
  exit 1
fi

if [[ -z "${RELEASE_TAG}" && "${CHANNEL}" == "beta" ]]; then
  RELEASE_TAG="tip"
fi

if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/Inline.app"
fi
if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="${ROOT_DIR}/build/macos-direct/Inline.dmg"
fi

mkdir -p "${TEMP_ROOT}"
TEMP_DIR=$(mktemp -d "${TEMP_ROOT}/run.XXXXXX")
SIGNING_KEY_PATH="${TEMP_DIR}/signing.key"
SIGN_UPDATE_PATH="${TEMP_DIR}/sign_update.txt"
APPCAST_PATH="${TEMP_DIR}/appcast.xml"
APPCAST_OUTPUT_PATH="${TEMP_DIR}/appcast_new.xml"
cleanup_files() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup_files EXIT

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd bun
require_cmd python3

if [[ -z "${SPARKLE_PUBLIC_KEY:-}" && -n "${MACOS_SPARKLE_PUBLIC_KEY:-}" ]]; then
  SPARKLE_PUBLIC_KEY="${MACOS_SPARKLE_PUBLIC_KEY}"
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" && -n "${MACOS_SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_PRIVATE_KEY="${MACOS_SPARKLE_PRIVATE_KEY}"
fi

require_env SPARKLE_PRIVATE_KEY
require_env PUBLIC_RELEASES_R2_ACCESS_KEY_ID
require_env PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY
require_env PUBLIC_RELEASES_R2_BUCKET
require_env PUBLIC_RELEASES_R2_ENDPOINT
require_env PUBLIC_RELEASES_R2_PUBLIC_BASE_URL

if [[ "${SKIP_BUILD}" != "1" ]]; then
  # Build-only requirements; appcast/upload-only flows should not require signing env.
  require_env SPARKLE_PUBLIC_KEY
  require_env MACOS_CERTIFICATE_NAME
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
  echo "• Building DMG (channel: ${CHANNEL})"
  CHANNEL="${CHANNEL}" DERIVED_DATA="${DERIVED_DATA}" DMG_PATH="${DMG_PATH}" \
    bash "${ROOT_DIR}/scripts/macos/build-direct.sh"
else
  echo "• Skipping build (using existing APP/DMG)"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found at ${APP_PATH}" >&2
  exit 1
fi
if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found at ${DMG_PATH}" >&2
  exit 1
fi

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist")
export BUILD_NUMBER
BASE_URL="${PUBLIC_RELEASES_R2_PUBLIC_BASE_URL%/}"
DMG_URL="${BASE_URL}/mac/${CHANNEL}/${BUILD_NUMBER}/Inline.dmg"
APPCAST_URL="${BASE_URL}/mac/${CHANNEL}/appcast.xml"

echo "• Upload DMG to R2"
UPLOAD_MODE="dmg" CHANNEL="${CHANNEL}" DMG_PATH="${DMG_PATH}" \
  bun run "${ROOT_DIR}/scripts/macos/release-direct.ts"

echo "• Verify DMG availability"
for attempt in 1 2 3 4 5; do
  if curl -fsI "${DMG_URL}" >/dev/null; then
    break
  fi
  if [[ "${attempt}" -eq 5 ]]; then
    echo "DMG not reachable at ${DMG_URL}" >&2
    exit 1
  fi
  sleep 2
done

echo "• Generate appcast"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")
COMMIT=$(git -C "${ROOT_DIR}" rev-parse --short HEAD)
COMMIT_LONG=$(git -C "${ROOT_DIR}" rev-parse HEAD)
echo "${SPARKLE_PRIVATE_KEY}" > "${SIGNING_KEY_PATH}"
"${SPARKLE_DIR}/bin/sign_update" -f "${SIGNING_KEY_PATH}" "${DMG_PATH}" > "${SIGN_UPDATE_PATH}"

if ! curl -fsSL "${APPCAST_URL}" -o "${APPCAST_PATH}"; then
  echo "⚠️  No existing appcast found at ${APPCAST_URL}; creating a new one."
  rm -f "${APPCAST_PATH}"
fi

INLINE_BUILD="${BUILD_NUMBER}" \
INLINE_VERSION="${VERSION}" \
INLINE_CHANNEL="${CHANNEL}" \
INLINE_DMG_URL="${DMG_URL}" \
INLINE_MIN_MACOS="15.0" \
INLINE_COMMIT="${COMMIT}" \
INLINE_COMMIT_LONG="${COMMIT_LONG}" \
SIGN_UPDATE_PATH="${SIGN_UPDATE_PATH}" \
APPCAST_PATH="${APPCAST_PATH}" \
APPCAST_OUTPUT="${APPCAST_OUTPUT_PATH}" \
python3 "${ROOT_DIR}/scripts/macos/update_appcast.py"

echo "• Validate appcast"
python3 "${ROOT_DIR}/scripts/macos/validate_appcast.py" \
  --appcast "${APPCAST_OUTPUT_PATH}" \
  --require-build "${BUILD_NUMBER}" \
  --require-url "${DMG_URL}"

echo "• Upload appcast to R2"
UPLOAD_MODE="appcast" CHANNEL="${CHANNEL}" APPCAST_PATH="${APPCAST_OUTPUT_PATH}" \
  bun run "${ROOT_DIR}/scripts/macos/release-direct.ts"

if [[ -n "${RELEASE_TAG}" && "${SKIP_GITHUB_RELEASE}" != "1" ]]; then
  require_cmd gh

  echo "• Update GitHub tag (${RELEASE_TAG})"
  git -C "${ROOT_DIR}" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    tag -fa "${RELEASE_TAG}" -m "Latest Sparkle release" HEAD
  git -C "${ROOT_DIR}" push --force origin "${RELEASE_TAG}"

  echo "• Upload artifacts to GitHub Release (${RELEASE_TAG})"
  prerelease_flag=""
  if [[ "${CHANNEL}" == "beta" ]]; then
    prerelease_flag="--prerelease"
  fi
  if ! gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
    gh release create "${RELEASE_TAG}" --title "${RELEASE_TAG}" ${prerelease_flag} --notes "Automated macOS direct release."
  else
    if [[ "${CHANNEL}" == "beta" ]]; then
      gh release edit "${RELEASE_TAG}" --prerelease
    fi
  fi
  gh release upload "${RELEASE_TAG}" "${DMG_PATH}" --clobber
fi

echo "• Release complete"
