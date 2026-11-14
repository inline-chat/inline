#!/bin/zsh
# usage: batch.sh outroot "test|args|name" ...   (stops if the phone is locked)
OUT=$1; shift
cd "$(dirname $0)/.."
for spec in "$@"; do
  T=$(echo "$spec" | cut -d'|' -f1); A=$(echo "$spec" | cut -d'|' -f2); N=$(echo "$spec" | cut -d'|' -f3); W=$(echo "$spec" | cut -d'|' -f4); W=${W:-0}
  if xcrun devicectl device info lockState --device 00008030-001E18CA0ED1402E 2>&1 | grep -q "passcodeRequired: true"; then echo "LOCKED before $N"; exit 3; fi
  echo "== $N"; ./scripts/uitest.sh $T "$A" $W $OUT/$N | tail -2
  if grep -q "Unlock .* to Continue" $OUT/$N/xcodebuild.log; then echo "LOCKED during $N"; pkill -f "xcodebuild test-without-building"; exit 3; fi
done
