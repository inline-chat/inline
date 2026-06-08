#!/usr/bin/env bash

macos_lipo_archs() {
  local path="$1"
  local info

  if ! info=$(lipo -info "${path}" 2>/dev/null); then
    return 1
  fi

  if [[ "${info}" =~ Non-fat\ file:.*\ is\ architecture:\ ([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "${info}" =~ are:\ (.*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

macos_archs_contain() {
  local archs="$1"
  local arch="$2"
  [[ " ${archs} " == *" ${arch} "* ]]
}

macos_require_exact_archs() {
  local path="$1"
  shift

  local actual
  if ! actual=$(macos_lipo_archs "${path}"); then
    echo "Unable to determine architecture: ${path}" >&2
    return 1
  fi

  local required
  for required in "$@"; do
    if ! macos_archs_contain "${actual}" "${required}"; then
      echo "Missing required arch ${required}: ${path} (${actual})" >&2
      return 1
    fi
  done

  local arch
  for arch in ${actual}; do
    if ! macos_archs_contain "$*" "${arch}"; then
      echo "Unexpected arch ${arch}: ${path} (${actual})" >&2
      return 1
    fi
  done
}

macos_thin_binary_to_arch() {
  local path="$1"
  local arch="$2"

  if [[ ! -f "${path}" ]]; then
    return 0
  fi

  local actual
  if ! actual=$(macos_lipo_archs "${path}"); then
    echo "Unable to determine architecture: ${path}" >&2
    return 1
  fi

  if ! macos_archs_contain "${actual}" "${arch}"; then
    echo "Cannot thin ${path}; missing ${arch} slice (${actual})" >&2
    return 1
  fi

  if [[ "${actual}" == "${arch}" ]]; then
    return 0
  fi

  local tmp="${path}.thin-${arch}.$$"
  local mode
  mode=$(stat -f "%Lp" "${path}")

  if ! lipo "${path}" -thin "${arch}" -output "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi

  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${path}"
  macos_require_exact_archs "${path}" "${arch}"
}

macos_thin_sparkle_framework() {
  local framework="$1"
  local arch="$2"
  local current="${framework}/Versions/Current"

  local binaries=(
    "${current}/Sparkle"
    "${current}/Autoupdate"
    "${current}/Updater.app/Contents/MacOS/Updater"
    "${current}/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "${current}/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  )

  local binary
  for binary in "${binaries[@]}"; do
    macos_thin_binary_to_arch "${binary}" "${arch}" || return 1
  done
}

macos_thin_bundle_to_arch() {
  local bundle="$1"
  local arch="$2"
  local found=0
  local status=0
  local file

  while IFS= read -r -d '' file; do
    if macos_lipo_archs "${file}" >/dev/null; then
      found=1
      macos_thin_binary_to_arch "${file}" "${arch}" || status=1
    fi
  done < <(find "${bundle}" -type f -print0)

  if [[ "${found}" -eq 0 ]]; then
    echo "No Mach-O files found in ${bundle}" >&2
    return 1
  fi

  return "${status}"
}

macos_check_bundle_exact_archs() {
  local bundle="$1"
  shift

  local found=0
  local status=0
  local file
  while IFS= read -r -d '' file; do
    if macos_lipo_archs "${file}" >/dev/null; then
      found=1
      macos_require_exact_archs "${file}" "$@" || status=1
    fi
  done < <(find "${bundle}" -type f -print0)

  if [[ "${found}" -eq 0 ]]; then
    echo "No Mach-O files found in ${bundle}" >&2
    return 1
  fi

  return "${status}"
}
