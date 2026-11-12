#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=../build/Scheng.app
rm -rf ../build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -framework AppKit -framework AVFoundation -lsqlite3 -o "$APP/Contents/MacOS/XiezhiPet" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources_icon_scale_black.png "$APP/Contents/Resources/icon_scale.png"
rsync -a --exclude '_*' --exclude '0[0-9]_*' --exclude '1[0-9]_*' --exclude '2[0-9]_*' ../assets "$APP/Contents/Resources/"
# 只拷 sequence.json 实际引用的静帧（眨眼 / 眼神跟随 / 躲藏等待）。
# 原来整目录拷 01_blink + 12_look + 13_hide 共 19 张，实际只用到 7 张。
python3 - ../assets "$APP/Contents/Resources/assets" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
cfg = json.load(open(os.path.join(src, "sequence.json")))
pairs = []
bk = cfg.get("blink", {})
for f in bk.get("files", []):
    pairs.append((bk.get("folder", "01_blink"), f))
for rel in cfg.get("look", {}).values():
    folder, name = os.path.split(rel)
    pairs.append((folder, name))
hw = cfg.get("hideWait")
if hw:
    pairs.append((cfg.get("hideFolder", "13_hide"), hw))
keep = list(dict.fromkeys(pairs))
for folder, name in keep:
    s = os.path.join(src, folder, name)
    if not os.path.isfile(s):
        raise SystemExit("missing static frame: " + s)
    os.makedirs(os.path.join(dst, folder), exist_ok=True)
    shutil.copy2(s, os.path.join(dst, folder, name))
print("static frames copied:", len(keep))
PY
# 不再吞掉签名失败：set -e 会让失败直接退出，并再校验一次封印
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built: $APP (签名已校验)"
