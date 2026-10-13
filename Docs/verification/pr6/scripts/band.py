#!/usr/bin/env python3
"""找「打点」白带的出现时刻 —— 也就是把日志的墙上时钟钉到录屏秒数上。

    band.py <video>

带子是 `padding(.horizontal, 120)` 的一条，只占屏幕中段；
启动那一瞬整个屏幕都是白的、翻月时整页都是暗的，所以判据不能只看「这一行白不白」，
要的是「中间白、两边不白」这一块孤岛。命中的帧按行报出原始像素区间。
"""
import os
import subprocess
import sys
import tempfile

SW = 195          # 缩图宽（原 1170 → 1/6）
TOP_ROWS = 80     # 只看顶部 80 行缩图 = 原视频顶部 480 px
STRIDE = 6
MID = (slice(int(380 / STRIDE), int(800 / STRIDE)),)          # 带子所在列区间
SIDE = (slice(0, int(320 / STRIDE)), slice(int(850 / STRIDE), SW))


def whiteness(buf, row, columns):
    base = row * SW * 3
    hit = total = 0
    for sl in columns:
        for col in range(sl.start, sl.stop):
            off = base + col * 3
            total += 1
            if buf[off] > 245 and buf[off + 1] > 245 and buf[off + 2] > 245:
                hit += 1
    return hit / total


def main():
    video = sys.argv[1]
    times = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "frame=pts_time", "-of", "csv=p=0", video],
        capture_output=True, text=True, check=True).stdout
    pts = [float(t.strip().rstrip(",")) for t in times.splitlines() if t.strip()]

    raw = tempfile.NamedTemporaryFile(delete=False, suffix=".raw").name
    try:
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", video,
             "-vf", f"crop=1170:{TOP_ROWS * STRIDE}:0:0,scale={SW}:{TOP_ROWS},format=rgb24",
             "-fps_mode", "passthrough", "-f", "rawvideo", raw],
            check=True, stderr=subprocess.DEVNULL)
        fb = SW * TOP_ROWS * 3
        n = min(os.path.getsize(raw) // fb, len(pts))
        marks = []
        with open(raw, "rb") as fh:
            for i in range(n):
                buf = fh.read(fb)
                if len(buf) != fb:
                    break
                rows = [row for row in range(TOP_ROWS)
                        if whiteness(buf, row, MID) > 0.9 and whiteness(buf, row, SIDE) < 0.2]
                if rows:
                    marks.append((pts[i], rows[0] * STRIDE, (rows[-1] + 1) * STRIDE))
        print(f"{os.path.basename(video)}：帧 {n}，孤岛白带 {len(marks)} 帧")
        for t, y0, y1 in marks:
            print(f"   t={t:.3f}s  y {y0}..{y1}")
    finally:
        os.unlink(raw)


main()
