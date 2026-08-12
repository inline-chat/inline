#!/usr/bin/env bash
set -o pipefail

mode="${1:-cold}"
if [[ "$mode" == -* ]]; then mode="cold"; else shift || true; fi

execute=false
json=false
project="$PWD"
older_than=""
dev_roots=()
protected_roots=()

usage() {
  echo "usage: disk-cleanup.sh [cold|safe|extra|deep] [--project PATH] [--dev-root PATH] [--protect PATH] [--older-than DAYS] [--json]"
  echo "       --execute/--yes are refused; deletion requires a separately approved literal path"
}

while (($#)); do
  case "$1" in
    --execute|--yes) execute=true ;;
    --json) json=true ;;
    --project|--dev-root|--protect|--older-than)
      option="$1"
      (($# >= 2)) || { echo "missing $option value" >&2; exit 2; }
      shift
      case "$option" in
        --project) project="$1" ;;
        --dev-root) dev_roots+=("$1") ;;
        --protect) protected_roots+=("$1") ;;
        --older-than) older_than="$1" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$mode" in cold|safe|extra|deep) ;; *) echo "invalid mode: $mode" >&2; usage >&2; exit 2 ;; esac
if [[ -z "$older_than" ]]; then
  if [[ "$mode" == cold ]]; then older_than=7; else older_than=30; fi
