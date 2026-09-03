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

onboarding_preview_path="apple/InlineMac/Views/Onboarding/OnboardingMessageStylePreview.swift"
onboarding_preview_source="$(read_source "$onboarding_preview_path" 2>/dev/null || true)"
if [[ -n "$onboarding_preview_source" ]] &&
   printf '%s\n' "$onboarding_preview_source" |
     grep -E '(^import InlineKit$|FullMessage|MessageTableCell|MessageSizeCalculator|MessageViewProps|EmbeddedMessageView|MessageBubbleBackground|MessageBubbleTail|MessageTimeAndState|NSViewRepresentable)' >/dev/null; then
  printf 'error: %s must remain independent of production message rendering\n' "$onboarding_preview_path" >&2
  failures=1
fi

all_chats_path="apple/InlineMac/Features/AllChats/AllChatsRouteView.swift"
all_chats_source="$(read_source "$all_chats_path" 2>/dev/null || true)"
all_chats_route_source="$(
  printf '%s\n' "$all_chats_source" |
    sed -n '/^struct AllChatsRouteView: View {/,/^private struct AllChatsViewOptionsMenu: View {/p'
)"
all_chats_row_source="$(
  printf '%s\n' "$all_chats_source" |
    sed -n '/^private struct ChatListRow: View {/,/^private struct AllChatsPreviewLine: View {/p'
)"
if [[ -n "$all_chats_source" ]]; then
  if ! printf '%s\n' "$all_chats_source" |
    grep -F '@State private var confirmationPresentation = AllChatsConfirmationPresentation()' >/dev/null; then
    printf 'error: %s must keep destructive confirmation state on the stable route\n' "$all_chats_path" >&2
    failures=1
  fi

  if ! printf '%s\n' "$all_chats_route_source" | grep -F '.alert(' >/dev/null; then
    printf 'error: %s must present destructive confirmations from AllChatsRouteView\n' "$all_chats_path" >&2
    failures=1
  fi

  if printf '%s\n' "$all_chats_row_source" | grep -F '.alert(' >/dev/null; then
    printf 'error: %s ChatListRow must not own alert presentation that can remove the row\n' "$all_chats_path" >&2
    failures=1
  fi

  if ! printf '%s\n' "$all_chats_row_source" |
    grep -F 'let requestConfirmation: (AllChatsRowConfirmation) -> Void' >/dev/null; then
    printf 'error: %s ChatListRow must submit confirmation requests to its stable owner\n' "$all_chats_path" >&2
    failures=1
  fi
fi

if git_grep --quiet --fixed-strings 'Not Loaded Title' -- 'apple/**/*.swift'; then
  printf 'error: Apple product UI must not expose the Not Loaded Title developer placeholder\n' >&2
  failures=1
fi

if git_grep --quiet --fixed-strings 'createPrivateChat' -- 'apple/**/*.swift'; then
  printf 'error: Apple DM selection must navigate to a user peer and let V3 GET_CHAT own get-or-create\n' >&2
  failures=1
fi

require_ordered_fragments() {
  local path="$1"
  shift
  local source
  source="$(read_source "$path" 2>/dev/null || true)"
  local prior_line=0
  local fragment
  for fragment in "$@"; do
    local line
    line="$(
      printf '%s\n' "$source" |
        grep -n -F -m 1 "$fragment" |
        cut -d: -f1 || true
    )"
    if [[ -z "$line" || "$line" -le "$prior_line" ]]; then
      printf 'error: %s must contain ordered lifecycle fragment: %s\n' "$path" "$fragment" >&2
      failures=1
      return
    fi
    prior_line="$line"
  done
}

voice_view_model_path="apple/InlineMac/Views/Compose/ComposeVoiceRecordingViewModel.swift"
voice_view_model_source="$(read_source "$voice_view_model_path" 2>/dev/null || true)"
if [[ -n "$voice_view_model_source" ]]; then
  if ! printf '%s\n' "$voice_view_model_source" | grep -F 'let preservesFinishing = finishingLifetime.isPreserving' >/dev/null ||
     ! printf '%s\n' "$voice_view_model_source" | grep -F 'let session = preservesFinishing ? nil : session' >/dev/null; then
    printf 'error: %s must let user-paused finishing survive view-model teardown\n' "$voice_view_model_path" >&2
    failures=1
  fi
  require_ordered_fragments \
    "$voice_view_model_path" \
    'let recording = try await session.finish()' \
    'let persistedMediaItem = try persistFinishedRecording?(recording)' \
    'guard let self else {' \
    'acceptFinishedRecording(recording, persistedMediaItem: persistedMediaItem)'
fi

for voice_host_path in \
  "apple/InlineMac/Views/Compose/GlassComposeAppKit.swift" \
  "apple/InlineMac/Views/Compose/LegacyComposeAppKit.swift"; do
  require_ordered_fragments \
    "$voice_host_path" \
    'let drafts2 = drafts2' \
    'let peerId = peerId' \
    'voiceViewModel.pauseRecording { [weak self] recording in' \
    'let mediaItem = try makeComposeVoiceMediaItem(from: recording)' \
    'let attachment = drafts2.appendAttachment(peer: peerId, media: mediaItem)' \
    'self?.attachmentItems[attachment.id] = mediaItem' \
    'return mediaItem'
done

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

printf 'Apple source contracts passed (%s).\n' "$mode${treeish:+:$treeish}"
