#!/bin/zsh
# usage: uitest.sh <testName> "<lab args>" [wait] [outdir]
set -u
cd "$(dirname $0)/.."
T=$1; ARGS=$2; WAIT=${3:-30}; OUT=${4:-/tmp/lab}
RUN=/Users/mo/dev/inline-chat/inline/.running
echo "$(date '+%Y-%m-%d %H:%M') claude(timeline-lab): xcodebuild test-without-building $T $ARGS" >> $RUN
rm -rf "$OUT/result.xcresult"; mkdir -p "$OUT"
XR=.build-xcode/Build/Products/keep.xctestrun
cp .build-xcode/Build/Products/TimelineLab_iphoneos27.2-arm64.xctestrun $XR
for k in $(plutil -p $XR | grep -B0 SystemAttachmentLifetime >/dev/null; /usr/libexec/PlistBuddy -c Print $XR | grep -E "^    [A-Za-z]" | awk '{print $1}' | grep -v -E "^(__xctestrun_metadata__|TestConfigurations|TestPlan|CodeCoverageBuildableInfos)$"); do :; done
python3 - $XR <<'PY'
import plistlib,sys
p=sys.argv[1]; d=plistlib.load(open(p,'rb'))
def fix(o):
    if isinstance(o,dict):
        for k in list(o):
            if k in ('SystemAttachmentLifetime','UserAttachmentLifetime'): o[k]='keepAlways'
            else: fix(o[k])
    elif isinstance(o,list):
        for x in o: fix(x)
fix(d); plistlib.dump(d,open(p,'wb'))
PY
TEST_RUNNER_LAB_ARGS="$ARGS" TEST_RUNNER_LAB_WAIT="$WAIT" TEST_RUNNER_TAP_YS="${TAP_YS:-560,460}" xcodebuild test-without-building \
  -xctestrun $XR \
  -destination 'id=00008030-001E18CA0ED1402E' -only-testing:TimelineLabUITests/LabUITests/$T \
  -resultBundlePath "$OUT/result.xcresult" > "$OUT/xcodebuild.log" 2>&1
echo "exit=$?"
grep -v "claude(timeline-lab)" $RUN > $RUN.tmp; cat $RUN.tmp > $RUN; rm $RUN.tmp
rm -rf "$OUT/container"; mkdir -p "$OUT/container"
xcrun devicectl device copy from --device 00008030-001E18CA0ED1402E --domain-type appDataContainer --domain-identifier research.inline.TimelineLab --source Documents --destination "$OUT/container" > /dev/null 2>&1
rm -rf "$OUT/attachments"; mkdir -p "$OUT/attachments"; xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/attachments" > /dev/null 2>&1
grep -E "UITEST|Test Case|error|\*\* TEST" "$OUT/xcodebuild.log" | head -40
# analyse the run's video if present
V=$(ls "$OUT"/attachments/*.mp4 2>/dev/null | head -1)
if [ -n "$V" ]; then /private/tmp/claude-501/-Users-mo-dev-inline-chat-inline/7e34b1b9-1f40-4548-bf19-ea5c5b542b83/scratchpad/tools/vanalyze "$V" "$OUT/video.csv" > /dev/null; echo "video analysed: $(wc -l < $OUT/video.csv) frames"; fi
