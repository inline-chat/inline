#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
mode="worktree"
treeish=""

usage() {
  printf 'Usage: %s [--cached | --treeish <ref>]\n' "$(basename "$0")" >&2
  exit 2
}

case "${1:-}" in
  "")
    ;;
  --cached)
    mode="cached"
    shift
    ;;
  --treeish)
    [[ $# -eq 2 ]] || usage
    mode="treeish"
    treeish="$2"
    shift 2
    ;;
  *)
    usage
    ;;
esac

[[ $# -eq 0 ]] || usage

git_grep() {
  local arguments=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    arguments+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift

  if [[ "$mode" == "worktree" ]]; then
    git -C "$repo_root" grep "${arguments[@]}" -- "$@"
  elif [[ "$mode" == "cached" ]]; then
    git -C "$repo_root" grep --cached "${arguments[@]}" -- "$@"
  else
    git -C "$repo_root" grep "${arguments[@]}" "$treeish" -- "$@"
  fi
}

read_source() {
  local path="$1"
  case "$mode" in
    worktree)
      sed -n '1,$p' "$repo_root/$path"
      ;;
    cached)
      git -C "$repo_root" show ":$path"
      ;;
    treeish)
      git -C "$repo_root" show "$treeish:$path"
      ;;
  esac
}

onboarding_usages="$(
  git_grep -h --only-matching --extended-regexp '\.onboarding[A-Za-z0-9]+Input\(' \
    -- 'apple/InlineIOS/**/*.swift' 2>/dev/null || true
)"

failures=0
while IFS= read -r modifier; do
  [[ -n "$modifier" ]] || continue
  modifier="${modifier#.}"
  modifier="${modifier%\(}"

  if ! git_grep --quiet --extended-regexp "func[[:space:]]+$modifier\\(" -- 'apple/**/*.swift'; then
    printf 'error: onboarding modifier %s is used but has no implementation\n' "$modifier" >&2
    failures=1
  fi
done < <(printf '%s\n' "$onboarding_usages" | LC_ALL=C sort -u)

performance_trace_files="$(
  git_grep --files-with-matches --fixed-strings 'PerformanceTrace.' \
    -- 'apple/InlineIOS/**/*.swift' 'apple/InlineMac/**/*.swift' 2>/dev/null |
    sed "s|^$treeish:||" || true
)"

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if ! read_source "$path" | grep -E '^import Logger$' >/dev/null; then
    printf 'error: %s uses PerformanceTrace but does not import Logger\n' "$path" >&2
    failures=1
  fi
done <<< "$performance_trace_files"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

printf 'Apple source contracts passed (%s).\n' "$mode${treeish:+:$treeish}"
