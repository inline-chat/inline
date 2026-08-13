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
SPARKLE_VERSION=${SPARKLE_VERSION:-2.9.3}
DERIVED_DATA="${DERIVED_DATA:-"${ROOT_DIR}/build/InlineMacDirect"}"
APP_PATH="${APP_PATH:-""}"
DMG_PATH="${DMG_PATH:-""}"
SPARKLE_DIR="${SPARKLE_DIR:-"${ROOT_DIR}/.action/sparkle/${SPARKLE_VERSION}"}"
TEMP_ROOT="${ROOT_DIR}/build/macos-release-tmp"
CREATE_NEW_APPCAST=0
PROVENANCE_PATH=""

usage() {
  cat <<'EOF'
Usage: appcast-only.sh [--channel stable|beta|tip] [--app-path <path>] [--dmg-path <path>] [--derived-data <path>] [--provenance-path <path>] [--create-new-appcast]
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
    --create-new-appcast)
      CREATE_NEW_APPCAST=1
      shift
      ;;
    --provenance-path)
      PROVENANCE_PATH="${2:-}"
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
  "")
    echo "Missing --channel value" >&2
    exit 1
    ;;
  *)
    echo "Invalid --channel: ${CHANNEL}" >&2
    exit 1
    ;;
esac

if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/Inline.app"
fi
if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="${ROOT_DIR}/build/macos-direct/Inline.dmg"
fi
if [[ -z "${PROVENANCE_PATH}" ]]; then
  PROVENANCE_PATH="$(dirname "${DMG_PATH}")/release-provenance.json"
fi

