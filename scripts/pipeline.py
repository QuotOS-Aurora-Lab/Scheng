#!/usr/bin/env python3
"""獬豸桌宠素材流水线：
1) 去掉纯白底（从边缘 flood fill，保留白色绒毛内部）
2) 裁掉多余留白
3) 统一画布 512x512，底边对齐
4) 派生帧（位移/缩放/镜像）用于补足帧数
"""
import sys, os, json
from collections import deque
from PIL import Image, ImageChops, ImageFilter

CANVAS = 512


def load_rgba(path):
    im = Image.open(path).convert("RGBA")
    return im


def near_white(r, g, b, th=238, spread=14):
    """纯白 + 与背景连通的中性灰阴影都算背景（灰影靠 spread 判定，与白绒毛靠亮度区分）"""
    d = max(r, g, b) - min(r, g, b)
    if r >= th and g >= th and b >= th and d <= 16:
        return True
    if d <= 12 and min(r, g, b) >= 168:      # 中性灰/浅灰投影
        return True
    return False


def flood_remove_bg(im, th=242, spread=14, feather=1):
    """从四边向内 flood fill，只去掉与外界连通的近白区域"""
    w, h = im.size
    px = im.load()
    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if not seen[y * w + x] and near_white(*px[x, y][:3], th=th, spread=spread):
                seen[y * w + x] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if not seen[y * w + x] and near_white(*px[x, y][:3], th=th, spread=spread):
                seen[y * w + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        r, g, b, a = px[x, y]
        px[x, y] = (r, g, b, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                if near_white(*px[nx, ny][:3], th=th, spread=spread):
                    seen[ny * w + nx] = 1
                    q.append((nx, ny))
    return im


def soften_edges(im, radius=1, passes=1):
    """对 alpha 做轻微羽化，消掉白边"""
    a = im.getchannel("A")
    for _ in range(passes):
        a = a.filter(ImageFilter.GaussianBlur(radius))
    im.putalpha(a)
    return im


def trim(im, pad=2):
    bbox = im.getbbox()
    if not bbox:
        return im
    l, t, r, b = bbox
    return im.crop((max(0, l - pad), max(0, t - pad), min(im.size[0], r + pad), min(im.size[1], b + pad)))


def place_on_canvas(im, mode="height", target=400, max_side=488, bottom_pad=6):
    """按指定基准缩放后，水平居中、底部对齐放入 512 画布"""
    w, h = im.size
    if mode == "height":
        s = target / h
        if w * s > max_side:
            s = max_side / w
    elif mode == "width":
        s = target / w
        if h * s > max_side:
            s = max_side / h
    else:  # fit
        s = min(max_side / w, max_side / h)
    nw, nh = max(1, int(w * s)), max(1, int(h * s))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - nw) // 2
    y = CANVAS - nh - bottom_pad
    canvas.paste(im, (x, y), im)
    return canvas




def keep_main_component(im, pad_ratio=0.06, min_area_ratio=0.08):
    """只保留主体（最大连通域）及其附近部件，删掉切片时带进来的邻格残片/阴影块"""
    from collections import deque
    if getattr(im, "readonly", False):
        im = im.copy()          # PIL 某些路径给出只读图像，写像素会 ValueError
    w, h = im.size
    px = im.load()
    lab = [[0] * w for _ in range(h)]
    comps = []
    cid = 0
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 8 and lab[y][x] == 0:
                cid += 1
                q = deque([(x, y)])
                lab[y][x] = cid
                pts = []
                while q:
                    cx_, cy_ = q.popleft()
                    pts.append((cx_, cy_))
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = cx_ + dx, cy_ + dy
                        if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] > 8 and lab[ny][nx] == 0:
                            lab[ny][nx] = cid
                            q.append((nx, ny))
                comps.append(pts)
    if not comps:
        return im
    comps.sort(key=len, reverse=True)
    main = comps[0]
    mx0 = min(p[0] for p in main); mx1 = max(p[0] for p in main)
    my0 = min(p[1] for p in main); my1 = max(p[1] for p in main)
    pad = int(max(mx1 - mx0, my1 - my0) * pad_ratio)
    keep = set()
    total = len(main)
    for pts in comps:
        cx0 = min(p[0] for p in pts); cx1 = max(p[0] for p in pts)
        cy0 = min(p[1] for p in pts); cy1 = max(p[1] for p in pts)
        overlap = not (cx1 < mx0 - pad or cx0 > mx1 + pad or cy1 < my0 - pad or cy0 > my1 + pad)
        if overlap or len(pts) > total * min_area_ratio:
            keep.update(pts)
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 8 and (x, y) not in keep:
                r, g, b, a = px[x, y]
                px[x, y] = (r, g, b, 0)
    return im



