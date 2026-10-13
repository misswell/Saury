#!/bin/bash
# 只补录一个场景（其余三条已经拍好了时用，省两分钟）。
set -u
UD=D13B9A45-CEDF-4479-BA64-25C1D38750A8
BUNDLE=com.guofeng.saury
OUT=${OUT:?要给出 OUT}
mkdir -p "$OUT"; cd "$OUT" || exit 1
name=$1 dur=$2; shift 2
xcrun simctl spawn "$UD" log stream --style compact \
    --predicate 'subsystem == "com.guofeng.saury" AND category == "probe"' > "$name.log" 2>/dev/null &
lp=$!
sleep 1
xcrun simctl io "$UD" recordVideo --codec=h264 --force "$name.mp4" > /dev/null 2>&1 &
vp=$!
sleep 2
xcrun simctl launch --terminate-running-process "$UD" "$BUNDLE" "$@" > /dev/null
sleep "$dur"
kill -INT "$vp" 2>/dev/null
sleep 2
kill "$lp" 2>/dev/null
xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null
ls -l "$name.mp4" | awk '{print $5, $9}'
