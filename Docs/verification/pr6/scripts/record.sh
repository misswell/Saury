#!/bin/bash
# PR6 动效录屏：每个场景一遍「外部录屏 + 探针日志」。
# 单设备（不新建 Simulator），录屏用 kill -INT 收尾，否则 Recorder 资源会一直被占着。
set -u
UD=D13B9A45-CEDF-4479-BA64-25C1D38750A8
BUNDLE=com.guofeng.saury
OUT=${OUT:-/Users/guofeng/Code/solo/Saury/build/verification/pr6}
mkdir -p "$OUT"
cd "$OUT" || exit 1

scene() {
    local name=$1 dur=$2; shift 2
    printf '\n=== %s（%ss，参数：%s）\n' "$name" "$dur" "$*"
    xcrun simctl spawn "$UD" log stream --style compact \
        --predicate 'subsystem == "com.guofeng.saury" AND category == "probe"' > "$name.log" 2>/dev/null &
    local lp=$!
    sleep 1
    xcrun simctl io "$UD" recordVideo --codec=h264 --force "$name.mp4" > /dev/null 2>&1 &
    local vp=$!
    sleep 2
    xcrun simctl launch --terminate-running-process "$UD" "$BUNDLE" "$@" > /dev/null
    sleep "$dur"
    kill -INT "$vp" 2>/dev/null
    sleep 2
    kill "$lp" 2>/dev/null
    xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null
    ls -l "$name.mp4" | awk '{print $5, $9}'
    sleep 3
}

scene 01-carousel-fling 12 -saury-demo -saury-tab overview -saury-fling
scene 02-calendar-flip 9 -saury-demo -saury-tab calendar -saury-months
scene 03-period-number 10 -saury-demo -saury-tab overview -saury-period -saury-number
scene 04-charts-morph 19 -saury-demo -saury-tab overview -saury-chart
