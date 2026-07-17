#!/bin/bash
set -euo pipefail

readonly package_checks_workflow="Apple Package Tests"

if [[ "${CI_XCODE_CLOUD:-FALSE}" != "TRUE" || "${CI_WORKFLOW:-}" != "$package_checks_workflow" ]]; then
  echo "Skipping Apple package checks for workflow '${CI_WORKFLOW:-local}'."
  exit 0
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}"
checks_script="$script_dir/run-ci-checks.sh"

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
base_commit="${CI_PULL_REQUEST_TARGET_COMMIT:-}"
head_commit="${CI_COMMIT:-HEAD}"

# Xcode Cloud exposes the full target/source range for pull request builds, but
# no previous commit for a branch-change build. Prefer the provider range when
# both commits are present and run every package whenever it is unavailable.
if [[ -z "$base_commit" ]] ||
   ! git -C "$repo_root" rev-parse --verify "$base_commit^{commit}" >/dev/null 2>&1 ||
   ! git -C "$repo_root" rev-parse --verify "$head_commit^{commit}" >/dev/null 2>&1 ||
   ! git -C "$repo_root" merge-base "$base_commit" "$head_commit" >/dev/null 2>&1; then
  base_commit=""
  add_all_packages
  echo "Full Xcode Cloud comparison range unavailable; running all Apple package checks."
fi

changed_paths=""
if [[ -n "$base_commit" ]] &&
   ! changed_paths="$(git -C "$repo_root" diff --name-only "$base_commit...$head_commit")"; then
  base_commit=""
  add_all_packages
  echo "Xcode Cloud comparison failed; running all Apple package checks."
fi

if [[ -n "$base_commit" ]]; then
  while IFS= read -r path; do
    case "$path" in
      apple/ci_scripts/ci_post_clone.sh|apple/ci_scripts/run-ci-checks.sh|apple/ci_scripts/swiftlint.sh|scripts/apple/run-ci-checks.sh|scripts/apple/swiftlint.sh)
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
  done <<< "$changed_paths"
fi

if [[ ${#packages[@]} -eq 0 ]]; then
  exec "$checks_script" --lint-only
fi

exec "$checks_script" "${packages[@]}"
