#!/usr/bin/env python3
"""素材构建：绿幕同源多格 -> 切片 -> 归一 -> 派生 -> 中割插帧 -> sequence.json"""
import os, sys, json
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline as P

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "raw")
AST = os.path.join(ROOT, "assets")

# (raw, folder, out, mode, target)  —— 白底单图走这条
JOBS = [
    ("idle_01",      "01_idle",  "idle_01", "height", 400),
    ("idle_up",      "01_idle",  "idle_02", "height", 400),
    ("idle_down",    "01_idle",  "idle_03", "height", 400),
    ("blink_half",   "01_blink", "blink_01", "height", 400),
    ("idle_02",      "01_blink", "blink_02", "height", 400),
    ("pat_laugh",    "05_pat",   "pat_01", "height", 400),
    ("pat_01",       "05_pat",   "pat_02", "height", 400),
    ("pat_other",    "05_pat",   "pat_03", "height", 400),
    ("daze_01",      "06_daze",  "daze_01", "height", 400),
    ("idle_01",      "07_yawn",  "yawn_01", "height", 400),
    ("yawn_half",    "07_yawn",  "yawn_02", "height", 400),
    ("yawn_max",     "07_yawn",  "yawn_03", "height", 412),
    ("yawn_close",   "07_yawn",  "yawn_04", "height", 400),
    ("tail_01",      "08_tail",  "tail_01", "height", 390),
    ("tail_rev",     "08_tail",  "tail_02", "height", 390),
    ("tablet_01",    "09_tablet", "tablet_01", "width", 470),
    ("tablet_up",    "09_tablet", "tablet_02", "width", 470),
    ("study_01",     "10_study", "study_01", "height", 400),
    ("study_page",   "10_study", "study_02", "height", 400),
    ("study_up",     "10_study", "study_03", "height", 400),
    ("play_lie",     "11_play",  "play_01", "width", 450),
    ("play_roll",    "11_play",  "play_02", "width", 440),
    ("play_side",    "11_play",  "play_03", "width", 452),
    ("look_left",    "12_look",  "look_left", "height", 400),
    ("look_right",   "12_look",  "look_right", "height", 400),
]


def slice_sheet(name, prefix, n=4):
    """按绿色空白列把横向序列图切成 n 格"""
    import numpy as np
    sheet = Image.open(os.path.join(RAW, name)).convert("RGB")
    w, h = sheet.size
    a = np.asarray(sheet).astype(int)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    ink = ((g - np.maximum(r, b)) < 12).sum(axis=0)
    empty = ink == 0
    gaps, start = [], None
    for x in range(w):
        if empty[x] and start is None:
            start = x
        elif not empty[x] and start is not None:
            if x - start > 12:
                gaps.append((start, x))
            start = None
    if start is not None and w - start > 12:
        gaps.append((start, w))
    cuts = []
    for k in range(1, n):
        target = k * w / n
        gseg = min(gaps, key=lambda gg: abs((gg[0] + gg[1]) / 2 - target))
        cuts.append(int((gseg[0] + gseg[1]) / 2))
    bounds = [0] + cuts + [w]
    for i in range(n):
        sheet.crop((bounds[i], 0, bounds[i + 1], h)).save(os.path.join(RAW, f"{prefix}_q{i+1}.png"))
    print(prefix, "sliced at", cuts)


def build_sheet(sheet_name, prefix, folder, names, head_target=320, max_h=496, head_ref_idx=0, n=4):
    slice_sheet(sheet_name, prefix, n)
    P.process_group_green([os.path.join(RAW, f"{prefix}_q{i}.png") for i in range(1, n + 1)],
                          [os.path.join(AST, folder, f"{nm}.png") for nm in names],
                          head_target=head_target, max_h=max_h, head_ref_idx=head_ref_idx)


def top_of(path):
    im = Image.open(path)
    bb = im.getbbox()
    return bb[1] if bb else 0