fi
[[ "$older_than" =~ ^[0-9]+$ ]] || { echo "--older-than must be a non-negative integer" >&2; exit 2; }
project="$(cd "$project" 2>/dev/null && pwd -P)" || { echo "project does not exist" >&2; exit 2; }
if ((${#dev_roots[@]} == 0)) && [[ -d "$HOME/dev" ]]; then dev_roots+=("$HOME/dev"); fi

canonical_dev_roots=()
for dev_root in "${dev_roots[@]}"; do
  canonical_root="$(cd "$dev_root" 2>/dev/null && pwd -P)" || { echo "dev root does not exist: $dev_root" >&2; exit 2; }
  case "$canonical_root" in
    /|"$HOME/Library/Developer/CoreDevice/DeviceFS"|"$HOME/Library/Developer/CoreDevice/DeviceFS"/*|/Volumes|/Volumes/*)
      echo "refusing unsafe dev root: $canonical_root" >&2
      exit 2
      ;;
  esac
  canonical_dev_roots+=("$canonical_root")
done
dev_roots=("${canonical_dev_roots[@]}")

if [[ "$(basename "$project")" == inline && -d "$(dirname "$project")/inline-public" ]]; then
  protected_roots+=("$(dirname "$project")/inline-public")
fi
canonical_protected_roots=()
for protected_root in "${protected_roots[@]}"; do
  canonical_root="$(cd "$protected_root" 2>/dev/null && pwd -P)" || { echo "protected root does not exist: $protected_root" >&2; exit 2; }
  canonical_protected_roots+=("$canonical_root")
done
protected_roots=("${canonical_protected_roots[@]}")

if $execute; then
  echo "refusing deletion: this helper is audit-only" >&2
  echo "remeasure and request confirmation for each literal path before deleting it separately" >&2
  exit 2
fi

targets=()
groups=()
candidate_path_is_allowed() {
  local audit_path="$1" base_name protected_root
  [[ -e "$audit_path" || -L "$audit_path" ]] || return 1
  [[ "$audit_path" == /* ]] || { echo "skipping non-absolute audit path: $audit_path" >&2; return 1; }
  base_name="$(basename "$audit_path")"
  case "$base_name" in .env|.env.*) return 1 ;; esac
  case "$audit_path" in
    "$HOME/.codex/sessions"|"$HOME/.codex/sessions"/*|"$HOME/.codex/archived_sessions"|"$HOME/.codex/archived_sessions"/*) return 1 ;;
    "$HOME/Library/Developer/CoreDevice/DeviceFS"|"$HOME/Library/Developer/CoreDevice/DeviceFS"/*|/Volumes|/Volumes/*) return 1 ;;
  esac
  for protected_root in "${protected_roots[@]}"; do
    case "$audit_path" in "$protected_root"|"$protected_root"/*) return 1 ;; esac
  done
  return 0
}

candidate_is_measurable() {
  local audit_path="$1" env_path
  candidate_path_is_allowed "$audit_path" || return 1
  if [[ -d "$audit_path" ]]; then
    if ! env_path="$(find "$audit_path" -xdev \( -name .env -o -name '.env.*' \) -print -quit 2>/dev/null)"; then
      echo "skipping unreadable audit path: $audit_path" >&2
      return 1
    fi
    [[ -n "$env_path" ]] && return 1
  fi
  return 0
}

append_target() {
  targets+=("$2")
  groups+=("$1")
}

add_target() {
  local group="$1" audit_path="$2"
  candidate_is_measurable "$audit_path" || return 0
  append_target "$group" "$audit_path"
}

tree_has_recent_file() {
  local audit_path="$1" recent_file
  if ! recent_file="$(find "$audit_path" -xdev \( -name .env -o -name '.env.*' \) -prune -o \
    -type f -mtime "-$older_than" -print -quit 2>/dev/null)"; then
    echo "skipping unreadable audit path: $audit_path" >&2
    return 0
  fi
  [[ -n "$recent_file" ]]
}

size_kb_for() {
  local audit_path="$1" measurement
  if ! measurement="$(du -x -sk "$audit_path" 2>/dev/null)"; then
    echo "could not measure audit path: $audit_path" >&2
    echo 0
    return 0
  fi
  awk '{print $1}' <<<"$measurement"
}

add_if_inactive() {
  local group="$1" audit_path="$2" minimum_kb="${3:-1}"
  candidate_path_is_allowed "$audit_path" || return 0
  tree_has_recent_file "$audit_path" && return 0
  candidate_is_measurable "$audit_path" || return 0
  [[ "$(size_kb_for "$audit_path")" -lt "$minimum_kb" ]] && return 0
  append_target "$group" "$audit_path"
}

add_inactive_children() {
  local group="$1" root="$2" minimum_kb="${3:-1}" audit_path
  [[ -d "$root" ]] || return 0
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  while IFS= read -r -d '' audit_path; do
    candidate_path_is_allowed "$audit_path" || continue
    tree_has_recent_file "$audit_path" && continue
    candidate_is_measurable "$audit_path" || continue
    [[ "$(size_kb_for "$audit_path")" -lt "$minimum_kb" ]] && continue
    append_target "$group" "$audit_path"
  done < <(find "$root" -xdev -mindepth 1 -maxdepth 1 -mtime "+$older_than" -print0)
}

add_named_dirs() {
  local group="$1" root="$2" age_filter="$3" audit_path
  [[ -d "$root" ]] || return 0
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  while IFS= read -r -d '' audit_path; do
    [[ "$audit_path" == "$project"/* ]] && [[ "$mode" == safe ]] && continue
    candidate_path_is_allowed "$audit_path" || continue
    [[ "$age_filter" == old ]] && tree_has_recent_file "$audit_path" && continue
    candidate_is_measurable "$audit_path" || continue
    append_target "$group" "$audit_path"
  done < <(
    if [[ "$age_filter" == old ]]; then
      find "$root" -xdev -mindepth 2 -maxdepth 5 \
        \( -type d \( -name .git -o -name .env -o -name '.env.*' \) -prune \) -o \
        \( -type d \( -name node_modules -o -name target -o -name .build -o -name DerivedData \) \
          -mtime "+$older_than" -print0 -prune \)
    else
      find "$root" -xdev -mindepth 2 -maxdepth 5 \
        \( -type d \( -name .git -o -name .env -o -name '.env.*' \) -prune \) -o \
        \( -type d \( -name node_modules -o -name target -o -name .build -o -name DerivedData \) \
          -print0 -prune \)
    fi
  )
}

add_cold_generated_dirs() {
  local root="$1" audit_path
  [[ -d "$root" ]] || return 0
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  while IFS= read -r -d '' audit_path; do
    if [[ "$audit_path" == "$project"/* ]]; then
      case "$audit_path" in
        "$project/.tmp"/*|"$project/.references"/*) ;;
        *) continue ;;
      esac
    fi
    candidate_path_is_allowed "$audit_path" || continue
    tree_has_recent_file "$audit_path" && continue
    candidate_is_measurable "$audit_path" || continue
    [[ "$(size_kb_for "$audit_path")" -lt 102400 ]] && continue
    append_target "cold-generated-output" "$audit_path"
  done < <(
    find "$root" -xdev -mindepth 2 -maxdepth 9 \
      \( -type d \( -name .git -o -name node_modules -o -name .env -o -name '.env.*' \) -prune \) -o \
      \( -type d \( -name .build -o -name target -o -name _build -o -name 'DerivedData*' \) \
        -mtime "+$older_than" -print0 -prune \)
  )
}

derived_data_belongs_to_project() {
  local audit_path="$1" workspace_path
  [[ -f "$audit_path/info.plist" ]] || return 1
  workspace_path="$(plutil -extract WorkspacePath raw -o - "$audit_path/info.plist" 2>/dev/null || true)"
  case "$workspace_path" in "$project"|"$project"/*) return 0 ;; esac
  return 1
}

add_derived_data_entries() {
  local group="$1" minimum_kb="$2" root="$HOME/Library/Developer/Xcode/DerivedData" audit_path base_name
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' audit_path; do
    base_name="$(basename "$audit_path")"
    case "$base_name" in ModuleCache.noindex|SDKExplicitPrecompiledModules|SymbolCache.noindex) continue ;; esac
    candidate_path_is_allowed "$audit_path" || continue
    derived_data_belongs_to_project "$audit_path" && continue
    tree_has_recent_file "$audit_path" && continue
    candidate_is_measurable "$audit_path" || continue
    [[ "$(size_kb_for "$audit_path")" -lt "$minimum_kb" ]] && continue
    append_target "$group" "$audit_path"
  done < <(find "$root" -xdev -mindepth 1 -maxdepth 1 -type d -mtime "+$older_than" -print0)
}

add_inactive_xcodes() {
  command -v xcode-select >/dev/null 2>&1 || return 0
  local selected_developer active_xcode audit_xcode resolved_xcode xcode_roots
  xcode_roots=(/Applications)
  [[ -d "$HOME/Applications" ]] && xcode_roots+=("$HOME/Applications")
  selected_developer="$(xcode-select -p 2>/dev/null || true)"
  active_xcode="${selected_developer%/Contents/Developer}"
  if [[ -d "$active_xcode" ]]; then active_xcode="$(cd "$active_xcode" && pwd -P)"; fi
  while IFS= read -r -d '' audit_xcode; do
    resolved_xcode="$(cd "$audit_xcode" 2>/dev/null && pwd -P)" || continue
    [[ "$resolved_xcode" == "$active_xcode" ]] && continue
    add_target "inactive-xcode-app" "$resolved_xcode"
  done < <(
    find "${xcode_roots[@]}" -xdev -mindepth 1 -maxdepth 1 -type d \
      \( -name Xcode.app -o -name Xcode-beta.app -o -name 'Xcode-*.app' -o -name 'Xcode_*.app' -o -name 'Xcode [0-9]*.app' \) \
      -print0
  )
}

# Shared low-risk inventory.
add_inactive_children "old-temp" "${TMPDIR:-/tmp}"
add_inactive_children "old-temp" "$HOME/Library/Caches/TemporaryItems"
cache_root="$HOME/Library/Caches"
if [[ -d "$cache_root" ]]; then
  if [[ "$mode" == cold ]]; then
    add_if_inactive "sparkle-cache" "$cache_root/org.sparkle-project.Sparkle"
    while IFS= read -r -d '' app_cache; do
      add_if_inactive "sparkle-cache" "$app_cache/org.sparkle-project.Sparkle"
    done < <(find "$cache_root" -xdev -mindepth 1 -maxdepth 1 -type d -print0)
  else
    add_target "sparkle-cache" "$cache_root/org.sparkle-project.Sparkle"
    while IFS= read -r -d '' app_cache; do
      add_target "sparkle-cache" "$app_cache/org.sparkle-project.Sparkle"
    done < <(find "$cache_root" -xdev -mindepth 1 -maxdepth 1 -type d -print0)
  fi
fi

if [[ "$mode" == cold ]]; then
  add_derived_data_entries "cold-derived-data" 102400
  for root in "${dev_roots[@]}"; do add_cold_generated_dirs "$root"; done
  add_inactive_xcodes
else
  add_derived_data_entries "old-derived-data" 0
  for root in "${dev_roots[@]}"; do add_named_dirs "old-project-output" "$root" old; done
fi

if [[ "$mode" == extra || "$mode" == deep ]]; then
  add_target "xcode-derived-data" "$HOME/Library/Developer/Xcode/DerivedData"
  for path in "$project/build" "$project/.build" "$project/DerivedData" "$project/target"; do add_target "current-project-output" "$path"; done
  for path in "$HOME/.bun/install/cache" "$HOME/.npm/_cacache" "$HOME/.cargo/registry/cache" "$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/Caches/go-build" "$HOME/Library/Caches/ms-playwright"; do add_target "hot-module-cache" "$path"; done
fi

if [[ "$mode" == deep ]]; then
  for root in "${dev_roots[@]}"; do add_named_dirs "dependency-tree" "$root" all; done
fi

# Irrecoverable entries are intentionally reported after rebuild/redownload candidates.
add_inactive_children "trash" "$HOME/.Trash"

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

bytes_for() {
  local audit_path="$1" measurement
  if ! measurement="$(du -x -sk "$audit_path" 2>/dev/null)"; then
    echo "could not measure audit path: $audit_path" >&2
    echo 0
    return 0
  fi
  awk '{print $1 * 1024}' <<<"$measurement"
}
human_for() {
  local audit_path="$1" measurement
  if ! measurement="$(du -x -sh "$audit_path" 2>/dev/null)"; then
    echo "could not measure audit path: $audit_path" >&2
    echo "?"
    return 0
  fi
  awk '{print $1}' <<<"$measurement"
}
impact_for() {
  case "$1" in
    old-temp|sparkle-cache) echo "none-or-small-redownload" ;;
    trash) echo "irrecoverable-after-emptying" ;;
    cold-generated-output|cold-derived-data|old-derived-data|old-project-output) echo "rebuild-only-if-reopened" ;;
    inactive-xcode-app) echo "redownload-only-if-old-xcode-needed" ;;
    xcode-derived-data|current-project-output) echo "hot-rebuild" ;;
    hot-module-cache|dependency-tree) echo "hot-redownload-or-reinstall" ;;
    *) echo "review" ;;
  esac
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

if $json; then
  printf '{"mode":"%s","project":"%s","targets":[' "$mode" "$(json_escape "$project")"
  for ((i=0; i<${#targets[@]}; i++)); do
    ((i)) && printf ','
    printf '{"group":"%s","impact":"%s","path":"%s","bytes":%s}' \
      "${groups[i]}" "$(impact_for "${groups[i]}")" "$(json_escape "${targets[i]}")" "$(bytes_for "${targets[i]}")"
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
for ((i=0; i<${#targets[@]}; i++)); do
  printf '  %-22s %-28s %7s  %s\n' \
    "${groups[i]}" "$(impact_for "${groups[i]}")" "$(human_for "${targets[i]}")" "${targets[i]}"
done

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

echo
echo "audit only; remeasure and request confirmation for each literal path before deletion"
