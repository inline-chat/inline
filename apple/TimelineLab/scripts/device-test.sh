#!/bin/zsh
# Runs one lab UI test on the iPhone SE and collects its screenshots and video: HarnessUITests by default, or the
# class in CLASS (ProdUITests drives the installed production app).
# usage: [CLASS=ProdUITests] device-test.sh <testName> <outdir> ["extra harness args"]
# Prerequisites: the lab's runner is built for testing (.build-xcode) and Inline Debug with the harness is installed.
set -u
cd "$(dirname $0)/.."
T=$1; OUT=$2; ARGS=${3:-}
DEV=00008030-001E18CA0ED1402E
RUN=/Users/mo/dev/inline-chat/inline/.running
if xcrun devicectl device info lockState --device $DEV 2>&1 | grep -q "passcodeRequired: true"; then echo "LOCKED before $T"; exit 3; fi
echo "$(date '+%Y-%m-%d %H:%M') claude(timeline-device): xcodebuild test-without-building ${CLASS:-HarnessUITests}/$T $ARGS" >> $RUN
rm -rf "$OUT"; mkdir -p "$OUT"
XR=.build-xcode/Build/Products/keep.xctestrun
cp .build-xcode/Build/Products/TimelineLab_iphoneos27.2-arm64.xctestrun $XR
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
TEST_RUNNER_HARNESS_ARGS="$ARGS" xcodebuild test-without-building -xctestrun $XR \
  -destination "id=$DEV" -only-testing:TimelineLabUITests/${CLASS:-HarnessUITests}/$T \
  -resultBundlePath "$OUT/result.xcresult" > "$OUT/xcodebuild.log" 2>&1
echo "exit=$?"
grep -v "claude(timeline-device): xcodebuild test-without-building ${CLASS:-HarnessUITests}/$T" $RUN > $RUN.tmp; cat $RUN.tmp > $RUN; rm $RUN.tmp
mkdir -p "$OUT/attachments"; xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/attachments" > /dev/null 2>&1
grep -E "\[UITEST\]|Test Case|error:|\*\* TEST|Unlock" "$OUT/xcodebuild.log" | head -60
# The in-app frame probe (only with --timeline-harness-probe), just that file.
if [[ "$ARGS" == *--timeline-harness-probe* ]]; then
  xcrun devicectl device copy from --device $DEV --domain-type appDataContainer --domain-identifier chat.inline.InlineIOS.debug \
    --source Documents/timeline-probe.csv --destination "$OUT/probe.csv" > /dev/null 2>&1 && echo "probe: $(wc -l < $OUT/probe.csv) frames"
fi
