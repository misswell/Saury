#!/usr/bin/env python3
"""PR6 逐帧量测：把录屏的某个区域按帧拆开，找「运动突发」并量每一次的连续性。

    motion.py <video> <w> <h> <x> <y> [--scale N] [--from T] [--to T] [--label S]

只依赖标准库。ffmpeg 解码成 rgb24 裸帧，这里按帧流式读。
区域默认缩到 96 宽：纯 Python 逐像素吃不下 1170 宽的原帧，而这里要判的都是面积量
（空白帧、环形被清零、一步跳到位的孤立尖峰），缩图上同样成立。

每次突发给出：
  起点 / 跨度 / 帧数      —— 动效总时长与实际可见的连续运动时间
  最大单帧跳变 + 排名     —— 连续过渡是一串中等值，瞬移是一个孤立大尖峰
  突发内最低彩色占比      —— 环形图被「先清零」时这一列会掉到 0
  突发内近全黑帧数        —— 过渡中的空白帧 / 背景闪现
"""
import os
import subprocess
import sys
import tempfile

MOTION_MAD = 1.0      # 相邻帧平均绝对差阈值（0–255）
BURST_GAP = 0.12      # 超过这么久的静止算下一次突发
BLACK_LUM = 12.0      # 区域均值低于此算近全黑


def main():
    video = sys.argv[1]
    w, h, x, y = map(int, sys.argv[2:6])
    argv = sys.argv
    def opt(name, default):
        return argv[argv.index(name) + 1] if name in argv else default
    scale = int(opt("--scale", 96))
    lo = float(opt("--from", 0.0))
    hi = float(opt("--to", 1e9))
    MOTION_MAD = float(opt("--mad", 1.0))
    dump = "--dump" in argv
    label = opt("--label", "")

    times = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "frame=pts_time", "-of", "csv=p=0", video],
        capture_output=True, text=True, check=True).stdout
    pts = [float(t.strip().rstrip(",")) for t in times.splitlines() if t.strip()]

    sw = scale
    sh = max(1, round(h * scale / w))
    raw = tempfile.NamedTemporaryFile(delete=False, suffix=".raw").name
    try:
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", f"crop={w}:{h}:{x}:{y},scale={sw}:{sh},format=rgb24",
             "-fps_mode", "passthrough", "-f", "rawvideo", raw],
            check=True, stderr=subprocess.DEVNULL)
        frame_bytes = sw * sh * 3
        count = min(os.path.getsize(raw) // frame_bytes, len(pts))
        offsets = range(0, frame_bytes, 9)

        rows = []
        prev = None
        with open(raw, "rb") as fh:
            for index in range(count):
                buf = fh.read(frame_bytes)
                if len(buf) != frame_bytes:
                    break
                t = pts[index]
                lum = colour = sampled = diff = 0
                for off in offsets:
                    r, g, b = buf[off], buf[off + 1], buf[off + 2]
                    lum += (r + g + b) // 3
                    if max(r, g, b) - min(r, g, b) > 40:
                        colour += 1
                    sampled += 1
                    if prev is not None:
                        diff += abs(r - prev[off]) + abs(g - prev[off + 1]) + abs(b - prev[off + 2])
                if prev is not None and lo <= t <= hi:
                    rows.append((t, lum / sampled, colour / sampled, diff / (sampled * 3)))
                prev = buf

        bursts = []
        if dump:
            for row in rows:
                if row[3] > MOTION_MAD:
                    print(f"   {row[0]:.3f} MAD={row[3]:.2f} lum={row[1]:.1f}"
                          f" colour={row[2] * 100:.1f}%")
            return
        current = []
        for position, row in enumerate(rows):
            gap_anchor = rows[position - 1][0] if position else row[0]
            if row[3] > MOTION_MAD:
                if current and row[0] - current[-1][0] > BURST_GAP:
                    bursts.append(current)
                    current = []
                current.append(row)
            elif current and row[0] - gap_anchor > BURST_GAP:
                bursts.append(current)
                current = []
        if current:
            bursts.append(current)

        print(f"== {label}{os.path.basename(video)} 区域 {w}x{h}+{x}+{y}"
              f"（缩到 {sw}x{sh}）窗口 {lo:.2f}–{hi:.2f}s，帧 {len(rows)}，突发 {len(bursts)} 次")
        for i, burst in enumerate(bursts, 1):
            onset = burst[0][0]
            span = burst[-1][0] - onset
            peak = max(burst, key=lambda r: r[3])
            col = min(burst, key=lambda r: r[2])
            blacks = sum(1 for r in burst if r[1] < BLACK_LUM)
            neighbours = sorted((r[3] for r in rows), reverse=True)[:8]
            isolated = peak[3] > 3 * max([r[3] for r in burst if r is not peak] or [0])
            print(f"   #{i} 起 {onset:.3f}s 跨 {span * 1000:.0f}ms {len(burst)} 帧"
                  f"｜最大跳变 {peak[3]:.2f} @ {peak[0]:.3f}s"
                  f"{'（孤立尖峰＝一步到位）' if isolated and len(burst) > 2 else ''}"
                  f"｜最低彩色 {col[2] * 100:.1f}% @ {col[0]:.3f}s"
                  f"｜近全黑 {blacks} 帧")
            if i == 1 and neighbours:
                pass
    finally:
        os.unlink(raw)


main()