def interleave(folder, names):
    """在相邻关键帧之间插一帧中割：微位移 + 轻微压缩"""
    out = [names[0]]
    for i in range(len(names) - 1):
        cur = os.path.join(AST, folder, names[i] + ".png")
        nxt = os.path.join(AST, folder, names[i + 1] + ".png")
        mid = f"{names[i]}_m"
        dy = int((top_of(nxt) - top_of(cur)) * 0.45)
        if dy == 0:
            dy = -2
        P.derive(cur, os.path.join(AST, folder, mid + ".png"), dy=dy, sy=0.985)
        out += [mid, names[i + 1]]
    return out


def main():
    for folder in os.listdir(AST):
        d = os.path.join(AST, folder)
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".png"):
                    os.remove(os.path.join(d, f))
    for folder in ["18_gavel", "19_groom", "20_fish"]:
        os.makedirs(os.path.join(AST, folder), exist_ok=True)

    for raw, folder, out, mode, target in JOBS:
        src = os.path.join(RAW, raw + ".jpg")
        if not os.path.exists(src):
            src = os.path.join(RAW, raw + ".png")
        P.process(src, os.path.join(AST, folder, out + ".png"), mode=mode, target=target)

    # ---- 绿幕同源多格（同机位、同比例、底边对齐）----
    slice_sheet("walk_sheet3.png", "walk")
    P.process_group_green([os.path.join(RAW, f"walk_q{i}.png") for i in (1, 2, 3, 4)],
                          [os.path.join(AST, "04_walk", f"walk_0{i}.png") for i in (1, 2, 3, 4)],
                          head_target=320, max_h=500)

    slice_sheet("lift_sheet2.png", "lift")
    P.process_group_green([os.path.join(RAW, f"lift_q{i}.png") for i in (1, 2, 3, 4)],
                          [os.path.join(AST, "02_lift", f"lift_0{i}.png") for i in (1, 2, 3, 4)],
                          eye_target=112, max_h=496)

    build_sheet("land_sheet3.png", "land", "03_land",
                ["land_01", "land_02", "land_03", "land_04"], head_ref_idx=3)
    build_sheet("hide_sheet2.png", "hide", "13_hide",
                ["hide_01", "hide_02", "hide_03", "hide_04"])
    build_sheet("stretch_sheet2.png", "stretch", "14_stretch",
                ["stretch_01", "stretch_02", "stretch_03", "stretch_04"])
    build_sheet("sleep_sheet.png", "sleep", "15_sleep",
                ["sleep_01", "sleep_02", "sleep_03", "sleep_04"])
    build_sheet("wave_sheet.png", "wave", "16_wave",
                ["wave_01", "wave_02", "wave_03", "wave_04"])
    build_sheet("pounce_sheet.png", "pounce", "17_pounce",
                ["pounce_01", "pounce_02", "pounce_03", "pounce_04"])
    build_sheet("gavel_sheet.png", "gavel", "18_gavel",
                ["gavel_01", "gavel_02", "gavel_03", "gavel_04"])
    build_sheet("groom_sheet.png", "groom", "19_groom",
                ["groom_01", "groom_02", "groom_03", "groom_04"])
    build_sheet("fish_sheet.png", "fish", "20_fish",
                ["fish_01", "fish_02", "fish_03", "fish_04"])

    A = lambda folder, f: os.path.join(AST, folder, f)
    D = lambda src, dst, **kw: P.derive(A(*src), A(*dst), **kw)

    # ---- 派生帧（收尾/过渡）----
    D(("01_idle", "idle_01.png"), ("01_idle", "idle_04.png"), dy=4)
    D(("01_idle", "idle_03.png"), ("01_idle", "idle_05.png"), dy=2)
    D(("01_blink", "blink_02.png"), ("01_blink", "blink_03.png"), dy=2)
    D(("02_lift", "lift_02.png"), ("02_lift", "lift_05.png"), dy=-6)
    D(("03_land", "land_04.png"), ("03_land", "land_05.png"), dy=2)
    D(("04_walk", "walk_02.png"), ("04_walk", "walk_05.png"), dy=-7)
    D(("04_walk", "walk_04.png"), ("04_walk", "walk_06.png"), dy=-7)
    D(("04_walk", "walk_01.png"), ("04_walk", "walk_07.png"), dy=-2)
    D(("05_pat", "pat_02.png"), ("05_pat", "pat_04.png"), dy=-4)
    D(("05_pat", "pat_03.png"), ("05_pat", "pat_05.png"), rot=2)
    D(("05_pat", "pat_03.png"), ("05_pat", "pat_06.png"), dy=-3, rot=2)
    D(("06_daze", "daze_01.png"), ("06_daze", "daze_02.png"), rot=2.5, dy=3)
    D(("06_daze", "daze_01.png"), ("06_daze", "daze_03.png"), rot=-2)
    D(("06_daze", "daze_02.png"), ("06_daze", "daze_04.png"), dy=3)
    D(("07_yawn", "yawn_04.png"), ("07_yawn", "yawn_05.png"), dy=-3)
    D(("07_yawn", "yawn_04.png"), ("07_yawn", "yawn_06.png"), dy=2, rot=-1)
    D(("08_tail", "tail_01.png"), ("08_tail", "tail_03.png"), mirror=True)
    D(("08_tail", "tail_02.png"), ("08_tail", "tail_04.png"), mirror=True)
    D(("09_tablet", "tablet_02.png"), ("09_tablet", "tablet_03.png"), dy=-4)
    D(("10_study", "study_01.png"), ("10_study", "study_04.png"), dy=-4)
    D(("10_study", "study_03.png"), ("10_study", "study_05.png"), dy=-3)
    D(("11_play", "play_02.png"), ("11_play", "play_04.png"), rot=-7, dx=6, dy=-2)
    D(("11_play", "play_01.png"), ("11_play", "play_05.png"), rot=5, dy=-4)
    D(("11_play", "play_02.png"), ("11_play", "play_06.png"), rot=8, dy=-3)
    Image.open(A("01_idle", "idle_01.png")).save(A("12_look", "look_mid.png"))
    D(("13_hide", "hide_03.png"), ("13_hide", "hide_05.png"), dy=-4)
    D(("13_hide", "hide_02.png"), ("13_hide", "hide_06.png"), dy=2)
    D(("14_stretch", "stretch_03.png"), ("14_stretch", "stretch_05.png"), dy=-4, rot=1)
    D(("15_sleep", "sleep_04.png"), ("15_sleep", "sleep_05.png"), dy=2)
    D(("16_wave", "wave_02.png"), ("16_wave", "wave_05.png"), dx=6, rot=2)
    D(("17_pounce", "pounce_04.png"), ("17_pounce", "pounce_05.png"), dy=-3)
    D(("18_gavel", "gavel_03.png"), ("18_gavel", "gavel_05.png"), dy=2)
    D(("19_groom", "groom_03.png"), ("19_groom", "groom_05.png"), dy=2)
    D(("20_fish", "fish_04.png"), ("20_fish", "fish_05.png"), dy=2)

    # ---- 关键帧 -> 中割插帧 ----
    KEYS = {
        "idle":     ("01_idle",  ["idle_01", "idle_02", "idle_03", "idle_04", "idle_05"]),
        "blink":    ("01_blink", ["blink_01", "blink_02", "blink_03"]),
        "lift":     ("02_lift",  ["lift_01", "lift_02", "lift_03", "lift_04", "lift_05"]),
        "land":     ("03_land",  ["land_01", "land_02", "land_03", "land_04", "land_05"]),
        "walk":     ("04_walk",  ["walk_01", "walk_02", "walk_03", "walk_04", "walk_05", "walk_06", "walk_07"]),
        "pat":      ("05_pat",   ["pat_01", "pat_02", "pat_03", "pat_04", "pat_05", "pat_06"]),
        "daze":     ("06_daze",  ["daze_01", "daze_02", "daze_03", "daze_04"]),
        "yawn":     ("07_yawn",  ["yawn_01", "yawn_02", "yawn_03", "yawn_04", "yawn_05", "yawn_06"]),
        "tail":     ("08_tail",  ["tail_01", "tail_02", "tail_03", "tail_04"]),
        "tablet":   ("09_tablet", ["tablet_01", "tablet_02", "tablet_03"]),
        "study":    ("10_study", ["study_01", "study_02", "study_03", "study_04", "study_05"]),
        "play":     ("11_play",  ["play_01", "play_02", "play_03", "play_04", "play_05", "play_06"]),
        # 躲藏：从探出逐帧缩回毛球（末帧=球，藏好）
        "hide":     ("13_hide",  ["hide_04", "hide_03", "hide_05", "hide_02", "hide_06", "hide_01"]),
        "stretch":  ("14_stretch", ["stretch_01", "stretch_02", "stretch_03", "stretch_04", "stretch_05"]),
        "sleep":    ("15_sleep", ["sleep_01", "sleep_02", "sleep_03", "sleep_04", "sleep_05"]),
        "wave":     ("16_wave",  ["wave_01", "wave_02", "wave_03", "wave_04", "wave_05"]),
        "pounce":   ("17_pounce", ["pounce_01", "pounce_02", "pounce_03", "pounce_04", "pounce_05"]),
        "gavel":    ("18_gavel", ["gavel_01", "gavel_02", "gavel_03", "gavel_04", "gavel_05"]),
        "groom":    ("19_groom", ["groom_01", "groom_02", "groom_03", "groom_04", "groom_05"]),
        "fish":     ("20_fish",  ["fish_01", "fish_02", "fish_03", "fish_04", "fish_05"]),
    }
    ORDER = {state: interleave(folder, keys) for state, (folder, keys) in KEYS.items()}

    BASE = {
        "idle": (3.2, True, 0), "blink": (5.0, False, 0), "lift": (8.0, True, 0),
        "land": (14.0, False, 0), "walk": (10.0, True, 0), "pat": (10.0, False, 0.3),
        "daze": (2.0, True, 3.2), "yawn": (7.0, False, 0), "tail": (10.0, False, 0),
        "tablet": (3.0, True, 3.6), "study": (1.5, True, 0), "play": (9.0, False, 0),
        "hide": (6.0, False, 0), "stretch": (6.0, False, 0.4), "sleep": (1.2, True, 14.0),
        "wave": (9.0, False, 0.4), "pounce": (10.0, False, 0.2),
        "gavel": (9.0, False, 0.3), "groom": (7.0, False, 0.2), "fish": (8.0, False, 0.3),
    }
    states = {}
    for state, files in ORDER.items():
        fps0, loop, hold = BASE[state]
        fps = round(fps0 * len(files) / len(KEYS[state][1]), 2)
        states[state] = {"folder": KEYS[state][0], "files": [f + ".png" for f in files],
                         "fps": fps, "loop": loop, "hold": hold}

    seq = {"states": states,
           "hideWait": "hide_02.png", "hideFolder": "13_hide",
           "look": {"left": "12_look/look_left.png", "mid": "12_look/look_mid.png",
                    "right": "12_look/look_right.png"},
           "blink": {"folder": "01_blink", "files": ["blink_01.png", "blink_02.png", "blink_03.png"]}}
    with open(os.path.join(AST, "sequence.json"), "w") as f:
        json.dump(seq, f, ensure_ascii=False, indent=1)

    total = sum(len(v["files"]) for v in states.values())
    print("done, states:", len(states), "frames:", total)


if __name__ == "__main__":
    main()
