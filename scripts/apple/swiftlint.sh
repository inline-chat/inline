#!/usr/bin/env bash

set -euo pipefail

readonly SWIFTLINT_VERSION="0.65.0"
readonly SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"
readonly SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"
apple_dir="${root_dir}/apple"
tool_dir="${root_dir}/.tmp/tools/swiftlint-${SWIFTLINT_VERSION}"
zip_path="${tool_dir}/portable_swiftlint.zip"
swiftlint_bin="${tool_dir}/swiftlint"

use_system_swiftlint=false
if command -v swiftlint >/dev/null 2>&1; then
  system_version="$(swiftlint version 2>/dev/null || true)"
  if [ "${system_version}" = "${SWIFTLINT_VERSION}" ]; then
    use_system_swiftlint=true
    swiftlint_bin="$(command -v swiftlint)"
  fi
fi

if [ "${use_system_swiftlint}" = false ]; then
  needs_download=true
  if [ -x "${swiftlint_bin}" ]; then
    local_version="$("${swiftlint_bin}" version 2>/dev/null || true)"
    if [ "${local_version}" = "${SWIFTLINT_VERSION}" ]; then
      needs_download=false
    fi
  fi

  if [ "${needs_download}" = true ]; then
    mkdir -p "${tool_dir}"
    curl -L --fail --silent --show-error "${SWIFTLINT_URL}" -o "${zip_path}"

    actual_sha="$(shasum -a 256 "${zip_path}" | awk '{ print $1 }')"
    if [ "${actual_sha}" != "${SWIFTLINT_SHA256}" ]; then
      printf 'SwiftLint checksum mismatch. Expected %s, got %s\n' "${SWIFTLINT_SHA256}" "${actual_sha}" >&2
      exit 1
    fi

    unzip -q -o "${zip_path}" -d "${tool_dir}"
    chmod +x "${swiftlint_bin}"
  fi
fi

cd "${apple_dir}"
exec "${swiftlint_bin}" lint --force-exclude "$@"
