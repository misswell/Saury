#!/bin/bash
# PR6「之前」录屏：把模拟器里的库和偏好整份挪开（可逆，不删），
# 装基准提交的副本，让它自己灌一份和「之后」同款的示例数据，再录四个场景。
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
C=$(xcrun simctl get_app_container "$UD" "$BUNDLE" data)

xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null
sleep 1

BK=${BK:-/tmp/saury-pr6/aside-orig}
mkdir -p "$BK/store" "$BK/prefs"
mv "$S/default.store" "$S/default.store-wal" "$S/default.store-shm" "$BK/store/" 2>/dev/null
mv "$GP/group.com.guofeng.saury.plist" "$BK/prefs/" 2>/dev/null
mv "$C/Library/Preferences/$BUNDLE.plist" "$BK/prefs/" 2>/dev/null
echo "$BK" > /tmp/saury-pr6/aside-path
echo "挪开：$(ls "$BK/store" "$BK/prefs" 2>/dev/null | tr '\n' ' ')"
ls "$S" "$GP"

xcrun simctl install "$UD" /tmp/saury-pr6/dd-before/Build/Products/Debug-iphonesimulator/Saury.app || exit 1
echo "基准包装好了"
OUT=/Users/guofeng/Code/solo/Saury/build/verification/pr6/before bash "$HERE"/record.sh
