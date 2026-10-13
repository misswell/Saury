#!/bin/bash
# 05 · 三 Tab 往返 + 弹窗进出 + 切完就 push 详情（§9.2 的中断场景）。
# 两条录制用的是同一张脚本表：`-saury-motion` 在基准提交和当前树上都有，
# 时刻一模一样（8.0/10.5/13.0/16.0/19.0/21.5/24.0），只是落地动作各写各的。
# 依赖的本机状态（worktree 和编译产物不进仓库，探针 diff 进仓库）：
#   git worktree add /Users/guofeng/Code/solo/Saury-baseline 021d939
#   探针 diff 就在仓库里：git apply "$HERE/../baseline-probes.patch"
#   （只有 Logger 打点、ProbeMarker 白带和 -saury-* 启动参数，没有一行改动画语义），编到 /tmp/saury-pr6/dd-before。
#   所以那份副本的行号和 `git show 021d939:<path>` 对不上，引基准源码一律以后者为准。
#   模拟器只用 AGENTS.md 允许的那一台（D13B9A45-CEDF-4479-BA64-25C1D38750A8）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UD=D13B9A45-CEDF-4479-BA64-25C1D38750A8
BUNDLE=com.guofeng.saury
G=/Users/guofeng/Library/Developer/CoreSimulator/Devices/$UD/data/Containers/Shared/AppGroup/CEB738E4-8FFA-493F-B22A-B3FA4DA0A1E4
S="$G/Library/Application Support"
GP="$G/Library/Preferences"
OUT=/Users/guofeng/Code/solo/Saury/build/verification/pr6
PAIR=/tmp/saury-pr6/aside-05pair
mkdir -p "$PAIR"

take() {   # take <tree> <app 路径> <输出目录>
    local tree=$1 app=$2 dir=$3
    xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null
    sleep 1
    C=$(xcrun simctl get_app_container "$UD" "$BUNDLE" data)
    mkdir -p "$PAIR/$tree/store" "$PAIR/$tree/prefs"
    mv "$S"/default.store "$S"/default.store-wal "$S"/default.store-shm "$PAIR/$tree/store/" 2>/dev/null
    mv "$GP/group.com.guofeng.saury.plist" "$PAIR/$tree/prefs/" 2>/dev/null
    mv "$C/Library/Preferences/$BUNDLE.plist" "$PAIR/$tree/prefs/" 2>/dev/null
    xcrun simctl install "$UD" "$app" || return 1
    xcrun simctl launch "$UD" "$BUNDLE" -saury-demo > /dev/null || return 1
    sleep 9
    xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null
    sleep 2
    echo "=== $tree 预热完，开始录 05"
    OUT="$dir" bash "$HERE"/record-one.sh 05-motion-script 30 -saury-demo -saury-motion
}

take before /tmp/saury-pr6/dd-before/Build/Products/Debug-iphonesimulator/Saury.app "$OUT/before"
take after \
    /Users/guofeng/Library/Developer/Xcode/DerivedData/Saury-dzqslrgxwmaolqbjenwhdamembcc/Build/Products/Debug-iphonesimulator/Saury.app \
    "$OUT/after"
