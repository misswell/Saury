#!/bin/bash
# 把 PR6 的五个场景 + 减少动态效果两组，全部按同一套量测重跑一遍，输出留档。
# 每个场景的裁剪框都对着 1170x2532 的原视频量过：只框住要判定的那块，别把无关的抖动算进来。
#
# 前置：$EV 下得先有那 14 段录屏和探针日志。它们在 build/ 里（gitignore 掉的），
# 重录用同目录的 record-one.sh / record-01-pair.sh / record-05-pair.sh /
# record-reduce-motion.sh / swap-and-record-before.sh。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
EV=/Users/guofeng/Code/solo/Saury/build/verification/pr6
OUT="$HERE/../results"
mkdir -p "$OUT"
cd "$HERE" || exit 1

run() { name=$1; shift; { printf '########'; printf ' "%s"' "$@"; printf ' ########\n'; python3 "$@" 2>&1; echo; } >> "$OUT/$name.txt"; }

for pair in before after; do
  : > "$OUT/01-$pair.txt"; : > "$OUT/02-$pair.txt"; : > "$OUT/03-$pair.txt"
  : > "$OUT/04-$pair.txt"; : > "$OUT/05-$pair.txt"

  # 01 轮播：同一串 −150pt 拖动，看松手后怎么停下 + 每帧走了多远
  run "01-$pair" fling.py "$EV/$pair/01-carousel-fling.mp4" "$EV/$pair/01-carousel-fling.log" \
      1090 420 40 760 --grep "探针 up" --quiet 120
  run "01-$pair" track.py "$EV/$pair/01-carousel-fling.mp4" 40 760 1090 420 --max 60 --label "$pair"

  # 02 日历翻月：整块日历区域的逐帧突发
  run "02-$pair" motion.py "$EV/$pair/02-calendar-flip.mp4" 1090 1000 40 1180 --label "$pair 日历"
  run "02-$pair" latency.py "$EV/$pair/02-calendar-flip.mp4" "$EV/$pair/02-calendar-flip.log" \
      1090 1000 40 1180 --grep "日历探针 第" --label "$pair 日历按下"

  # 03 统计周期：本月总额那个数字
  run "03-$pair" motion.py "$EV/$pair/03-period-number.mp4" 560 140 40 380 --label "$pair 数字"
  run "03-$pair" latency.py "$EV/$pair/03-period-number.mp4" "$EV/$pair/03-period-number.log" \
      560 140 40 380 --grep "周期探针 →" --label "$pair 数字按下"

  # 04 图表：柱状↔折线切换
  run "04-$pair" motion.py "$EV/$pair/04-charts-morph.mp4" 1090 620 40 1180 --label "$pair 图表"
  run "04-$pair" latency.py "$EV/$pair/04-charts-morph.mp4" "$EV/$pair/04-charts-morph.log" \
      1090 620 40 1180 --grep "图表探针 切" --label "$pair 图表按下"

  # 05 三 Tab 往返 + 弹窗：整屏
  run "05-$pair" motion.py "$EV/$pair/05-motion-script.mp4" 1170 2532 0 0 --label "$pair 全脚本"
done

for pair in before-reduce-motion after-reduce-motion; do
  : > "$OUT/02-$pair.txt"; : > "$OUT/03-$pair.txt"
  run "02-$pair" motion.py "$EV/$pair/02-calendar-flip.mp4" 1090 1000 40 1180 --label "$pair 日历"
  run "03-$pair" motion.py "$EV/$pair/03-period-number.mp4" 560 140 40 380 --label "$pair 数字"
done

wc -l "$OUT"/*.txt | tail -20
