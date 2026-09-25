#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
build_jobs="${SWIFT_BUILD_JOBS:-2}"
if [[ ! "$build_jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: SWIFT_BUILD_JOBS must be a positive integer" >&2
  exit 2
fi

echo "Apple CI toolchain:"
sw_vers
xcodebuild -version
xcrun swift --version

if [[ "${APPLE_CI_SKIP_SOURCE_CHECKS:-0}" != "1" ]]; then
  "$script_dir/check-source-contracts.sh"
  "$script_dir/swiftlint.sh" --quiet --reporter summary
fi

if [[ "${1:-}" == "--lint-only" ]]; then
  echo "Apple source checks completed."
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- InlineKit InlineUI InlineIOSUI InlineMacUI
fi

run_logged() {
  local log_path="$1"
  shift
  if [[ -n "$log_path" ]]; then
    "$@" 2>&1 | tee "$log_path"
  else
    "$@"
  fi
}

failures=0
for package in "$@"; do
  case "$package" in
    InlineKit|InlineUI|InlineIOSUI|InlineMacUI|InlineRealtimeCore|InlineMacSidebarModel|InlineThumbnailing|InlineSyntaxHighlighting|InlineMacScripting|InlineMath|MemojiKit|InlineDevCompanion)
      ;;
    *)
      echo "error: unsupported Swift package '$package'" >&2
      exit 2
      ;;
  esac

  package_dir="$repo_root/apple/$package"
  if [[ ! -f "$package_dir/Package.swift" ]] || ! grep -Eq '\.testTarget\(' "$package_dir/Package.swift"; then
    echo "error: $package must have a manifest and a test target" >&2
    failures=1
    continue
  fi

  report_dir="${APPLE_CI_REPORT_DIR:-}"
  if [[ -n "$report_dir" ]]; then
    mkdir -p "$report_dir"
  fi
  build_log=""
  test_log=""
  if [[ -n "$report_dir" ]]; then
    build_log="$report_dir/$package-build.log"
    test_log="$report_dir/$package-test.log"
  fi
  echo "Building $package tests"
  if ! (
    cd "$package_dir"
    run_logged "$build_log" xcrun swift build --build-tests --disable-automatic-resolution --jobs "$build_jobs"
  ); then
    echo "error: $package test build failed" >&2
    failures=1
    continue
  fi

  echo "Testing $package"
  # Pass explicitly: Swift Testing otherwise enables suite-level parallelism,
  # even though `swift test --help` describes --no-parallel as the default.
  # UI tests share platform services; GRDB fixtures also compete for setup time.
  if ! (
    cd "$package_dir"
    run_logged "$test_log" xcrun swift test --skip-build --disable-automatic-resolution --no-parallel
  ); then
    echo "error: $package tests failed" >&2
    failures=1
  fi
done

exit "$failures"
