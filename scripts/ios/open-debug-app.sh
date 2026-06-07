#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

PROJECT=${PROJECT:-"${ROOT_DIR}/apple/Inline.xcodeproj"}
SCHEME=${SCHEME:-"Inline (iOS)"}
CONFIGURATION=${CONFIGURATION:-Debug}
CACHE_PATH=${CACHE_PATH:-"${ROOT_DIR}/.tmp/ios-debug-target.json"}
LOG_PATH=${LOG_PATH:-"${ROOT_DIR}/.tmp/ios-debug-$(date +%Y%m%d-%H%M%S).log"}

build=1
launch=1
list=0
select=0
verbose=0

usage() {
  cat <<'EOF'
Usage: open-debug-app.sh [options]

Builds and runs the regular Xcode Debug iOS app without launching Xcode.
The first run asks for a preferred physical iOS device and a simulator fallback.
Later runs use the physical device when it is available and use the simulator
only when the preferred device is unavailable.

Options:
  --select        Re-prompt for preferred device and simulator fallback
  --list          List available devices and simulators, then exit
  --no-build      Install/launch the most recent Debug build without rebuilding
  --no-launch     Build and resolve the app path, but do not install or launch
  --verbose       Show full command output
  -h, --help      Show help

Environment:
  PROJECT         Xcode project path
  SCHEME          Xcode scheme (default: Inline (iOS))
  CONFIGURATION   Build configuration (default: Debug)
  CACHE_PATH      Target cache path (default: .tmp/ios-debug-target.json)
  LOG_PATH        Non-verbose command log path (default: .tmp/ios-debug-<timestamp>.log)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --select)
      select=1
      shift
      ;;
    --list)
      list=1
      shift
      ;;
    --no-build)
      build=0
      shift
      ;;
    --no-launch)
      launch=0
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

for cmd in xcodebuild xcrun python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${CACHE_PATH}")"

devices_json=$(mktemp)
sims_json=$(mktemp)
target_json=$(mktemp)
settings_file=$(mktemp)
devicectl_log=$(mktemp)

cleanup() {
  rm -f "${devices_json}" "${sims_json}" "${target_json}" "${settings_file}" "${devicectl_log}"
}
trap cleanup EXIT

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

run_cmd "List physical iOS devices" xcrun devicectl list devices --json-output "${devices_json}"

capture_cmd "List iOS simulators" "${sims_json}" xcrun simctl list devices available -j

python3 - "${devices_json}" "${sims_json}" "${CACHE_PATH}" "${target_json}" "${select}" "${list}" "${verbose}" <<'PY'
import json
import os
import re
import sys

devices_path, sims_path, cache_path, target_path, select_arg, list_arg, verbose_arg = sys.argv[1:]
force_select = select_arg == "1"
list_only = list_arg == "1"
verbose = verbose_arg == "1"


def load_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


def version_key(value):
    return tuple(int(part) for part in re.findall(r"\d+", value or "0"))


def compact_id(value):
    if not value:
        return ""
    return value[:8]


def device_label(item):
    detail = item.get("model") or "iOS device"
    os_version = item.get("os")
    suffix = f", iOS {os_version}" if os_version else ""
    return f"{item['name']} ({detail}{suffix}, {compact_id(item['id'])})"


def sim_label(item):
    return f"{item['name']} (iOS {item['os']}, {item['state']}, {compact_id(item['id'])})"


def prompt_choice(title, items, label_fn, allow_none=False):
    try:
        tty = open("/dev/tty", "r", encoding="utf-8")
    except OSError:
        print("No interactive terminal is available for choosing an iOS target.", file=sys.stderr)
        print(f"Run again from a terminal, or create {cache_path} manually.", file=sys.stderr)
        sys.exit(1)

    print(title)
    if allow_none:
        print("  0. No preferred physical device")
    for index, item in enumerate(items, start=1):
        print(f"  {index}. {label_fn(item)}")

    with tty:
        while True:
            print("Choose: ", end="", flush=True)
            raw = tty.readline()
            if raw == "":
                print("No choice was read from the terminal.", file=sys.stderr)
                sys.exit(1)

            raw = raw.strip()
            if allow_none and raw == "0":
                return None
            try:
                value = int(raw)
            except ValueError:
                print("Enter a number from the list.")
                continue
            if 1 <= value <= len(items):
                return items[value - 1]
            print("Enter a number from the list.")


def print_targets(devices, sims):
    print("Physical iOS devices:")
    if devices:
        for item in devices:
            print(f"  - {device_label(item)}")
    else:
        print("  none")

    print("Available iOS simulators:")
    if sims:
        for item in sims:
            print(f"  - {sim_label(item)}")
    else:
        print("  none")


devices_data = load_json(devices_path, {})
sim_data = load_json(sims_path, {})
cache = load_json(cache_path, {})

devices = []
for device in devices_data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    if hardware.get("platform") != "iOS":
        continue

    device_id = hardware.get("udid") or device.get("identifier")
    name = props.get("name") or device.get("name") or device_id
    if not device_id or not name:
        continue

    devices.append(
        {
            "kind": "device",
            "id": device_id,
            "name": name,
            "os": props.get("osVersionNumber") or "",
            "model": hardware.get("marketingName") or hardware.get("productType") or "",
        }
    )

devices.sort(key=lambda item: item["name"].lower())

sims = []
for runtime, runtime_devices in sim_data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue

    for sim in runtime_devices:
        if not sim.get("isAvailable"):
            continue

        sim_id = sim.get("udid")
        name = sim.get("name") or sim_id
        if not sim_id or not name:
            continue

        runtime_name = runtime.rsplit(".", 1)[-1].replace("iOS-", "").replace("-", ".")
        sims.append(
            {
                "kind": "simulator",
                "id": sim_id,
                "name": name,
                "os": runtime_name,
                "state": sim.get("state") or "Unknown",
            }
        )

