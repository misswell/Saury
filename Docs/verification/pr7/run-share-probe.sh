#!/bin/bash
# PR7c 分享扩展探针（任务书 §10.5「分享图片时不得静默丢弃」「草稿队列按顺序消费」）。
#
# 命令行点不动系统分享面板，所以这一条验的是「扩展那一份线上 JSON + App Group 暂存目录」
# 到「新增页带着图标出现」这整段：草稿由 App 内部按 `SauryShare/ShareViewController.swift`
# 手写的同一份形状放进 App Group，消费走的是用户回到前台时真的那一句 `drainExternalInput()`。
# 不是另搭一条演示通路 —— 解码、搬图、弹层、预填用的都是真那套代码。
#
# 模拟器只用 AGENTS.md 允许的那一台（D13B9A45-CEDF-4479-BA64-25C1D38750A8）。
# 产物：build/verification/pr7/share-probe.log（全量日志）+ 两张快门。
set -u
UD=D13B9A45-CEDF-4479-BA64-25C1D38750A8
BUNDLE=com.guofeng.saury
APP=${APP:-/Users/guofeng/Library/Developer/Xcode/DerivedData/Saury-dzqslrgxwmaolqbjenwhdamembcc/Build/Products/Debug-iphonesimulator/Saury.app}
OUT=/Users/guofeng/Code/solo/Saury/build/verification/pr7
mkdir -p "$OUT"

xcrun simctl install "$UD" "$APP" || exit 1
xcrun simctl spawn "$UD" log stream --style compact \
    --predicate 'subsystem == "com.guofeng.saury"' > "$OUT/share-probe.log" 2>/dev/null &
LP=$!
sleep 1
# `-saury-demo` 是这套探针的总闸（RootView 里那一串都在它后面），不是演示数据的意思。
xcrun simctl launch --terminate-running-process "$UD" "$BUNDLE" -saury-demo -saury-share >/dev/null
sleep 26
kill "$LP" 2>/dev/null
xcrun simctl terminate "$UD" "$BUNDLE" 2>/dev/null

C=$(xcrun simctl get_app_container "$UD" "$BUNDLE" data)
cp "$C/tmp/saury-probe/share-01-image-icon.png" "$C/tmp/saury-probe/share-02-text-name.png" "$OUT/" 2>/dev/null
grep -a "分享探针" "$OUT/share-probe.log"
