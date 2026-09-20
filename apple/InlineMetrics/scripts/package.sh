#!/bin/bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: package.sh --team TEAM_ID [--identity 'Apple Development']

Builds a universal Release app, checks its signatures and architectures,
and creates a ZIP containing only the app and installation instructions.
Requires Xcode and an installed signing identity for the specified team.
This command does not notarize, publish, install, or launch the app.
HELP
}

metrics_team=""
metrics_identity="Apple Development"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team|--identity)
      if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 2; fi
      if [[ "$1" == "--team" ]]; then metrics_team="$2"; else metrics_identity="$2"; fi
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ ! "$metrics_team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'Supply your 10-character Apple development team ID with --team.' >&2
  exit 2
fi

metrics_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
metrics_build_dir="$metrics_project_dir/build/distribution"
mkdir -p "$metrics_project_dir/build/packages"
metrics_package_dir="$(mktemp -d "$metrics_project_dir/build/packages/Inline-Metrics.XXXXXX")"
metrics_stage="$metrics_package_dir/Inline Metrics"
metrics_log="$metrics_package_dir/build.log"

echo "Building universal macOS app. Log: $metrics_log"
if ! xcodebuild \
  -project "$metrics_project_dir/InlineMetrics.xcodeproj" \
  -scheme InlineMetrics -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$metrics_build_dir" \
  "DEVELOPMENT_TEAM=$metrics_team" "CODE_SIGN_IDENTITY=$metrics_identity" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$metrics_log" 2>&1; then
  tail -60 "$metrics_log" >&2
  exit 1
fi

metrics_app="$metrics_build_dir/Build/Products/Release/Inline Metrics.app"
metrics_widget="$metrics_app/Contents/PlugIns/InlineMetricsWidget.appex"
codesign --verify --deep --strict "$metrics_app"
for metrics_binary in "$metrics_app/Contents/MacOS/Inline Metrics" "$metrics_widget/Contents/MacOS/InlineMetricsWidget"; do
  metrics_architectures="$(xcrun lipo -archs "$metrics_binary")"
  if [[ " $metrics_architectures " != *" arm64 "* || " $metrics_architectures " != *" x86_64 "* ]]; then
    echo "Expected Apple Silicon and Intel architectures in $metrics_binary; found $metrics_architectures" >&2
    exit 1
  fi
done

mkdir -p "$metrics_stage"
ditto "$metrics_app" "$metrics_stage/Inline Metrics.app"
cp "$metrics_project_dir/INSTALL.txt" "$metrics_stage/INSTALL.txt"
ditto -c -k --sequesterRsrc --keepParent "$metrics_stage" "$metrics_package_dir/Inline-Metrics-macOS.zip"
shasum -a 256 "$metrics_package_dir/Inline-Metrics-macOS.zip" > "$metrics_package_dir/SHA256.txt"
echo "Package: $metrics_package_dir/Inline-Metrics-macOS.zip"
echo 'Internal signed build; not notarized. Installation instructions are included.'
