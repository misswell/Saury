#!/usr/bin/env python3
"""逐帧追一条竖向亮度剖面的「亮区上边界」，用来量 sheet 边缘的真实走线。

    ./edge.py <video> <t0> <t1> [--x 590] [--thr 120]

和 motion.py 的区别：motion.py 只看「这一帧和上一帧差多少」，这里看
「亮区从第几行开始」，所以能回答两个 motion.py 答不了的问题：
边缘是不是单调到达终点（有没有回弹），以及它到底哪一帧停住。

适用边界：只有当被量的那一层有一条**横贯屏幕的明暗边**（底部弹起的 sheet）时，
「亮区首行」才是那个层的边缘。中部锚定的菜单 / 弹窗不适用 —— 那一列撞到的就是
菜单里的文字行，读出来来回跳。实测反例：EON 的币种菜单 x=590 在 156.635–156.865
之间首行于 281 ↔ 1065~1087 反复跳，163.2–163.5 更是每帧换一次，那是列表在滚。
这种窗口下本脚本的输出没有解释力，别拿去当结论。
"""
import subprocess
import sys

W = 6  # 取的竖条宽度，只用来抗噪
H = None


def probe(video, t0, t1):
    """列出窗口内每一帧的显示时间戳。"""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "frame=pts_time", "-of", "csv=p=0",
         "-read_intervals", f"{t0}%{t1}", video],
        capture_output=True, text=True, check=True).stdout
    ts = [float(l.strip().rstrip(",")) for l in out.splitlines() if l.strip()]
    return sorted(t for t in ts if float(t0) <= t <= float(t1))


def column(video, t0, t1, x):
    """把 x 处一整列灰度抽出来，返回 (字节流, 列高)。"""
    size = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", video],
        capture_output=True, text=True, check=True).stdout.strip()
    _, h = (int(v) for v in size.split("x"))
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", str(t0), "-to", str(t1), "-i", video,
         "-vf", f"crop={W}:{h}:{x}:0,scale=1:{h},format=gray",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
        capture_output=True, check=True).stdout
    return raw, h


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    video, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    x, thr = 590, 120
    args = sys.argv[4:]
    for i, a in enumerate(args):
        if a == "--x":
            x = int(args[i + 1])
        if a == "--thr":
            thr = int(args[i + 1])

    ts = probe(video, t0, t1)
    raw, h = column(video, t0, t1, x)
    n = len(raw) // h
    # -ss 落在两个 PTS 之间时 ffmpeg 会多吐一帧重复帧；宁可对齐尾部也不串时间。
    if n > len(ts):
        raw = raw[(n - len(ts)) * h:]
        n = len(ts)
    if n != len(ts):
        print(f"!! 帧数 {n} 对不上时间戳 {len(ts)}，只按较短的那份出", file=sys.stderr)
        n = min(n, len(ts))

    print(f"== {video.split('/')[-1]} 竖条 x={x} 阈值={thr} 窗口 {t0}–{t1}s"
          f"｜帧 {n}｜平均帧间隔 {1000*(ts[-1]-ts[0])/(n-1):.1f} ms")
    print(f"{'时刻':>9}  {'亮区首行':>8}  {'亮区行数':>8}  {'单帧位移':>8}")
    prev = None
    for i in range(n):
        col = raw[i * h:(i + 1) * h]
        rows = [j for j, v in enumerate(col) if v > thr]
        top = rows[0] if rows else -1
        d = "" if prev is None else f"{top - prev:+d}"
        print(f"{ts[i]:9.3f}  {top:8d}  {len(rows):8d}  {d:>8}")
        prev = top
    return 0


if __name__ == "__main__":
    sys.exit(main())