def remove_bottom_white_gaps(im, min_area=250, aspect=1.2, bottom_frac=0.08, max_width_ratio=0.4):
    """删掉四肢之间被围住的空白地面（表现成白色膜片）"""
    import numpy as np
    from collections import deque
    a = np.array(im.convert("RGBA")).astype(int)
    h, w = a.shape[:2]
    r, g, b, al = a[:, :, 0], a[:, :, 1], a[:, :, 2], a[:, :, 3]
    mn = np.minimum(np.minimum(r, g), b)
    mx = np.maximum(np.maximum(r, g), b)
    white = (al > 150) & (mn >= 238) & ((mx - mn) <= 14)
    char = al > 150
    if char.sum() == 0:
        return im
    cy0 = np.nonzero(char)[0].min(); cy1 = np.nonzero(char)[0].max()
    cx0 = np.nonzero(char)[1].min(); cx1 = np.nonzero(char)[1].max()
    char_w = cx1 - cx0 + 1
    lab = np.zeros((h, w), bool)
    for y in range(h):
        for x in range(w):
            if white[y, x] and not lab[y, x]:
                q = deque([(x, y)]); lab[y, x] = True; pts = []
                while q:
                    cx, cy = q.popleft(); pts.append((cy, cx))
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < w and 0 <= ny < h and white[ny, nx] and not lab[ny, nx]:
                            lab[ny, nx] = True; q.append((nx, ny))
                arr = np.array(pts); yy = arr[:, 0]; xx = arr[:, 1]
                if len(pts) < min_area:
                    continue
                if yy.min() == 0 or xx.min() == 0 or yy.max() == h - 1 or xx.max() == w - 1:
                    continue
                bw = xx.max() - xx.min() + 1; bh = yy.max() - yy.min() + 1
                if bw / max(1, bh) < aspect:
                    continue
                if bw > char_w * max_width_ratio:
                    continue
                if (cy1 - yy.max()) > bottom_frac * (cy1 - cy0):
                    continue
                a[yy, xx, 3] = 0
    return Image.fromarray(a.astype("uint8"))


def neutralize_gray(im, lo=170, hi=250, spread=12):
    """把残留的中性灰投影压成纯白：灰影会变成看不出的白色，而彩色绒毛不受影响"""
    import numpy as np
    a = np.array(im.convert("RGBA")).astype(int)
    r, g, b, al = a[:, :, 0], a[:, :, 1], a[:, :, 2], a[:, :, 3]
    mn = np.minimum(np.minimum(r, g), b)
    mx = np.maximum(np.maximum(r, g), b)
    mask = (al > 0) & ((mx - mn) <= spread) & (mn >= lo) & (mn <= hi)
    a[:, :, 0][mask] = 255
    a[:, :, 1][mask] = 255
    a[:, :, 2][mask] = 255
    return Image.fromarray(a.astype("uint8"))


