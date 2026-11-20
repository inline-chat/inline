#!/bin/zsh
# Phase-0b device runs. Usage: scripts/phase0b.sh <outdir> [A|B1|B2|B3|all]
# Prerequisite (once): build-for-testing (see README line in the report). Each line is one XCUITest run; batch.sh
# checks the lock state before every run and stops if the phone is locked or automation times out.
OUT=${1:?outdir}; PART=${2:-all}
B=$(dirname $0)/batch.sh
if [[ $PART == A || $PART == all ]]; then
$B $OUT \
 "testS4Swipe|-mode S4 -s4 keepignore|s4_keepignore" \
 "testSelfDriven|-mode S1 -autorun 1 -variants A -reps 3 -s1scen open -s1delay 4|first_base|30" \
 "testSelfDriven|-mode S1 -autorun 1 -variants A -reps 3 -s1scen open -s1delay 4 -composerext 1|first_ext|30" \
 "testSelfDriven|-mode S1 -autorun 1 -variants A -reps 3 -s1scen open -s1delay 4 -prewarm swap|first_swap|30" \
 "testSelfDriven|-mode S1 -autorun 1 -prewarm swap -swapfx 1 -s1delay 2|swapfx|20" \
 "testS4Swipe|-mode S4 -s4 keepignore -prewarm swap -s4closed 1|s4_swapclosed" \
 "testS2Synth|-mode S2priv -kbmove transform -synth 1 -autorun 1|s2synth|40" \
 "testS2Synth|-mode S2priv -kbmove transform -synth 1 -autorun 1 -prewarm swap|s2synth_swap|40" || exit $?
fi
if [[ $PART == B1 || $PART == all ]]; then
# velocity estimators logged against UIKit's on the same drags (U), and the old C for reference
$B $OUT \
 "testS3c|-mode S3U -noreset 1|s3c_U" \
 "testS3c|-mode S3C -noreset 1 -clegacy 1|s3c_C_legacy" || exit $?
fi
if [[ $PART == B2 || $PART == all ]]; then
# C with the fitted constants; VEST/BOOST chosen from the B1 analysis (defaults: lsq80, 1.05)
$B $OUT \
 "testS3c|-mode S3C -noreset 1 -vest ${VEST:-lsq80} -v0boost ${BOOST:-1.05}|s3c_C_fit" \
 "testS3|-mode S3U -recenter 300|s3_U_recenter" || exit $?
fi
if [[ $PART == B3 || $PART == all ]]; then
# 2000-row list, 2 ms per row creation, realisation ±160 pt around the predicted position
$B $OUT \
 "testS3c|-mode S3L -engine C -rows 2000 -rowcost 2 -noreset 1 -vest ${VEST:-lsq80} -v0boost ${BOOST:-1.05}|s3l_C" \
 "testS3c|-mode S3L -engine U -rows 2000 -rowcost 2 -noreset 1|s3l_U" \
 "testS3c|-mode S3L -engine C -rows 2000 -rowcost 2 -noreset 1 -hitch 1 -vest ${VEST:-lsq80} -v0boost ${BOOST:-1.05}|s3l_C_hitch" \
 "testS3c|-mode S3L -engine U -rows 2000 -rowcost 2 -noreset 1 -hitch 1|s3l_U_hitch" \
 "testS3c|-mode S3L -engine C -rows 2000 -rowcost 2 -noreset 1 -prepend 1 -vest ${VEST:-lsq80} -v0boost ${BOOST:-1.05}|s3l_C_prepend" \
 "testS3c|-mode S3L -engine U -rows 2000 -rowcost 2 -noreset 1 -prepend 1|s3l_U_prepend" || exit $?
fi
