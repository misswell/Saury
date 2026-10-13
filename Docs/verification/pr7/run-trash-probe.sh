#!/bin/bash
# PR7d 回收站到期清理探针（任务书 §10.6「30 天期限有真实的数据清理任务」「清理时间以删除时间为准」
# 「永久清理后的事件和图标处理规则必须一致」）。
#
# 验的是「到期之后真的有人动手」这整段，而且把两条触发路分开：
# ①落盘广播 → 根视图那一脚；②故意不落盘（没有广播）→ 只有回收站页 `.task` 那一脚能动。
# 图标按引用计数看盘上文件：独占那张要没，共用那张要等最后一个引用走掉才没。
# 种数据、软删除、清理、弹层用的都是真那套代码（`SubscriptionRepository` / `TrashJanitor`），
# 没有另搭演示通路。
#
# 模拟器只用 AGENTS.md 允许的那一台（D13B9A45-CEDF-4479-BA64-25C1D38750A8）。
# 产物：build/verification/pr7/trash-probe.log（全量日志）+ 三张快门
# （回收站页 1 张；③ 的前后两帧拍在订阅列表上，那一屏才看得到「还在用这张图」那条）。
set -u
UD=D13B9A45-CEDF-4479-BA64-25C1D38750A8
BUNDLE=com.guofeng.saury
APP=${APP:-/Users/guofeng/Library/Developer/Xcode/DerivedData/Saury-dzqslrgxwmaolqbjenwhdamembcc/Build/Products/Debug-iphonesimulator/Saury.app}
OUT=/Users/guofeng/Code/solo/Saury/build/verification/pr7
mkdir -p "$OUT"

xcrun simctl install "$UD" "$APP" || exit 1
xcrun simctl spawn "$UD" log stream --style compact \
    --predicate 'subsystem == "com.guofeng.saury"' > "$OUT/trash-probe.log" 2>/dev/null &
LP=$!
sleep 1
# `-saury-demo` 是这套探针的总闸（RootView 里那一串都在它后面）。注意它还有个副作用：
# 库空的时候往里灌三行示例订阅（RootView.swift:253-259 的 `install(DemoDataSeeder…)`），库不空则跳过。
# 探针自己开场会先清掉它上一趟留下的数据（幂等），起点条数以日志里「开场」「起点」两行为准。
xcrun simctl launch --terminate-running-process "$UD" "$BUNDLE" -saury-demo -saury-trash >/dev/null
sleep 44
kill "$LP" 2>/dev/null
xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null

C=$(xcrun simctl get_app_container "$UD" "$BUNDLE" data)
cp "$C/tmp/saury-probe/trash-01-page-after-purge.png" \
   "$C/tmp/saury-probe/trash-02-keeper-still-on-list.png" \
   "$C/tmp/saury-probe/trash-03-keeper-gone.png" "$OUT/" 2>/dev/null
grep -a "回收站探针" "$OUT/trash-probe.log"
