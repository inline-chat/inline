#!/usr/bin/env bash
# Compile/test the installer and update protocol without building unrelated UI.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inline-cli-swift.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources" "$scratch/Tests"
ln -s "$repo/apple/InlineMacUI/Sources/InlineCLIInstaller" "$scratch/Sources/InlineCLIInstaller"
ln -s "$repo/apple/InlineMacUI/Tests/InlineCLIInstallerTests" "$scratch/Tests/InlineCLIInstallerTests"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CLIUpdateQualification", platforms: [.macOS(.v15)], targets: [
  .target(name: "InlineCLIInstaller", resources: [.process("Resources")]),
  .testTarget(name: "InlineCLIInstallerTests", dependencies: ["InlineCLIInstaller"]),
])
SWIFT
INLINE_CLI_SIGNATURE_FIXTURE="$repo/cli/tests/fixtures/signed-channel.json" swift test --package-path "$scratch" -j 2
