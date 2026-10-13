#!/usr/bin/env python3
"""从 motion.py --mad -1 --dump 的输出里，按「噪声底」把连续运动段切出来。

    runs.py <floor>        # 读 stdin

一帧相邻差低于 floor 就当静止；连续 floor 以上的帧算一段运动，报起止、跨度、帧数。
"""
import sys

floor = float(sys.argv[1])
rows = []
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 2 or not parts[0].replace(".", "", 1).isdigit():
        continue
    rows.append((float(parts[0]), float(parts[1].split("=")[1])))

runs, current = [], []
for t, mad in rows:
    if mad >= floor:
        current.append((t, mad))
    elif current:
        runs.append(current)
        current = []
if current:
    runs.append(current)

for i, run in enumerate(runs, 1):
    gaps = sorted(run[k][0] - run[k - 1][0] for k in range(1, len(run)))
    median = gaps[len(gaps) // 2] * 1000 if gaps else 0.0
    print(f"#{i} {run[0][0]:.3f} → {run[-1][0]:.3f}｜{(run[-1][0] - run[0][0]) * 1000:.0f} ms"
          f"｜{len(run)} 帧｜峰值 MAD {max(r[1] for r in run):.2f}"
          f"｜帧间隔中位 {median:.0f} ms")
