#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"

echo "Apple CI toolchain:"
sw_vers
xcodebuild -version
xcrun swift --version

"$script_dir/swiftlint.sh" --quiet --reporter summary

if [[ "${1:-}" == "--lint-only" ]]; then
  echo "No Swift package changed; lint completed."
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- InlineKit InlineUI InlineIOSUI InlineMacUI
fi

for package in "$@"; do
  case "$package" in
    InlineKit|InlineUI|InlineIOSUI|InlineMacUI)
      ;;
    *)
      echo "error: unsupported Swift package '$package'" >&2
      exit 2
      ;;
  esac

  package_dir="$repo_root/apple/$package"
  echo "Building $package tests"
  (
    cd "$package_dir"
    xcrun swift build --build-tests --disable-automatic-resolution
  )

  echo "Testing $package"
  if [[ "$package" == "InlineKit" ]]; then
    (
      cd "$package_dir"
      xcrun swift test --skip-build --disable-automatic-resolution --no-parallel
    )
  else
    (
      cd "$package_dir"
      xcrun swift test --skip-build --disable-automatic-resolution
    )
  fi
done
