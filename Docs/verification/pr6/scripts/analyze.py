#!/usr/bin/env python3
"""PR6 逐帧量测：把一段录屏的某一区域按帧拆开，量「有没有空白帧 / 是不是一步跳到位」。

用法：
  analyze.py <video> <w> <h> <x> <y> [--prefix TAG] [--scale N]

只依赖标准库：ffmpeg 负责解码成 rgb24 裸帧，这里按帧流式读，不一次吃进内存。
区域默认再缩到 96 宽（`--scale` 改），因为纯 Python 逐像素吃不下 1170 宽的原帧；
面积型的判断（空白帧、环形被清零、一步跳到位的尖峰）在缩图上同样成立。
输出三组数：
  motion  相邻帧的平均绝对差（MAD），用来分「有内容的帧」和「静止帧」
  spike   单帧最大跳变（一步跳到位 = 一个巨大的孤立尖峰；连续过渡 = 一串中等值）
  colour  每帧里「有颜色的像素」占比，环形图被清零时这一列会掉到 0
"""
import os
import subprocess
import sys
import tempfile


def main():
    video = sys.argv[1]
    w, h, x, y = map(int, sys.argv[2:6])
    prefix = ""
    scale = 96
    if "--prefix" in sys.argv:
        prefix = sys.argv[sys.argv.index("--prefix") + 1] + " "
    if "--scale" in sys.argv:
        scale = int(sys.argv[sys.argv.index("--scale") + 1])

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
             "-fps_mode", "passthrough", "-f", "rawvideo", raw], check=True)
        frame_bytes = sw * sh * 3
        count = min(os.path.getsize(raw) // frame_bytes, len(pts))
        offsets = range(0, frame_bytes, 9)  # 每三个像素取一个

        rows = []
        prev = None
        with open(raw, "rb") as fh:
            for i in range(count):
                buf = fh.read(frame_bytes)
                if len(buf) != frame_bytes:
                    break
                lum = 0
                colour = 0
                sampled = 0
                mad = 0.0
                for off in offsets:
                    r, g, b = buf[off], buf[off + 1], buf[off + 2]
                    lum += (r + g + b) // 3
                    if max(r, g, b) - min(r, g, b) > 40:
                        colour += 1
                    sampled += 1
                    if prev is not None:
                        mad += abs(r - prev[off]) + abs(g - prev[off + 1]) + abs(b - prev[off + 2])
                rows.append((pts[i], lum / sampled, colour / sampled,
                             mad / (sampled * 3) if prev is not None else 0.0))
                prev = buf

        print(f"== {prefix}{os.path.basename(video)} 区域 {w}x{h}+{x}+{y}"
              f"（缩到 {sw}x{sh}）帧数 {len(rows)}")
        motion = [(t, mad) for t, _, _, mad in rows if mad > 1.0]
        if motion:
            span = motion[-1][0] - motion[0][0]
            gaps = [b - a for (a, _), (b, _) in zip(motion, motion[1:])]
            print(f"   运动帧 {len(motion)} 张，首末跨度 {span * 1000:.0f}ms，"
                  f"相邻间隔中位数 {median(gaps) * 1000:.1f}ms")
            biggest = max(rows, key=lambda r: r[3])
            print(f"   最大单帧跳变 MAD={biggest[3]:.2f} @ {biggest[0]:.3f}s")
            print("   前 6 个跳变 "
                  + str(['%.2f' % v for v in sorted((r[3] for r in rows), reverse=True)[:6]]))
        else:
            print("   这一段里没有 MAD>1 的帧（区域几乎没动）")
        lowest = min(rows, key=lambda r: r[2])
        print(f"   彩色像素占比：起 {rows[0][2] * 100:.2f}% 最低 {lowest[2] * 100:.2f}%"
              f" @ {lowest[0]:.3f}s 末 {rows[-1][2] * 100:.2f}%")
        dark = [r for r in rows if r[1] < 12]
        print(f"   近全黑帧（区域均值<12/255）：{len(dark)} 张"
              + (f"，最早 @ {dark[0][0]:.3f}s" if dark else ""))
    finally:
        os.unlink(raw)


def median(values):
    if not values:
        return 0.0
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


main()
