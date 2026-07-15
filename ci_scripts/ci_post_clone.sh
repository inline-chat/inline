#!/bin/bash
set -euo pipefail

readonly package_checks_workflow="Apple Package Tests"

if [[ "${CI_XCODE_CLOUD:-FALSE}" != "TRUE" || "${CI_WORKFLOW:-}" != "$package_checks_workflow" ]]; then
  echo "Skipping Apple package checks for workflow '${CI_WORKFLOW:-local}'."
  exit 0
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
checks_script="$repo_root/scripts/apple/run-ci-checks.sh"

if [[ ! -x "$checks_script" ]]; then
  echo "error: missing executable Apple CI checks script at $checks_script" >&2
  exit 1
fi

add_package() {
  local candidate="$1"
  local package
  for package in "${packages[@]:-}"; do
    if [[ "$package" == "$candidate" ]]; then
      return
    fi
  done
  packages+=("$candidate")
}

add_all_packages() {
  add_package "InlineKit"
  add_package "InlineUI"
  add_package "InlineIOSUI"
  add_package "InlineMacUI"
}

packages=()
base_commit=""

# Xcode Cloud normally checks out a branch build at the commit being tested.
# Use its first parent for affected-package selection, and safely fall back to
# full coverage whenever that history is unavailable or CI plumbing changed.
if git -C "$repo_root" rev-parse --verify HEAD^ >/dev/null 2>&1; then
  base_commit="HEAD^"
fi

if [[ -z "$base_commit" ]]; then
  add_all_packages
else
  while IFS= read -r path; do
    case "$path" in
      ci_scripts/ci_post_clone.sh|scripts/apple/run-ci-checks.sh)
        add_all_packages
        ;;
      apple/InlineKit/*)
        add_all_packages
        ;;
      apple/InlineUI/*)
        add_package "InlineUI"
        add_package "InlineIOSUI"
        add_package "InlineMacUI"
        ;;
      apple/InlineIOSUI/*)
        add_package "InlineIOSUI"
        ;;
      apple/InlineMacUI/*)
        add_package "InlineMacUI"
        ;;
    esac
  done < <(git -C "$repo_root" diff --name-only "$base_commit" HEAD)
fi

if [[ ${#packages[@]} -eq 0 ]]; then
  exec "$checks_script" --lint-only
fi

exec "$checks_script" "${packages[@]}"
