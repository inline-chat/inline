#!/bin/zsh
# SIMULATOR runs. usage: simtest.sh <simUDID> <testName> "<lab args>" [wait] [outdir]
set -u
cd "$(dirname $0)/.."
SIM=$1; T=$2; ARGS=$3; WAIT=${4:-0}; OUT=${5:-/tmp/labsim}
RUN=/Users/mo/dev/inline-chat/inline/.running
echo "$(date '+%Y-%m-%d %H:%M') claude(timeline-lab): xcodebuild test-without-building (SIMULATOR) $T $ARGS" >> $RUN
rm -rf "$OUT/result.xcresult"; mkdir -p "$OUT"
XR=$(ls .build-sim/Build/Products/*.xctestrun | head -1)
TEST_RUNNER_LAB_ARGS="$ARGS" TEST_RUNNER_LAB_WAIT="$WAIT" nice xcodebuild test-without-building -xctestrun "$XR" \
  -destination "id=$SIM" -only-testing:TimelineLabUITests/LabUITests/$T -resultBundlePath "$OUT/result.xcresult" > "$OUT/xcodebuild.log" 2>&1
echo "exit=$?"
grep -v "claude(timeline-lab)" $RUN > $RUN.tmp; cat $RUN.tmp > $RUN; rm $RUN.tmp
rm -rf "$OUT/container"; mkdir -p "$OUT/container"
C=$(xcrun simctl get_app_container $SIM research.inline.TimelineLab data 2>/dev/null)
[ -n "$C" ] && cp -R "$C/Documents/." "$OUT/container/"
grep -E "UITEST|\*\* TEST" "$OUT/xcodebuild.log" | head -20
