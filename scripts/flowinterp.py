#!/usr/bin/env python3
"""关键帧 -> 60 帧：双向光流中割（替代缩放/位移插值），帧间动作是真的在变形而不是滑移"""
import os, sys, numpy as np, cv2
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AST = os.path.join(ROOT, "assets")
OUT = os.path.join(ROOT, "build_frames")
N_OUT = 60


def load(p):
    im = Image.open(p).convert("RGBA")
    return im, np.array(im)


def to_gray(a):
    rgb = a[..., :3].astype(np.float32)
    g = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    return g.astype(np.uint8)


def optical_flow(a, b):
    ga, gb = to_gray(a), to_gray(b)
    fwd = cv2.calcOpticalFlowFarneback(ga, gb, None, 0.5, 3, 31, 6, 9, 1.5, 0)
    bwd = cv2.calcOpticalFlowFarneback(gb, ga, None, 0.5, 3, 31, 6, 9, 1.5, 0)
    # 毛发/描边这类高频细节会让光流撕裂，先强平滑位移场，只保留大块形变
    k = 21
    fwd = cv2.GaussianBlur(fwd, (k, k), 0)
    bwd = cv2.GaussianBlur(bwd, (k, k), 0)
    return fwd, bwd


def warp(img, flow, t):
    h, w = img.shape[:2]
    xs, ys = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    mapx = xs + t * flow[..., 0]
    mapy = ys + t * flow[..., 1]
    return cv2.remap(img, mapx, mapy, cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_REPLICATE)


def premul(a):
    f = a.astype(np.float32)
    f[..., :3] *= (f[..., 3:4] / 255.0)
    return f


def interp(a, b, u, flows=None):
    fwd, bwd = flows if flows else optical_flow(a, b)
    pa, pb = premul(a), premul(b)
    wa = warp(pa, fwd, u)
    wb = warp(pb, bwd, 1.0 - u)
    out = wa * (1.0 - u) + wb * u          # 预乘后直接加权，边缘不会出黑边
    al = out[..., 3:4] / 255.0
    rgb = out[..., :3] / np.maximum(al, 1e-4)
    return np.dstack([np.clip(rgb, 0, 255), np.clip(out[..., 3:4], 0, 255)]).astype(np.uint8)


def build(folder, names, canvas=320):
    keys = [load(os.path.join(AST, folder, n + ".png"))[1] for n in names]
    seg = len(keys) - 1
    # 预计算每段光流
    flows = [optical_flow(keys[i], keys[i + 1]) for i in range(seg)]
    frames = []
    for i in range(N_OUT):
        t = i / (N_OUT - 1) * seg
        k = min(seg - 1, int(t))
        u = t - k
        ease = u * u * (3 - 2 * u)
        arr = interp(keys[k], keys[k + 1], ease, flows[k])
        img = Image.fromarray(arr, "RGBA")
        # 统一到底边锚定再缩到 320（保持几何一致）
        bb = img.getbbox()
        if bb:
            img = img.resize((canvas, canvas), Image.LANCZOS)
        frames.append(img)
    d = os.path.join(OUT, folder)
    os.makedirs(d, exist_ok=True)
    for old in os.listdir(d):
        os.remove(os.path.join(d, old))
    for i, img in enumerate(frames):
        img.save(os.path.join(d, f"{i:03d}.png"))
    return len(frames)


if __name__ == "__main__":
    SEQ = {
        "21_type": [f"type_{i:02d}" for i in range(1, 9)],
        "22_page": ["page_01", "page_02", "page_03", "page_04", "page_05", "page_07", "page_08"],
        "23_note": ["note_03", "note_04", "note_06", "note_04", "note_03"],
        "24_squat": ["squat_01", "squat_02", "squat_03", "squat_04", "squat_05",
                     "squat_04", "squat_03", "squat_02", "squat_01"],
    }
    for folder, names in SEQ.items():
        print(folder, build(folder, names), "frames")
