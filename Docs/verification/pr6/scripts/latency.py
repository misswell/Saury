#!/usr/bin/env python3
"""§12.2「操作到首帧反馈时间」：把探针日志的时刻和录屏逐帧对到一起。

    latency.py <video> <log> <w> <h> <x> <y> --grep <样式> [--scale N] [--label S]

对齐不靠猜：`ProbeMarker` 在打点那一帧把屏幕中段刷成一条白带，
日志里同一句「打点 …」写下的就是同一刻。两边按出现顺序一一对上，
取中位数当偏移量，误差就是录屏的一帧（这里约 27ms）。

之后每条被 `--grep` 选中的日志行都换算成录屏时刻，
往后找被量区域里第一帧真正动了的（相邻帧平均绝对差过阈值），
差值就是「按下 → 屏幕上出现反馈」用了多久。
"""
import os
import re
import subprocess
import sys
import tempfile

SW = 195
TOP_ROWS = 80
STRIDE = 6
MID = (range(int(380 / STRIDE), int(800 / STRIDE)),)
SIDE = (range(0, int(320 / STRIDE)), range(int(850 / STRIDE), SW))
# ProbeMarkerBand：padding(.top, 52) + 高 18 pt，3x 屏 → 原视频 y 156..210。
# 只认落在这条带子里、且连续 5 行（30px）以上的孤岛；启动白屏和卡片亮边都进不来。
BAND_ROWS = range(150 // STRIDE, 216 // STRIDE)
MOTION_MAD = 1.0


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
    if not m:
        return None
    h, mi, s, ms = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(s) + int(ms) / 1000


def main():
    argv = sys.argv
    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    video, log, w, h, x, y = argv[1], argv[2], *map(int, argv[3:7])
    pattern = opt("--grep", "")
    scale = int(opt("--scale", 96))
    label = opt("--label", os.path.basename(video))

    pts = [float(t.strip().rstrip(",")) for t in
           run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "frame=pts_time", "-of", "csv=p=0", video]).splitlines() if t.strip()]

    # 1) 白带帧：屏幕中段整块白、两边不白，且至少连成 30px 高的一条
    hits = []
    for index, buf in enumerate(decode(video, f"crop=1170:{TOP_ROWS * STRIDE}:0:0,"
                                             f"scale={SW}:{TOP_ROWS},format=rgb24", SW * TOP_ROWS * 3)):
        rows = []
        for row in BAND_ROWS:
            base = row * SW * 3
            mid = sum(1 for c in MID[0]
                      if buf[base + c * 3] > 245 and buf[base + c * 3 + 1] > 245 and buf[base + c * 3 + 2] > 245)
            side = total = 0
            for rng in SIDE:
                for c in rng:
                    total += 1
                    if buf[base + c * 3] > 245 and buf[base + c * 3 + 1] > 245 and buf[base + c * 3 + 2] > 245:
                        side += 1
            if mid / len(MID[0]) > 0.9 and side / total < 0.2:
                rows.append(row)
        if len(rows) >= 5 and index < len(pts):
            hits.append(pts[index])

    # 一次打点会被录成 2–3 帧，按间隔并成一次；取首帧，那最接近日志写下的时刻。
    marks = []
    for t in hits:
        if marks and t - marks[-1][-1] < 0.15:
            marks[-1].append(t)
        else:
            marks.append([t])
    marks = [group[0] for group in marks]

    logged = open(log, encoding="utf-8", errors="replace").read().splitlines()
    mark_times = [wallclock(l) for l in logged if "打点" in l]
    mark_times = [t for t in mark_times if t is not None]
    if len(marks) != len(mark_times):
        print(f"！打点帧 {len(marks)} 个，日志 {len(mark_times)} 条，对不上，偏移量不可信")
    pairs = min(len(marks), len(mark_times))
    offsets = sorted(mark_times[i] - marks[i] for i in range(pairs))
    offset = offsets[len(offsets) // 2] if offsets else 0.0
    spread = (offsets[-1] - offsets[0]) if offsets else 0.0
    mean_gap = (pts[-1] - pts[0]) / max(1, len(pts) - 1) * 1000
    print(f"== {label} 区域 {w}x{h}+{x}+{y}｜打点 {pairs} 对，"
          f"偏移 {offset:.3f}s（离散 {spread * 1000:.0f}ms，平均帧间隔 {mean_gap:.0f}ms）")

    # 2) 逐帧运动量
    sw = scale
    sh = max(1, round(h * scale / w))
    events = []
    prev = None
    offsets_px = range(0, sw * sh * 3, 9)
    for index, buf in enumerate(decode(video, f"crop={w}:{h}:{x}:{y},scale={sw}:{sh},format=rgb24",
                                       sw * sh * 3)):
        if index >= len(pts):
            break
        t = pts[index]
        diff = 0
        if prev is not None:
            for off in offsets_px:
                diff += abs(buf[off] - prev[off]) + abs(buf[off + 1] - prev[off + 1]) + abs(buf[off + 2] - prev[off + 2])
            diff /= len(offsets_px) * 3
        prev = buf
        if diff > MOTION_MAD:
            events.append((t, diff))
    moving = [t for t, _ in events]

    # 3) 每条操作 → 第一帧动
    #    连着按的时候，前一段动画还没停，「第一帧动」会算到上一段头上。
    #    所以要求按下前 quiet 毫秒内屏幕是静止的，这条操作才量得出真实响应。
    quiet = float(opt("--quiet", 120)) / 1000
    rx = re.compile(pattern) if pattern else None
    rows = []
    for line in logged:
        if "打点" in line:
            continue
        t = wallclock(line)
        if t is None:
            continue
        if rx and not rx.search(line):
            continue
        vt = t - offset
        if any(vt - quiet <= m < vt for m in moving):
            rows.append((vt, "连续操作（上一段还没落定）", line))
            continue
        first = next((m for m in moving if m >= vt - 0.03), None)
        if first is None:
            rows.append((vt, "找不到后续运动", line))
        else:
            rows.append((vt, f"{(first - vt) * 1000:+.0f}ms（首帧动 {first:.3f}s）", line))
    for vt, verdict, line in rows:
        text = line.split("] ", 1)[-1] if "] " in line else line
        print(f"   {vt:7.3f}s → {verdict:38}｜{text[:96]}")
    lat = sorted(abs(float(v.split("ms")[0])) for _, v, _ in rows if "ms（" in v)
    skipped = sum(1 for _, v, _ in rows if "连续操作" in v)
    if lat:
        print(f"   静止后按下 {len(lat)} 次，中位 {lat[len(lat) // 2]:.0f}ms，"
              f"最小 {lat[0]:.0f}ms，最大 {lat[-1]:.0f}ms；另有 {skipped} 次落在上一段动画里")


main()