mkdir -p "${TEMP_ROOT}"
TEMP_DIR=$(mktemp -d "${TEMP_ROOT}/appcast.XXXXXX")
SIGNING_KEY_PATH="${TEMP_DIR}/signing.key"
SIGN_UPDATE_PATH="${TEMP_DIR}/sign_update.txt"
APPCAST_PATH="${TEMP_DIR}/appcast.xml"
APPCAST_OUTPUT_PATH="${TEMP_DIR}/appcast_new.xml"
APPCAST_HEADERS_PATH="${TEMP_DIR}/appcast.headers"
LOCK_ROOT="${ROOT_DIR}/build/macos-release-locks"
LOCK_DIRS=()
LOCK_TOKEN=$(python3 -c 'import uuid; print(uuid.uuid4())')
cleanup_files() {
  rm -rf "${TEMP_DIR}"
  local index
  for ((index=${#LOCK_DIRS[@]} - 1; index >= 0; index--)); do
    python3 - "${LOCK_DIRS[index]}/owner.json" "${LOCK_TOKEN}" <<'PY' || true
import json
import os
import sys

path, token = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as file:
        owner = json.load(file)
    if owner.get("token") == token:
        os.unlink(path)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    pass
PY
    rmdir "${LOCK_DIRS[index]}" 2>/dev/null || true
  done
}
trap cleanup_files EXIT
mkdir -p "${LOCK_ROOT}"

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
require_cmd curl
require_cmd cmp
require_cmd git
require_cmd shasum
require_cmd stat

acquire_lock() {
  local lock_dir="$1"
  if ! mkdir "${lock_dir}" 2>/dev/null; then
    echo "Release lock is already held: ${lock_dir}" >&2
    exit 1
  fi
  LOCK_DIRS+=("${lock_dir}")
  python3 - "${lock_dir}/owner.json" "${LOCK_TOKEN}" "$$" "${CHANNEL}" <<'PY'
import json
import os
import sys

path, token, pid, channel = sys.argv[1:]
with open(path, "w", encoding="utf-8") as file:
    json.dump({"token": token, "pid": int(pid), "channel": channel, "kind": "standalone-appcast"}, file)
    file.write("\n")
os.chmod(path, 0o600)
PY
}

DERIVED_LOCK_HASH=$(python3 -c 'import hashlib, os, sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:16])' "${DERIVED_DATA}")
acquire_lock "${LOCK_ROOT}/channel-${CHANNEL}.lockdir"
acquire_lock "${LOCK_ROOT}/derived-data-${DERIVED_LOCK_HASH}.lockdir"

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" && -n "${MACOS_SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_PRIVATE_KEY="${MACOS_SPARKLE_PRIVATE_KEY}"
fi
require_env SPARKLE_PRIVATE_KEY
require_env PUBLIC_RELEASES_R2_ACCESS_KEY_ID
require_env PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY
require_env PUBLIC_RELEASES_R2_BUCKET
require_env PUBLIC_RELEASES_R2_ENDPOINT
require_env PUBLIC_RELEASES_R2_PUBLIC_BASE_URL

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found at ${DMG_PATH}" >&2
  exit 1
fi
if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found at ${APP_PATH}" >&2
  exit 1
fi
if [[ ! -f "${PROVENANCE_PATH}" ]]; then
  echo "Artifact provenance not found at ${PROVENANCE_PATH}" >&2
  exit 1
fi

echo "• Run signed-artifact post-check"
DMG_PATH="${DMG_PATH}" APP_PATH="" bash "${ROOT_DIR}/scripts/macos/post-check.sh"

SOURCE_COMMIT=$(git -C "${ROOT_DIR}" rev-parse HEAD)
SOURCE_COMMIT_SHORT=$(git -C "${ROOT_DIR}" rev-parse --short "${SOURCE_COMMIT}")
SOURCE_BUILD=$(git -C "${ROOT_DIR}" rev-list --count "${SOURCE_COMMIT}")
if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain)" ]]; then
  echo "Appcast publication requires a clean source tree on every channel." >&2
  exit 1
fi
bun run "${ROOT_DIR}/scripts/macos/app-release-metadata.ts" \
  --app-path "${APP_PATH}" \
  --verify-dmg "${DMG_PATH}" \
  --expect-build "${SOURCE_BUILD}" \
  --expect-commit "${SOURCE_COMMIT_SHORT}"
APP_EXECUTABLE_SHA256=$(shasum -a 256 "${APP_PATH}/Contents/MacOS/Inline" | awk '{print $1}')
DMG_SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')
DMG_SIZE=$(stat -f %z "${DMG_PATH}")
python3 - "${PROVENANCE_PATH}" "${SOURCE_COMMIT}" "${SOURCE_BUILD}" "${APP_EXECUTABLE_SHA256}" "${DMG_SIZE}" "${DMG_SHA256}" <<'PY'
import json
import sys

path, source_commit, source_build, app_sha256, dmg_size, dmg_sha256 = sys.argv[1:]
with open(path, encoding="utf-8") as file:
    provenance = json.load(file)
expected = {
    "schemaVersion": 1,
    "sourceCommit": source_commit,
    "sourceBuild": source_build,
    "sourceClean": True,
    "appExecutableSha256": app_sha256,
    "dmgSize": int(dmg_size),
    "dmgSha256": dmg_sha256,
}
mismatches = [f"{key}: {provenance.get(key)!r} != {value!r}" for key, value in expected.items() if provenance.get(key) != value]
if mismatches:
    raise SystemExit("Artifact provenance mismatch: " + "; ".join(mismatches))
PY
BUILD_NUMBER="${SOURCE_BUILD}"
export BUILD_NUMBER
BASE_URL="${PUBLIC_RELEASES_R2_PUBLIC_BASE_URL%/}"
DMG_URL="${BASE_URL}/mac/${CHANNEL}/${BUILD_NUMBER}/Inline.dmg"
APPCAST_URL="${BASE_URL}/mac/${CHANNEL}/appcast.xml"

echo "• Verify remote DMG bytes"
REMOTE_DMG_PATH="${TEMP_DIR}/remote-Inline.dmg"
curl -fSL --retry 4 --retry-all-errors "${DMG_URL}" -o "${REMOTE_DMG_PATH}"
if ! cmp -s "${DMG_PATH}" "${REMOTE_DMG_PATH}"; then
  echo "Remote DMG does not match local artifact at ${DMG_URL}" >&2
  exit 1
fi

echo "• Generate appcast"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")
MINIMUM_SYSTEM_VERSION=$(bun run "${ROOT_DIR}/scripts/macos/app-release-metadata.ts" \
  --app-path "${APP_PATH}" \
  --field=minimum-system-version)
COMMIT="${SOURCE_COMMIT_SHORT}"
COMMIT_LONG="${SOURCE_COMMIT}"
DMG_LENGTH="${DMG_SIZE}"

echo "${SPARKLE_PRIVATE_KEY}" > "${SIGNING_KEY_PATH}"
"${SPARKLE_DIR}/bin/sign_update" -f "${SIGNING_KEY_PATH}" "${DMG_PATH}" > "${SIGN_UPDATE_PATH}"

set +e
HTTP_STATUS=$(curl -sS -L -D "${APPCAST_HEADERS_PATH}" -o "${APPCAST_PATH}" -w "%{http_code}" "${APPCAST_URL}")
CURL_STATUS=$?
set -e
APPCAST_EXPECTED_ETAG=""
APPCAST_EXPECT_ABSENT=0
if [[ "${CURL_STATUS}" -eq 0 && "${HTTP_STATUS}" == "200" ]]; then
  if [[ "${CREATE_NEW_APPCAST}" == "1" ]]; then
    echo "--create-new-appcast was passed, but ${APPCAST_URL} already exists." >&2
    exit 1
  fi
  APPCAST_EXPECTED_ETAG=$(awk '/^[Ee][Tt][Aa][Gg]:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); etag=$0 } END { print etag }' "${APPCAST_HEADERS_PATH}")
  if [[ -z "${APPCAST_EXPECTED_ETAG}" ]]; then
    echo "Existing appcast response did not include an ETag; refusing an unconditional update." >&2
    exit 1
  fi
elif [[ "${CURL_STATUS}" -eq 0 && "${HTTP_STATUS}" == "404" && "${CREATE_NEW_APPCAST}" == "1" ]]; then
  rm -f "${APPCAST_PATH}"
  APPCAST_EXPECT_ABSENT=1
  echo "• Confirmed first publication (HTTP 404)"
elif [[ "${HTTP_STATUS}" == "404" ]]; then
  echo "Appcast does not exist; pass --create-new-appcast only for an intentional first publication." >&2
  exit 1
else
  echo "Unable to fetch existing appcast (curl exit ${CURL_STATUS}, HTTP ${HTTP_STATUS:-unknown}); refusing to replace feed history." >&2
  exit 1
fi

INLINE_BUILD="${BUILD_NUMBER}" \
INLINE_VERSION="${VERSION}" \
INLINE_CHANNEL="${CHANNEL}" \
INLINE_DMG_URL="${DMG_URL}" \
INLINE_MIN_MACOS="${MINIMUM_SYSTEM_VERSION}" \
INLINE_HARDWARE_REQUIREMENTS="arm64" \
INLINE_COMMIT="${COMMIT}" \
INLINE_COMMIT_LONG="${COMMIT_LONG}" \
SIGN_UPDATE_PATH="${SIGN_UPDATE_PATH}" \
APPCAST_PATH="${APPCAST_PATH}" \
APPCAST_OUTPUT="${APPCAST_OUTPUT_PATH}" \
ALLOW_NEW_APPCAST="${CREATE_NEW_APPCAST}" \
python3 "${ROOT_DIR}/scripts/macos/update_appcast.py"

echo "• Validate appcast"
python3 "${ROOT_DIR}/scripts/macos/validate_appcast.py" \
  --appcast "${APPCAST_OUTPUT_PATH}" \
  --require-build "${BUILD_NUMBER}" \
  --require-short-version "${VERSION}" \
  --require-url "${DMG_URL}" \
  --require-length "${DMG_LENGTH}" \
  --require-hardware arm64 \
  --require-minimum-system-version "${MINIMUM_SYSTEM_VERSION}"

echo "• Upload appcast to R2"
UPLOAD_MODE="appcast" CHANNEL="${CHANNEL}" APPCAST_PATH="${APPCAST_OUTPUT_PATH}" \
  BUILD_NUMBER="${BUILD_NUMBER}" APPCAST_EXPECTED_ETAG="${APPCAST_EXPECTED_ETAG}" \
  APPCAST_EXPECT_ABSENT="${APPCAST_EXPECT_ABSENT}" RELEASE_CHANNEL_LOCK_TOKEN="${LOCK_TOKEN}" \
  bun run "${ROOT_DIR}/scripts/macos/release-direct.ts"

echo "• Appcast update complete"
