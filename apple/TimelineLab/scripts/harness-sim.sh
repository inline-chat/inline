#!/bin/zsh
# Runs one HarnessUITests test against the Inline Debug app on a simulator and collects its screenshots,
# video and probe. The tests' coordinates are for a 375 x 667 pt screen, so use an iPhone SE (3rd generation).
# usage: harness-sim.sh <simUDID> <testName> <outdir> ["extra harness args"]
# Prerequisites: the lab's runner is built for testing into .build-sim for that simulator, and Inline Debug
# (a simulator build) is installed on it.
set -u
cd "$(dirname $0)/.."
SIM=$1; T=$2; OUT=$3; ARGS=${4:-}
RUN=/Users/mo/dev/inline-chat/inline/.running
echo "$(date '+%Y-%m-%d %H:%M') claude(timeline-v4): xcodebuild test-without-building (SIMULATOR) HarnessUITests/$T $ARGS" >> $RUN
rm -rf "$OUT"; mkdir -p "$OUT"
XR=$(ls .build-sim/Build/Products/*.xctestrun | grep -v keep | head -1)
TEST_RUNNER_HARNESS_ARGS="$ARGS" nice xcodebuild test-without-building -xctestrun "$XR" \
  -destination "id=$SIM" -only-testing:TimelineLabUITests/HarnessUITests/$T \
  -resultBundlePath "$OUT/result.xcresult" > "$OUT/xcodebuild.log" 2>&1
echo "exit=$?"
grep -v "claude(timeline-v4): xcodebuild test-without-building (SIMULATOR)" $RUN > $RUN.tmp; cat $RUN.tmp > $RUN; rm $RUN.tmp
mkdir -p "$OUT/attachments"; xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/attachments" > /dev/null 2>&1
grep -E "\[UITEST\]|Test Case|error:|\*\* TEST" "$OUT/xcodebuild.log" | head -60
if [[ "$ARGS" == *--timeline-harness-probe* ]]; then
  C=$(xcrun simctl get_app_container $SIM chat.inline.InlineIOS.debug data 2>/dev/null)
  [ -n "$C" ] && cp "$C/Documents/timeline-probe.csv" "$OUT/probe.csv" 2>/dev/null && echo "probe: $(wc -l < $OUT/probe.csv) frames"
fi
