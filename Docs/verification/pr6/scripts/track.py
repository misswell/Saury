#!/usr/bin/env python3
"""轮播卡片每一帧到底走了多远：用列亮度剖面在相邻帧之间找最佳水平位移。

    track.py <video> <x> <y> <w> <h> [--max 40] [--label S]

为什么不用「相邻帧平均绝对差」：甩得快的连续过渡和一步跳到位的瞬移，
在差值幅度上可以长得很像；能分开它们的是**单帧位移**。
这里把卡片那条横带按列取平均亮度，得到一条剖面，再去试 −max…+max 列的平移，
取让两帧最贴合的那个偏移量，换算回原始像素就是这一帧卡片走了多远。

剖面法只看整体形状，卡片换色、阴影变化都不会被当成位移。
"""
import os
import subprocess
import sys
import tempfile

SW = 234          # 缩图宽（原 1170 → 1/5），一列 = 5px


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def main():
    argv = sys.argv
    def opt(name, default):
        return argv[argv.index(name) + 1] if name in argv else default
    video, x, y, w, h = argv[1], *map(int, argv[2:6])
    mx = int(opt("--max", 40))
    lo = float(opt("--from", 0.0))
    hi = float(opt("--to", 1e9))
    label = opt("--label", "")

    pts = [float(t.strip().rstrip(",")) for t in
           run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "frame=pts_time", "-of", "csv=p=0", video]).splitlines() if t.strip()]
    sh = max(2, round(h * SW / w))
    raw = tempfile.NamedTemporaryFile(delete=False, suffix=".raw").name
    try:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video,
                        "-vf", f"crop={w}:{h}:{x}:{y},scale={SW}:{sh},format=gray",
                        "-fps_mode", "passthrough", "-f", "rawvideo", raw],
                       check=True, stderr=subprocess.DEVNULL)
        size = SW * sh
        profiles = []
        with open(raw, "rb") as fh:
            for index in range(min(len(pts), os.path.getsize(raw) // size)):
                buf = fh.read(size)
                col = [sum(buf[row * SW + c] for row in range(sh)) // sh for c in range(SW)]
                mean = sum(col) / len(col)
                profiles.append((pts[index], [v - mean for v in col]))

        def cost(a, b, s):
            total = n = 0
            for c in range(max(0, s), min(SW, SW + s)):
                total += abs(a[c] - b[c - s])
                n += 1
            return total / max(1, n)

        rows = []
        for i in range(1, len(profiles)):
            t, a = profiles[i - 1]
            _, b = profiles[i]
            best, score = 0, None
            for s in range(-mx, mx + 1):
                c = cost(a, b, s)
                if score is None or c < score:
                    best, score = s, c
            if lo <= t <= hi:
                rows.append((t, best * w / SW, score))

        jumps = sorted(rows, key=lambda r: -abs(r[1]))[:6]
        still = sum(1 for r in rows if abs(r[1]) < 2)
        print(f"== {label}{os.path.basename(video)} 剖面 {w}x{h}+{x}+{y}｜帧 {len(rows)}"
              f"｜静止 {still}｜最大单帧位移（px）：" +
              "  ".join(f"{t:.3f}s {d:+.0f}" for t, d, _ in jumps))
        big = [abs(d) for _, d, _ in rows if abs(d) > 0.25 * w]
        print(f"   超过 1/4 页宽（{0.25 * w:.0f}px）的瞬移帧：{len(big)} 次"
              + (f"，最大 {max(abs(d) for _, d, _ in rows):.0f}px" if big else ""))
    finally:
        os.unlink(raw)


main()
