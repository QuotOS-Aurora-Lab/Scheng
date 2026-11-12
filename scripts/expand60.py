#!/usr/bin/env python3
"""四格关键帧 -> 60 帧序列（单帧派生：位移+缩放，不交叉淡化，避免双角/双爪鬼影）"""
import os, math
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AST = os.path.join(ROOT, "assets")
OUT = os.path.join(ROOT, "build_frames")
CANVAS = 512

def warp(img, sy, dy, dx=0):
    """以底边为锚缩放，再整体上下/左右平移（dx 用来对齐各关键帧的水平重心，防止左右晃）"""
    w, h = img.size
    nw, nh = w, max(1, int(round(h * sy)))
    im = img.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.alpha_composite(im, (int(round(dx)), h - nh + int(round(dy))))
    return out

def expand(folder, names, n=150, canvas=320):
    keys = [Image.open(os.path.join(AST, folder, nm + ".png")).convert("RGBA") for nm in names]
    boxes = [k.getbbox() for k in keys]
    seg = len(keys) - 1
    per = n // seg          # 每段帧数（20）
    frames = []
    for s in range(seg):
        a, ba, bb = keys[s], boxes[s], boxes[s + 1]
        ratio = (bb[3] - bb[1]) / max(1, (ba[3] - ba[1]))
        dtop = bb[1] - ba[1]
        dcx = ((bb[0] + bb[2]) - (ba[0] + ba[2])) / 2.0
        for j in range(per):
            u = j / per
            u2 = u * u * (3 - 2 * u)
            sy = 1 + (ratio - 1) * u2
            sy = max(0.88, min(1.12, sy))          # 限制形变幅度，避免整只被压扁/拉长
            dy = dtop * u2
            dy = max(-36, min(36, dy))
            img = warp(a, sy, dy, dcx * u2)
            frames.append(img)
    frames.append(keys[-1])
    frames = frames[:n] if len(frames) >= n else frames
    while len(frames) < n:
        frames.append(keys[-1])
    d = os.path.join(OUT, folder)
    os.makedirs(d, exist_ok=True)
    for old in os.listdir(d):
        os.remove(os.path.join(d, old))
    paths = []
    for i, img in enumerate(frames):
        p = os.path.join(d, f"{i:03d}.png")
        img.resize((canvas, canvas), Image.LANCZOS).save(p)
        paths.append(p)
    return paths

if __name__ == "__main__":
    # 手排序列：可以重复用某一格做往返，也可以跳过姿态不一致的格
    SEQ = {
        "21_type": [f"type_{i:02d}" for i in range(1, 9)],
        "22_page": ["page_01", "page_02", "page_03", "page_04", "page_05", "page_07", "page_08"],
        "23_note": ["note_03", "note_04", "note_06", "note_04", "note_03"],
        "24_squat": ["squat_01", "squat_02", "squat_03", "squat_04", "squat_05",
                     "squat_04", "squat_03", "squat_02", "squat_01"],
    }
    jobs = [(f, SEQ[f]) for f in ["21_type", "22_page", "23_note", "24_squat"]]
    for folder, names in jobs:
        ps = expand(folder, names)
        print(folder, "frames", len(ps))
