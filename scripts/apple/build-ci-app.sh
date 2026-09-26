#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/../.." && pwd)"
platform="${1:-}"

case "$platform" in
  macos)
    scheme='Inline (macOS)'
    destination='platform=macOS'
    product='Inline.app'
    ;;
  ios)
    scheme='Inline (iOS)'
    destination='generic/platform=iOS'
    product='InlineIOS.app'
    ;;
  *)
    echo 'usage: build-ci-app.sh macos|ios' >&2
    exit 2
    ;;
esac

derived_data="${APPLE_CI_DERIVED_DATA:-$RUNNER_TEMP/inline-$platform-derived-data}"
report_dir="${APPLE_CI_REPORT_DIR:-$RUNNER_TEMP/inline-$platform-reports}"
mkdir -p "$report_dir"

# Binary SwiftPM artifacts are served by upstream GitHub releases. Retry only
# dependency resolution so a transient download error cannot waste a full build.
for attempt in 1 2 3; do
  echo "Resolving $scheme packages (attempt $attempt/3)"
  if xcodebuild \
    -project "$repo_root/apple/Inline.xcodeproj" \
    -scheme "$scheme" \
    -derivedDataPath "$derived_data" \
    -resolvePackageDependencies 2>&1 | tee -a "$report_dir/$platform-package-resolution.log"; then
    break
  fi
  if [[ "$attempt" == 3 ]]; then
    echo "error: $scheme package resolution failed after three attempts" >&2
    exit 1
  fi
  sleep "$((attempt * 5))"
done

for configuration in Debug Release; do
  echo "Building $scheme $configuration for $destination"
  xcodebuild \
    -project "$repo_root/apple/Inline.xcodeproj" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | tee "$report_dir/$platform-$configuration.log"

  product_path="$derived_data/Build/Products/$configuration/$product"
  if [[ "$platform" == macos ]]; then
    if [[ "$configuration" == Debug ]]; then
      product_path="$derived_data/Build/Products/$configuration/Inline Debug.app"
    fi
    info_plist="$product_path/Contents/Info.plist"
  else
    product_path="$derived_data/Build/Products/$configuration-iphoneos/$product"
    info_plist="$product_path/Info.plist"
  fi
  if [[ ! -f "$info_plist" ]]; then
    echo "error: missing $info_plist" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist"
done
