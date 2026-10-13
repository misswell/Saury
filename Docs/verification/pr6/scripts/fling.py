#!/usr/bin/env python3
"""松手之后那段「甩动」到底是怎么停下来的：逐次量每一次释放。

    fling.py <video> <log> <w> <h> <x> <y> --grep <样式> [--quiet MS]

和 motion.py 的区别：motion.py 只认「屏幕上有没有在动」，这里以日志里的一次
**松手**为锚点，把录屏时间轴用打点钉准，然后只看松手之后 1.2 秒那一段：

  首帧动 / 末帧动      —— 松手到开始减速、到彻底停住
  段内帧数             —— 这一段里屏幕交出了多少张不同的画面（连续过渡 vs 一步到位）
  最大单帧跳变         —— 一次跳一大步就是瞬移
  段内最低彩色占比     —— 卡片被「先清空再画」时会掉到 0
  段内近全黑帧数       —— 空白闪屏
"""
import os
import re
import subprocess
import sys
import tempfile

SW = 195
TOP_ROWS = 80
STRIDE = 6
MID = range(int(380 / STRIDE), int(800 / STRIDE))
SIDE = list(range(0, int(320 / STRIDE))) + list(range(int(850 / STRIDE), SW))
BAND_ROWS = range(150 // STRIDE, 216 // STRIDE)
BLACK_LUM = 12.0


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def decode(video, vf, frame_bytes):
    raw = tempfile.NamedTemporaryFile(delete=False, suffix=".raw").name
    try:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-vf", vf,
                        "-fps_mode", "passthrough", "-f", "rawvideo", raw],
                       check=True, stderr=subprocess.DEVNULL)
        with open(raw, "rb") as fh:
            while True:
                buf = fh.read(frame_bytes)
                if len(buf) != frame_bytes:
                    return
                yield buf
    finally:
        os.unlink(raw)


def wallclock(line):
    m = re.search(r"(\d{2}):(\d{2}):(\d{2})\.(\d{3})", line)
    h, mi, s, ms = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(s) + int(ms) / 1000


def main():
    argv = sys.argv
    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    video, log, w, h, x, y = argv[1], argv[2], *map(int, argv[3:7])
    pattern = opt("--grep", "up ")
    scale = int(opt("--scale", 96))
    window = float(opt("--window", 1.2))
    label = opt("--label", os.path.basename(video))

    pts = [float(t.strip().rstrip(",")) for t in
           run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "frame=pts_time", "-of", "csv=p=0", video]).splitlines() if t.strip()]

    hits = []
    for index, buf in enumerate(decode(video, f"crop=1170:{TOP_ROWS * STRIDE}:0:0,"
                                             f"scale={SW}:{TOP_ROWS},format=rgb24", SW * TOP_ROWS * 3)):
        if index >= len(pts):
            break
        rows = 0
        for row in BAND_ROWS:
            base = row * SW * 3
            mid = sum(1 for c in MID
                      if buf[base + c * 3] > 245 and buf[base + c * 3 + 1] > 245 and buf[base + c * 3 + 2] > 245)
            side = sum(1 for c in SIDE
                       if buf[base + c * 3] > 245 and buf[base + c * 3 + 1] > 245 and buf[base + c * 3 + 2] > 245)
            if mid / len(MID) > 0.9 and side / len(SIDE) < 0.2:
                rows += 1
        if rows >= 5:
            hits.append(pts[index])
    marks = []
    for t in hits:
        if marks and t - marks[-1][-1] < 0.15:
            marks[-1].append(t)
        else:
            marks.append([t])
    marks = [g[0] for g in marks]

    logged = open(log, encoding="utf-8", errors="replace").read().splitlines()
    mark_times = [wallclock(l) for l in logged if "打点" in l]
    if len(marks) != len(mark_times):
        print(f"！打点帧 {len(marks)} 个，日志 {len(mark_times)} 条 —— 偏移量不可信")
    pairs = min(len(marks), len(mark_times))
    offsets = sorted(mark_times[i] - marks[i] for i in range(pairs))
    offset = offsets[len(offsets) // 2] if offsets else 0.0
    print(f"== {label} 区域 {w}x{h}+{x}+{y}｜打点 {pairs} 对，离散 {(offsets[-1]-offsets[0])*1000:.0f}ms")

    sw, sh = scale, max(1, round(h * scale / w))
    prev = None
    frames = []
    for index, buf in enumerate(decode(video, f"crop={w}:{h}:{x}:{y},scale={sw}:{sh},format=rgb24",
                                       sw * sh * 3)):
        if index >= len(pts):
            break
        diff = lum = colour = sampled = 0
        for off in range(0, sw * sh * 3, 9):
            r, g, b = buf[off], buf[off + 1], buf[off + 2]
            lum += (r + g + b) // 3
            if max(r, g, b) - min(r, g, b) > 40:
                colour += 1
            sampled += 1
            if prev is not None:
                diff += abs(r - prev[off]) + abs(g - prev[off + 1]) + abs(b - prev[off + 2])
        prev = buf
        frames.append((pts[index], diff / (sampled * 3), lum / sampled, colour / sampled))

    rx = re.compile(pattern)
    press = 0
    for line in logged:
        if "打点" in line or not rx.search(line):
            continue
        t = wallclock(line)
        if t is None:
            continue
        press += 1
        vt = t - offset
        seg = [f for f in frames if vt <= f[0] <= vt + window]
        moving = [f for f in seg if f[1] > 1.0]
        if not moving:
            print(f"   #{press} 松手 {vt:.3f}s → 段内没有运动")
            continue
        peak = max(seg, key=lambda f: f[1])
        col = min(seg, key=lambda f: f[3])
        blacks = sum(1 for f in seg if f[2] < BLACK_LUM)
        print(f"   #{press} 松手 {vt:.3f}s｜首帧动 +{(moving[0][0]-vt)*1000:.0f}ms"
              f"｜到停 {(moving[-1][0]-moving[0][0])*1000:.0f}ms/{len(moving)} 帧"
              f"｜最大跳变 {peak[1]:.2f}｜最低彩色 {col[3]*1000:.0f}‰｜近全黑 {blacks} 帧")


main()