sims.sort(
    key=lambda item: (
        "iPhone" not in item["name"],
        "Pro" not in item["name"],
        tuple(-part for part in version_key(item["os"])),
        item["name"].lower(),
    )
)

if list_only:
    print_targets(devices, sims)
    sys.exit(0)

preferred = cache.get("preferredDevice")
fallback = cache.get("fallbackSimulator")

device_by_id = {item["id"]: item for item in devices}
sim_by_id = {item["id"]: item for item in sims}

selected = None
needs_save = False

if force_select or not cache:
    preferred = None
    fallback = None

    if devices:
        preferred = prompt_choice(
            "Choose preferred physical iOS device:",
            devices,
            device_label,
            allow_none=True,
        )
    else:
        print("No physical iOS devices are available. Simulator fallback will be used.")

    if not sims:
        if preferred:
            fallback = None
        else:
            print("No available iOS simulators found.", file=sys.stderr)
            sys.exit(1)
    else:
        fallback = prompt_choice(
            "Choose simulator fallback:",
            sims,
            sim_label,
            allow_none=False,
        )

    cache = {
        "preferredDevice": preferred,
        "fallbackSimulator": fallback,
    }
    needs_save = True

if preferred and preferred.get("id") in device_by_id:
    selected = device_by_id[preferred["id"]]
elif fallback and fallback.get("id") in sim_by_id:
    if preferred:
        name = preferred.get("name") or preferred.get("id")
        print(f"Preferred device is unavailable: {name}. Falling back to simulator.")
    selected = sim_by_id[fallback["id"]]
elif sims:
    if preferred:
        name = preferred.get("name") or preferred.get("id")
        print(f"Preferred device is unavailable: {name}.")
    print("Choose simulator fallback:")
    fallback = prompt_choice("Available iOS simulators:", sims, sim_label, allow_none=False)
    cache["fallbackSimulator"] = fallback
    selected = fallback
    needs_save = True
else:
    print("No preferred physical device or simulator fallback is available.", file=sys.stderr)
    sys.exit(1)

if needs_save:
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2)
        f.write("\n")
    if verbose:
        print(f"Saved iOS debug target preference to {cache_path}")

with open(target_path, "w", encoding="utf-8") as f:
    json.dump(selected, f)
PY

if [[ "${list}" == "1" ]]; then
  exit 0
fi

target_value() {
  local key="$1"
  python3 - "${target_json}" "${key}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get(sys.argv[2], ""))
PY
}

kind="$(target_value kind)"
target_id="$(target_value id)"
target_name="$(target_value name)"

case "${kind}" in
  device)
    platform="iOS"
    ;;
  simulator)
    platform="iOS Simulator"
    ;;
  *)
    echo "Unsupported iOS debug target kind: ${kind}" >&2
    exit 1
    ;;
esac

xcode_args=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "platform=${platform},id=${target_id}"
)

if [[ "${build}" == "1" ]]; then
  run_cmd "Build ${SCHEME} (${CONFIGURATION}) for ${target_name}" xcodebuild "${xcode_args[@]}" build
fi

capture_cmd "Resolve iOS Debug app settings" "${settings_file}" xcodebuild "${xcode_args[@]}" -showBuildSettings

build_setting() {
  local key="$1"

  awk -F ' = ' -v key="${key}" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' "${settings_file}"
}

products_dir="$(build_setting BUILT_PRODUCTS_DIR)"
product_name="$(build_setting FULL_PRODUCT_NAME)"
bundle_id="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"

if [[ -z "${products_dir}" || -z "${product_name}" || -z "${bundle_id}" ]]; then
  echo "Could not resolve iOS Debug app settings from xcodebuild." >&2
  exit 1
fi

app_path="${products_dir}/${product_name}"

if [[ ! -d "${app_path}" ]]; then
  echo "iOS Debug app was not found at: ${app_path}" >&2
  echo "Run without --no-build to create it." >&2
  exit 1
fi

log "Debug app: ${app_path}"
log "Bundle id: ${bundle_id}"

if [[ "${launch}" != "1" ]]; then
  exit 0
fi

case "${kind}" in
  device)
    log "Installing on ${target_name}..."
    run_cmd "Install on ${target_name}" xcrun devicectl device install app --device "${target_id}" "${app_path}"
    log "Launching on ${target_name}..."
    run_cmd "Launch on ${target_name}" xcrun devicectl device process launch --device "${target_id}" --terminate-existing "${bundle_id}"
    ;;
  simulator)
    sim_state="$(target_value state)"
    if [[ "${sim_state}" != "Booted" ]]; then
      log "Booting simulator ${target_name}..."
      xcrun simctl boot "${target_id}" >/dev/null 2>&1 || true
      run_cmd "Wait for simulator ${target_name} to boot" xcrun simctl bootstatus "${target_id}" -b
    fi

    run_cmd "Open Simulator" /usr/bin/open -a Simulator --args -CurrentDeviceUDID "${target_id}"
    log "Installing on simulator ${target_name}..."
    run_cmd "Install on simulator ${target_name}" xcrun simctl install "${target_id}" "${app_path}"
    xcrun simctl terminate "${target_id}" "${bundle_id}" >/dev/null 2>&1 || true
    log "Launching on simulator ${target_name}..."
    run_cmd "Launch on simulator ${target_name}" xcrun simctl launch "${target_id}" "${bundle_id}"
    ;;
esac
