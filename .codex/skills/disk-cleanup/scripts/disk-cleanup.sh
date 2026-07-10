#!/usr/bin/env bash
set -o pipefail

mode="${1:-safe}"
if [[ "$mode" == -* ]]; then mode="safe"; else shift || true; fi

execute=false
confirmed=false
json=false
project="$PWD"
older_than=30
dev_roots=()

usage() {
  echo "usage: disk-cleanup.sh [safe|extra|deep] [--project PATH] [--dev-root PATH] [--older-than DAYS] [--json] [--execute --yes]"
}

while (($#)); do
  case "$1" in
    --execute) execute=true ;;
    --yes) confirmed=true ;;
    --json) json=true ;;
    --project) shift; project="${1:?missing --project value}" ;;
    --dev-root) shift; dev_roots+=("${1:?missing --dev-root value}") ;;
    --older-than) shift; older_than="${1:?missing --older-than value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$mode" in safe|extra|deep) ;; *) echo "invalid mode: $mode" >&2; usage >&2; exit 2 ;; esac
[[ "$older_than" =~ ^[0-9]+$ ]] || { echo "--older-than must be a non-negative integer" >&2; exit 2; }
project="$(cd "$project" 2>/dev/null && pwd -P)" || { echo "project does not exist" >&2; exit 2; }
if ((${#dev_roots[@]} == 0)) && [[ -d "$HOME/dev" ]]; then dev_roots+=("$HOME/dev"); fi

if $json && $execute; then echo "--json cannot be combined with --execute" >&2; exit 2; fi
if $execute && ! $confirmed; then
  echo "refusing deletion: pass both --execute and --yes after reviewing the audit" >&2
  exit 2
fi

targets=()
groups=()
add_target() {
  local group="$1" path="$2"
  [[ -e "$path" || -L "$path" ]] || return 0
  [[ "$(basename "$path")" == ".env" ]] && return 0
  targets+=("$path")
  groups+=("$group")
}

add_children_older_than() {
  local group="$1" root="$2"
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' path; do add_target "$group" "$path"; done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime "+$older_than" -print0 2>/dev/null)
}

add_named_dirs() {
  local group="$1" root="$2" age_filter="$3"
  [[ -d "$root" ]] || return 0
  local args=("$root" -mindepth 2 -maxdepth 5 -type d \( -name node_modules -o -name target -o -name .build -o -name DerivedData \) -prune)
  [[ "$age_filter" == old ]] && args+=( -mtime "+$older_than" )
  while IFS= read -r -d '' path; do
    [[ "$path" == "$project"/* ]] && [[ "$mode" == safe ]] && continue
    add_target "$group" "$path"
  done < <(find "${args[@]}" -print0 2>/dev/null)
}

# Safe: old or unambiguously disposable data.
add_children_older_than "old-temp" "${TMPDIR:-/tmp}"
add_children_older_than "old-temp" "$HOME/Library/Caches/TemporaryItems"
add_children_older_than "trash" "$HOME/.Trash"
add_children_older_than "old-derived-data" "$HOME/Library/Developer/Xcode/DerivedData"
add_target "sparkle-cache" "$HOME/Library/Caches/org.sparkle-project.Sparkle"
while IFS= read -r -d '' path; do add_target "sparkle-cache" "$path"; done < <(find "$HOME/Library/Caches" -mindepth 2 -maxdepth 3 -type d -name org.sparkle-project.Sparkle -print0 2>/dev/null)
for root in "${dev_roots[@]}"; do add_named_dirs "old-project-output" "$root" old; done

if [[ "$mode" == extra || "$mode" == deep ]]; then
  add_target "xcode-derived-data" "$HOME/Library/Developer/Xcode/DerivedData"
  for path in "$project/build" "$project/.build" "$project/DerivedData" "$project/target"; do add_target "current-project-output" "$path"; done
  for path in "$HOME/.bun/install/cache" "$HOME/.npm/_cacache" "$HOME/.cargo/registry/cache" "$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/Caches/go-build" "$HOME/Library/Caches/ms-playwright"; do add_target "hot-module-cache" "$path"; done
fi

if [[ "$mode" == deep ]]; then
  for root in "${dev_roots[@]}"; do add_named_dirs "dependency-tree" "$root" all; done
fi

# Remove duplicate and nested candidates when a parent directory is already listed.
compact_targets=()
compact_groups=()
for ((i=0; i<${#targets[@]}; i++)); do
  candidate="${targets[i]}"
  redundant=false
  for ((j=0; j<${#targets[@]}; j++)); do
    ((i == j)) && continue
    existing="${targets[j]}"
    [[ "$candidate" == "$existing"/* ]] && { redundant=true; break; }
  done
  if ! $redundant; then
    duplicate=false
    if ((${#compact_targets[@]})); then
      for existing in "${compact_targets[@]}"; do [[ "$candidate" == "$existing" ]] && { duplicate=true; break; }; done
    fi
    $duplicate || { compact_targets+=("$candidate"); compact_groups+=("${groups[i]}"); }
  fi
done
targets=("${compact_targets[@]}")
groups=("${compact_groups[@]}")

bytes_for() { du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}' || echo 0; }
human_for() { du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "?"; }

if $json; then
  printf '{"mode":"%s","project":"%s","targets":[' "$mode" "${project//\"/\\\"}"
  for ((i=0; i<${#targets[@]}; i++)); do
    ((i)) && printf ','
    printf '{"group":"%s","path":"%s","bytes":%s}' "${groups[i]}" "${targets[i]//\"/\\\"}" "$(bytes_for "${targets[i]}")"
  done
  printf ']}\n'
  exit 0
fi

echo "mode: $mode"
echo "project: $project"
echo "disk before:"
df -h "$project" | tail -1
echo
echo "filesystem targets (${#targets[@]}):"
for ((i=0; i<${#targets[@]}; i++)); do printf '  %-22s %7s  %s\n' "${groups[i]}" "$(human_for "${targets[i]}")" "${targets[i]}"; done

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo
  echo "docker candidates:"
  docker system df 2>/dev/null || true
  docker ps -a --filter status=exited --filter status=created --format '  stopped-container      {{.ID}}  {{.Names}}' 2>/dev/null || true
fi
if [[ "$mode" == deep ]] && command -v xcrun >/dev/null 2>&1; then
  echo
  echo "unavailable simulator candidates:"
  xcrun simctl list devices unavailable 2>/dev/null || true
fi

if ! $execute; then
  echo
  echo "dry run only; review the list, then pass --execute --yes after explicit confirmation"
  exit 0
fi

echo
echo "deleting reviewed filesystem targets..."
for ((i=0; i<${#targets[@]}; i++)); do
  path="${targets[i]}"
  if [[ "$path" == / || "$path" == "$HOME" || "$path" == "$project" || -z "$path" ]]; then
    echo "  refused unsafe path: $path" >&2
    continue
  fi
  rm -rf -- "$path" || echo "  failed: $path" >&2
done

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker container prune -f || true
  docker image prune -f || true
  docker builder prune -f || true
  if [[ "$mode" == deep ]]; then
    docker image prune -a -f || true
    docker network prune -f || true
  fi
fi
if [[ "$mode" == deep ]] && command -v xcrun >/dev/null 2>&1; then xcrun simctl delete unavailable || true; fi

echo "disk after:"
df -h "$project" | tail -1