def fill_internal_holes(im, thr=40, max_area=6000):
    """把被主体包围的透明小洞填实（否则爪子等处会透出桌面=穿模），颜色沿用洞边像素逐层扩散"""
    import numpy as np
    from collections import deque
    a = np.array(im).astype(np.uint8)
    if a.shape[2] < 4:
        return im
    al = a[:, :, 3]
    mask = al > thr
    h, w = mask.shape
    if mask.sum() == 0:
        return im
    ext = np.zeros((h, w), bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if not mask[y, x] and not ext[y, x]:
                ext[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if not mask[y, x] and not ext[y, x]:
                ext[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not mask[ny, nx] and not ext[ny, nx]:
                ext[ny, nx] = True
                dq.append((ny, nx))
    holes = (~mask) & (~ext)
    if not holes.any():
        return im
    lab = np.zeros((h, w), np.int32)
    keep = np.zeros_like(holes)
    cur = 0
    for y in range(h):
        for x in range(w):
            if holes[y, x] and lab[y, x] == 0:
                cur += 1
                lab[y, x] = cur
                q = deque([(y, x)])
                px = [(y, x)]
                while q:
                    cy, cx = q.popleft()
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and holes[ny, nx] and lab[ny, nx] == 0:
                            lab[ny, nx] = cur
                            q.append((ny, nx))
                            px.append((ny, nx))
                if len(px) <= max_area:
                    for py, pxx in px:
                        keep[py, pxx] = True
    if not keep.any():
        return im
    # 取洞边缘"白毛亮色"的中位色做填充，避免把爪垫填成紫灰糊块
    edge_rgb = []
    ys, xs = np.where(keep)
    for y, x in zip(ys, xs):
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx]:
                c = a[ny, nx, :3].astype(np.float32)
                edge_rgb.append((0.3 * c[0] + 0.6 * c[1] + 0.1 * c[2], c))
    if edge_rgb:
        edge_rgb.sort(key=lambda t: -t[0])
        top = [c for _, c in edge_rgb[:max(1, len(edge_rgb) * 55 // 100)]]
        base = np.median(np.stack(top), axis=0)
    else:
        base = np.array([250.0, 248.0, 252.0], np.float32)
    rgb = a[:, :, :3].astype(np.float32)
    rgb[keep] = base
    a[:, :, 3][keep] = 255
    # 洞内做一次轻度模糊，避免边界出现生硬色块
    if keep.sum() > 40:
        tmp = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
        blur = np.array(tmp.filter(ImageFilter.GaussianBlur(1.6)).filter(ImageFilter.GaussianBlur(1.6))).astype(np.float32)
        rgb[keep] = (rgb[keep] * 0.35 + blur[keep] * 0.65)
    a[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    return Image.fromarray(a)


def process(src, dst, mode="height", target=400, th=238, spread=14):
    im = flood_remove_bg(load_rgba(src), th=th, spread=spread)
    im = keep_main_component(im)
    im = trim(im)
    out = remove_bottom_white_gaps(neutralize_gray(place_on_canvas(im, mode=mode, target=target)))
    out = fill_internal_holes(out)
    out.save(dst)
    return out


def process_group(srcs, dsts, target_h=376, canvas=CANVAS, bottom=8):
    """同源多帧：统一缩放比例、统一底边基线，只做整体缩放不做逐帧归一"""
    cleaned = []
    for src in srcs:
        im = flood_remove_bg(load_rgba(src))
        im = keep_main_component(im)
        cleaned.append(trim(im))
    hs = [im.size[1] for im in cleaned]
    s = target_h / max(hs)
    W = int(max(im.size[0] for im in cleaned) * s)
    for im, dst in zip(cleaned, dsts):
        r = im.resize((max(1, int(im.size[0] * s)), max(1, int(im.size[1] * s))), Image.LANCZOS)
        out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        x = (canvas - r.size[0]) // 2
        y = canvas - bottom - r.size[1]
        out.alpha_composite(r, (x, y))
        out = remove_bottom_white_gaps(neutralize_gray(out))
        out.save(dst)
    return W



def chroma_key_green(im):
    """绿幕抠像：以「绿通道相对红蓝的优势」判定背景，白色绒毛差值≈0 不受影响"""
    import numpy as np
    a = np.array(im.convert("RGBA")).astype(float)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    ref = np.maximum(r, b)
    dom = g - ref                                   # 绿色优势（纯绿≈255，白≈0）
    alpha = 1.0 - np.clip((dom - 6) / 34.0, 0, 1)   # dom<=6 全保留，dom>=40 全透明
    a[:, :, 3] = np.minimum(a[:, :, 3], alpha * 255)
    # despill：压掉边缘绿色反光
    spill = dom > 4
    a[:, :, 1] = np.where(spill, ref * 1.0 + np.minimum(dom, 10) * 0.2, g)
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def eye_distance(im):
    import numpy as np
    a = np.array(im.convert("RGBA")).astype(int)
    r, g, b, al = a[:, :, 0], a[:, :, 1], a[:, :, 2], a[:, :, 3]
    m = (al > 200) & (r > 170) & (g < 165) & (b < 140) & ((r - g) > 55)
    ys, xs = np.nonzero(m)
    if len(xs) == 0:
        return None
    mid = (xs.min() + xs.max()) / 2
    l = xs < mid
    return abs(xs[l].mean() - xs[~l].mean())


def process_group_green(srcs, dsts, target_h=372, canvas=CANVAS, bottom=8,
                        eye_target=None, max_h=None, head_target=None, head_ref_idx=None):
    """绿幕四格：同源同比例缩放，统一底边基线；可选按瞳距（头部尺寸）归一"""
    cleaned = []
    for src in srcs:
        im = chroma_key_green(load_rgba(src))
        im = keep_main_component(im)
        cleaned.append(trim(im))
    if head_target:
        def headw(im):
            bb = im.getbbox()
            h = bb[3] - bb[1]
            top = bb[1]
            cols = []
            for x in range(im.size[0]):
                for y in range(top, top + max(1, int(h * 0.3))):
                    if im.getpixel((x, y))[3] > 40:
                        cols.append(x)
                        break
            return (max(cols) - min(cols) + 1) if cols else None
        if head_ref_idx is not None:
            hw = headw(cleaned[head_ref_idx]) or 320
            s = head_target / hw
        else:
            ws = [w for w in (headw(im) for im in cleaned) if w]
            s = head_target / (sum(ws) / len(ws))
        if max_h:
            s = min(s, max_h / max(im.size[1] for im in cleaned))
    elif eye_target:
        ds = [d for d in (eye_distance(im) for im in cleaned) if d]
        s = eye_target / (sum(ds) / len(ds))
        if max_h:
            s = min(s, max_h / max(im.size[1] for im in cleaned))
    else:
        s = target_h / max(im.size[1] for im in cleaned)
    for im, dst in zip(cleaned, dsts):
        r = im.resize((max(1, int(im.size[0] * s)), max(1, int(im.size[1] * s))), Image.LANCZOS)
        out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        out.alpha_composite(r, ((canvas - r.size[0]) // 2, canvas - bottom - r.size[1]))
        out = fill_internal_holes(neutralize_gray(out))
        out.save(dst)


def derive(src, dst, dx=0, dy=0, sx=1.0, sy=1.0, rot=0.0, mirror=False, bottom_pad=8):
    """派生帧：以「底部中心」为锚点做位移/缩放/旋转，保证脚底线不跑、不出画布"""
    im = load_rgba(src)
    if mirror:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if rot:
        im = im.rotate(rot, resample=Image.BICUBIC, expand=True)
    if sx != 1.0 or sy != 1.0:
        im = im.resize((max(1, int(im.size[0] * sx)), max(1, int(im.size[1] * sy))), Image.LANCZOS)
    bb = im.getbbox() or (0, 0, im.size[0], im.size[1])
    im = im.crop(bb)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - im.size[0]) // 2 + dx
    y = CANVAS - bottom_pad - im.size[1] + dy
    canvas.alpha_composite(im, (x, y))
    canvas = fill_internal_holes(canvas)
    canvas.save(dst)
    return canvas


if __name__ == "__main__":
    from PIL import ImageFilter
    process("assets/01_idle/idle_01_raw.png", "assets/01_idle/idle_01.png")
    print("ok")
