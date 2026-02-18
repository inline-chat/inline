#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

OUTPUT_DIR=${OUTPUT_DIR:-"${ROOT_DIR}/build/macos-direct"}
DMG_PATH=${DMG_PATH:-"${OUTPUT_DIR}/Inline.dmg"}
APP_PATH=${APP_PATH:-""}
REQUIRE_APP_STAPLE=${REQUIRE_APP_STAPLE:-0}
REQUIRED_ARCHS=${REQUIRED_ARCHS:-""}

for arg in "$@"; do
  case "${arg}" in
    DMG_PATH=*) DMG_PATH="${arg#DMG_PATH=}" ;;
    OUTPUT_DIR=*) OUTPUT_DIR="${arg#OUTPUT_DIR=}" ;;
    APP_PATH=*) APP_PATH="${arg#APP_PATH=}" ;;
    REQUIRE_APP_STAPLE=*) REQUIRE_APP_STAPLE="${arg#REQUIRE_APP_STAPLE=}" ;;
    REQUIRED_ARCHS=*) REQUIRED_ARCHS="${arg#REQUIRED_ARCHS=}" ;;
    *) die "Unknown argument: ${arg}" ;;
  esac
done

info() { echo "• $*"; }
warn() { echo "⚠️  $*" >&2; }
die() { echo "✖ $*" >&2; exit 1; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

need_cmd hdiutil
need_cmd xcrun
need_cmd codesign
need_cmd spctl
need_cmd python3
need_cmd lipo

signature_has_timestamp() {
  local path="$1"
  local signature_details
  signature_details=$(/usr/bin/codesign -dv --verbose=4 "${path}" 2>&1 || true)
  if [[ "${signature_details}" == *"Timestamp="* ]]; then
    return 0
  fi
  echo "${signature_details}" >&2
  return 1
}

if [[ ! -f "${DMG_PATH}" ]]; then
  die "DMG not found: ${DMG_PATH}"
fi

info "DMG: ${DMG_PATH}"

MOUNT_PLIST=$(mktemp)
cleanup() {
  if [[ -n "${MOUNT_POINT:-}" ]]; then
    hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  rm -f "${MOUNT_PLIST}"
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -plist "${DMG_PATH}" > "${MOUNT_PLIST}"
MOUNT_POINT=$(python3 - "${MOUNT_PLIST}" <<'PY'
import plistlib
import sys

plist = plistlib.load(open(sys.argv[1], "rb"))
mount_point = ""
for ent in plist.get("system-entities", []):
    mp = ent.get("mount-point")
    if mp:
        mount_point = mp
        break
print(mount_point)
PY
)

if [[ -z "${MOUNT_POINT}" ]]; then
  die "Failed to mount DMG"
fi

APP_PATH=${APP_PATH:-"${MOUNT_POINT}/Inline.app"}
if [[ ! -d "${APP_PATH}" ]]; then
  die "App not found at ${APP_PATH}"
fi

info "App: ${APP_PATH}"

info "Validate stapled DMG ticket"
xcrun stapler validate "${DMG_PATH}"

info "Validate app ticket (optional)"
if ! xcrun stapler validate "${APP_PATH}" >/dev/null 2>&1; then
  if [[ "${REQUIRE_APP_STAPLE}" == "1" ]]; then
    die "App ticket is not stapled"
  else
    warn "App ticket not stapled (DMG is stapled)."
  fi
fi

info "Gatekeeper assessment"
spctl -a -vv --type execute "${APP_PATH}"

info "Code signature verification (deep)"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

info "Check app signature timestamp"
if ! signature_has_timestamp "${APP_PATH}"; then
  die "App signature missing timestamp"
fi

info "Check embedded bundles signatures + timestamps"
find "${APP_PATH}/Contents" -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -print0 \
  | while IFS= read -r -d '' bundle; do
      codesign --verify --strict --verbose=2 "${bundle}"
      if ! signature_has_timestamp "${bundle}"; then
        die "Missing timestamp: ${bundle}"
      fi
    done

info "Check Info.plist Sparkle keys"
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_PATH}/Contents/Info.plist" >/dev/null 2>&1; then
  die "Missing SUPublicEDKey in Info.plist"
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${APP_PATH}/Contents/Info.plist" >/dev/null 2>&1; then
  die "Missing SUFeedURL in Info.plist"
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "${APP_PATH}/Contents/Info.plist" >/dev/null 2>&1; then
  die "Missing SUScheduledCheckInterval in Info.plist"
fi

info "Check app architecture"
archs=$(python3 - "${APP_PATH}/Contents/MacOS/Inline" <<'PY'
import subprocess,sys,re
info = subprocess.check_output(["lipo","-info",sys.argv[1]], text=True).strip()
if "Non-fat file" in info:
    arch = info.split()[-1]
    print(arch)
elif "Architectures in the fat file" in info:
    m = re.search(r"are:\\s*(.*)$", info)
    print(m.group(1) if m else "")
else:
    print("")
PY
)

if [[ -z "${archs}" ]]; then
  die "Unable to determine app architecture"
fi
info "App architectures: ${archs}"

if [[ -n "${REQUIRED_ARCHS}" ]]; then
  for required in ${REQUIRED_ARCHS}; do
    if ! echo " ${archs} " | grep -q " ${required} "; then
      die "Missing required arch: ${required}"
    fi
  done
fi

info "Post-checks complete"
