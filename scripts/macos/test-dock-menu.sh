#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/inline-dock-menu.XXXXXX")

xcrun swiftc -swift-version 6 -parse-as-library \
  "$root_dir/apple/InlineMac/Services/DockMenu/DockMenu.swift" \
  "$root_dir/scripts/macos/tests/DockMenuTests.swift" \
  -o "$test_dir/DockMenuTests"
"$test_dir/DockMenuTests"
