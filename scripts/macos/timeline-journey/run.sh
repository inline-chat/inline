#!/bin/zsh
# usage: run.sh [label]
# Builds Inline Debug with the timeline journey harness, runs the journeys on the NEW message list over the perf
# harness's seeded chats (signed out, no server), serves window captures, copies everything to OUT and prints a
# summary. See README.md. Environment:
#   JOURNEY=all            or a comma-separated list: open,fling,drag,stream,stream-reading,edit,delete,send,resize,composer,appearance
#   NO_BUILD=1             run the last build as it is
#   OUT=<dir>              results (default build/timeline-journey/<label>)
#   FRAME=229,-860,1200,800  the window (default: slot APP of ~/dev/inline-chat/.lab-screen, the built-in display)
#   SLOT=APP               the lab-screen slot claimed for the run (NO_CLAIM=1 skips the claim)
#   CAPTURES=external      external (real pixels, screencapture -l) | inapp (the window's own drawing) | none
#   EXTRA_ARGS=...         more launch arguments
setopt null_glob
D=${0:a:h}
ROOT=${D:h:h:h}
label=${1:-timeline-$(date +%m%d-%H%M)}
JOURNEY=${JOURNEY:-all}
# LIST=table runs the journeys on the table list (the timeline list's setting off), for the scenarios that work on both.
TIMELINE_LIST=YES
[[ ${LIST:-timeline} == table ]] && TIMELINE_LIST=NO
DD=${DD:-$ROOT/build/TimelineJourneyDD}
APP="$DD/Build/Products/Debug/Inline Debug.app"
OUT=${OUT:-$ROOT/build/timeline-journey/$label}
FRAME=${FRAME:-229,-860,1200,800}
SLOT=${SLOT:-APP}
CAPTURES=${CAPTURES:-external}
LAB=$HOME/dev/inline-chat/.lab-screen
JDIR=$HOME/Library/Containers/chat.inline.InlineMac.debug/Data/tmp/timeline-journey
mkdir -p "$OUT"

running() { echo "$(date '+%Y-%m-%d %H:%M') timeline-journey $label: $1" >> "$ROOT/.running"; }
unrunning() { sed -i '' "/timeline-journey $label: /d" "$ROOT/.running" 2>/dev/null; }
claimed=""
release() { [[ -n $claimed ]] && "$LAB/release" "$SLOT" >/dev/null; unrunning; }
trap release EXIT INT TERM

if [[ -z $NO_BUILD ]]; then
  running "xcodebuild Inline (macOS) Debug -O"
  echo "building Inline Debug (log: $OUT/build.log)"
  xcodebuild -project "$ROOT/apple/Inline.xcodeproj" -scheme "Inline (macOS)" -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
    SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s ENABLE_TESTABILITY=NO \
    USE_PRODUCTION_API=NO DEV_HOST=perf-harness.invalid -allowProvisioningUpdates build > "$OUT/build.log" 2>&1
  ec=$?
  unrunning
  if (( ec != 0 )); then
    grep -E ": error:|BUILD FAILED" "$OUT/build.log" | sort -u | head -20
    exit $ec
  fi
fi
[[ -d $APP ]] || { echo "no app at $APP"; exit 1; }

if [[ -z $NO_CLAIM && -x $LAB/claim ]]; then
  if ! "$LAB/claim" "$SLOT" "timeline-journey $label" >/dev/null; then
    echo "slot $SLOT is held: $("$LAB/status" | grep "^$SLOT:")"; exit 3
  fi
  claimed=1
fi

# Quit earlier harness runs only (never an Inline Debug someone is using): they have --perf-harness.
for pid in $(pgrep -x "Inline Debug"); do
  ps -o args= -p $pid | grep -q -- "--perf-harness" && kill -TERM $pid
done
sleep 1.5
mkdir -p "$JDIR"
rm -f "$JDIR/$label".jsonl "$JDIR/$label"-* 2>/dev/null

# The activation click tool (see activate-click.swift), built once.
CLICK="$ROOT/build/timeline-journey/activate-click"
if [[ ! -x $CLICK || "$D/activate-click.swift" -nt $CLICK ]]; then
  swiftc -O "$D/activate-click.swift" -o "$CLICK" 2>/dev/null || echo "activate-click: build failed"
fi

running "Inline Debug --timeline-journey $JOURNEY (window $FRAME, slot $SLOT)"
echo "$label: load $(sysctl -n vm.loadavg)"
open -n "$APP" --args --perf-harness -experimental.macTimelineList "$TIMELINE_LIST" --timeline-journey "$JOURNEY" \
  --timeline-journey-label "$label" --timeline-journey-frame "$FRAME" --timeline-journey-captures "$CAPTURES" ${(z)EXTRA_ARGS}
for i in {1..80}; do pid=$(pgrep -nx "Inline Debug"); [[ -n $pid ]] && break; sleep 0.25; done
echo "$label: pid $pid"

# Serve captures (real pixels of the window) until the runner is done; at most 15 minutes.
deadline=$(( $(date +%s) + 900 ))
while [[ ! -e "$JDIR/$label-done" ]] && (( $(date +%s) < deadline )); do
  for request in "$JDIR/$label"-*.request; do
    wid=$(head -1 "$request")
    screencapture -x -o -l"$wid" "${request:r}.png" 2>/dev/null
    rm -f "$request"
  done
  # The runner asks to be the active app (gestures that need a key window). An app can't activate itself from the
  # background and LaunchServices activation from a script is refused, so: one real click on the empty title bar
  # spot the runner names, through the HID tap, holding the lab's POINTER slot for it; the pointer goes back.
  for request in "$JDIR/$label"-*.activate; do
    point=$(head -1 "$request")
    if [[ -n $point && -x $CLICK ]] && "$LAB/claim" POINTER "timeline-journey $label activation click" >/dev/null; then
      "$CLICK" ${=point} $pid || echo "$label: activation click refused (another window in front)"
      "$LAB/release" POINTER >/dev/null
    else
      echo "$label: activation click skipped (no point, no tool, or POINTER held)"
    fi
    rm -f "$request"
  done
  kill -0 $pid 2>/dev/null || { echo "$label: app exited early"; break; }
  sleep 0.05
done
[[ -e "$JDIR/$label-done" ]] || echo "$label: runner did not finish"
cp "$JDIR/$label".jsonl "$JDIR/$label"-*.png "$JDIR/$label-runner.log" "$OUT/" 2>/dev/null
kill -TERM $pid 2>/dev/null
echo "$label: end load $(sysctl -n vm.loadavg)"
python3 "$D/report.py" "$OUT/$label.jsonl"
echo "results: $OUT"
