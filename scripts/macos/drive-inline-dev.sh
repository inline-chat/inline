#!/usr/bin/env zsh

set -euo pipefail

usage() {
  /bin/cat <<'EOF'
Drive the isolated Inline-Dev macOS app through Accessibility.

Usage:
  scripts/macos/drive-inline-dev.sh list
  scripts/macos/drive-inline-dev.sh switch [--pace SECONDS] ROW [ROW ...]
  scripts/macos/drive-inline-dev.sh cycle [--pace SECONDS] [--count COUNT]

Examples:
  scripts/macos/drive-inline-dev.sh list
  scripts/macos/drive-inline-dev.sh switch --pace 2 4 5 6 7
  scripts/macos/drive-inline-dev.sh cycle --pace 2 --count 10

The driver refuses the production Inline app. It only launches or attaches to
this checkout's isolated chat.inline.InlineMac.devbuild app bundle. `list`
prints row numbers and actionability without printing chat titles or contents.
EOF
}

if (( $# == 0 )); then
  usage
  exit 2
fi

mode="$1"
shift

if [[ "$mode" == "--help" || "$mode" == "-h" || "$mode" == "help" ]]; then
  usage
  exit 0
fi

if [[ "$mode" != "list" && "$mode" != "switch" && "$mode" != "cycle" ]]; then
  print -u2 "Unknown mode: $mode"
  usage >&2
  exit 2
fi

pace="2"
count="10"
typeset -a requested_rows
requested_rows=()

while (( $# > 0 )); do
  case "$1" in
    --pace)
      if (( $# < 2 )); then
        print -u2 "--pace requires a value"
        exit 2
      fi
      pace="$2"
      shift 2
      ;;
    --count)
      if (( $# < 2 )); then
        print -u2 "--count requires a value"
        exit 2
      fi
      count="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      requested_rows+=("$@")
      break
      ;;
    --*)
      print -u2 "Unknown option: $1"
      exit 2
      ;;
    *)
      requested_rows+=("$1")
      shift
      ;;
  esac
done

if [[ ! "$pace" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  print -u2 "Invalid pace: $pace"
  exit 2
fi

if [[ ! "$count" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "Invalid count: $count"
  exit 2
fi

if [[ "$mode" == "switch" && ${#requested_rows[@]} -eq 0 ]]; then
  print -u2 "switch requires at least one row"
  exit 2
fi

for row in "${requested_rows[@]}"; do
  if [[ ! "$row" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Invalid row: $row"
    exit 2
  fi
done

repo_root="${0:A:h:h:h}"
app_path="$repo_root/build/InlineMacDirectLocal/Build/Products/DevBuild/Inline-Dev.app"
expected_binary="$app_path/Contents/MacOS/Inline-Dev"
info_plist="$app_path/Contents/Info.plist"
expected_bundle_id="chat.inline.InlineMac.devbuild"

if [[ ! -x "$expected_binary" || ! -f "$info_plist" ]]; then
  print -u2 "Inline-Dev is not built at: $app_path"
  print -u2 "Build the optimized local app before driving it."
  exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
  print -u2 "Refusing unexpected bundle ID: $actual_bundle_id"
  exit 1
fi

find_exact_pids() {
  local candidate command
  typeset -a matches
  matches=()

  for candidate in ${(f)"$(/usr/bin/pgrep -x Inline-Dev 2>/dev/null || true)"}; do
    [[ -n "$candidate" ]] || continue
    command="$(/bin/ps -p "$candidate" -o command= | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$command" == "$expected_binary" ]]; then
      matches+=("$candidate")
    fi
  done

  print -l -- "${matches[@]}"
}

typeset -a app_pids
app_pids=("${(@f)$(find_exact_pids)}")

if (( ${#app_pids[@]} == 0 )); then
  /usr/bin/open -n "$app_path"
  for _ in {1..50}; do
    /bin/sleep 0.2
    app_pids=("${(@f)$(find_exact_pids)}")
    (( ${#app_pids[@]} > 0 )) && break
  done
fi

if (( ${#app_pids[@]} == 0 )); then
  print -u2 "Inline-Dev did not launch."
  exit 1
fi

if (( ${#app_pids[@]} > 1 )); then
  print -u2 "Refusing to drive multiple matching Inline-Dev processes: ${app_pids[*]}"
  exit 1
fi

pid="${app_pids[1]}"
/usr/bin/open -a "$app_path"

/usr/bin/osascript - "$pid" "$mode" "$pace" "$count" "${requested_rows[@]}" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set runMode to item 2 of argv
  set paceSeconds to (item 3 of argv) as real
  set cycleCount to (item 4 of argv) as integer

  tell application "System Events"
    set targetProcess to missing value
    repeat 50 times
      try
        set targetProcess to first process whose unix id is targetPID
        exit repeat
      on error
        delay 0.2
      end try
    end repeat
    if targetProcess is missing value then error "The verified Inline-Dev process is no longer running."

    set frontmost of targetProcess to true
    delay 0.25

    tell targetProcess
      if (count of windows) is 0 then error "Inline-Dev has no window."

      try
        set sidebarOutline to UI element 1 of UI element 3 of UI element 1 of UI element 1 of UI element 1 of window 1
        if role of sidebarOutline is not "AXOutline" then error "Unexpected sidebar role."
      on error
        error "Could not locate the Inline-Dev sidebar outline."
      end try

      set rowCount to count of rows of sidebarOutline

      if runMode is "list" then
        set outputLines to {}
        repeat with rowIndex from 1 to rowCount
          set isActionable to false
          set rowSize to size of row rowIndex of sidebarOutline
          set rowHeight to item 2 of rowSize
          try
            set rowButton to UI element 1 of UI element 1 of row rowIndex of sidebarOutline
            set isActionable to (rowHeight ≤ 36 and name of every action of rowButton contains "AXPress")
          end try
          set end of outputLines to ((rowIndex as text) & tab & "chat_candidate=" & (isActionable as text) & tab & "height=" & rowHeight)
        end repeat
        return my joinLines(outputLines)
      end if

      if runMode is "switch" then
        set pressedCount to 0
        repeat with argumentIndex from 5 to count of argv
          set rowIndex to (item argumentIndex of argv) as integer
          set sidebarOutline to UI element 1 of UI element 3 of UI element 1 of UI element 1 of UI element 1 of window 1
          set rowCount to count of rows of sidebarOutline
          if rowIndex < 1 or rowIndex > rowCount then error "Row is outside the visible sidebar: " & rowIndex

          try
            set rowSize to size of row rowIndex of sidebarOutline
            set rowHeight to item 2 of rowSize
            if rowHeight > 36 then error "Row looks like a section/header rather than a chat."
            set rowButton to UI element 1 of UI element 1 of row rowIndex of sidebarOutline
            if name of every action of rowButton does not contain "AXPress" then error "Row is not actionable."
            perform action "AXPress" of rowButton
          on error
            error "Could not activate sidebar row " & rowIndex & "."
          end try

          set pressedCount to pressedCount + 1
          delay paceSeconds
        end repeat
        return "pressed=" & pressedCount
      end if

      if runMode is "cycle" then
        set actionableRows to {}
        repeat with rowIndex from 1 to rowCount
          try
            set rowSize to size of row rowIndex of sidebarOutline
            set rowHeight to item 2 of rowSize
            set rowButton to UI element 1 of UI element 1 of row rowIndex of sidebarOutline
            if rowHeight ≤ 36 and name of every action of rowButton contains "AXPress" then set end of actionableRows to rowIndex
          end try
        end repeat

        if (count of actionableRows) < 2 then error "Need at least two actionable sidebar rows."

        repeat with iteration from 1 to cycleCount
          set sequenceIndex to ((iteration - 1) mod (count of actionableRows)) + 1
          set rowIndex to item sequenceIndex of actionableRows
          set sidebarOutline to UI element 1 of UI element 3 of UI element 1 of UI element 1 of UI element 1 of window 1
          set rowButton to UI element 1 of UI element 1 of row rowIndex of sidebarOutline
          perform action "AXPress" of rowButton
          delay paceSeconds
        end repeat
        return "pressed=" & cycleCount & " actionable_rows=" & (count of actionableRows)
      end if
    end tell
  end tell
end run

on joinLines(itemsToJoin)
  set oldDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to linefeed
  set joinedText to itemsToJoin as text
  set AppleScript's text item delimiters to oldDelimiters
  return joinedText
end joinLines
APPLESCRIPT
