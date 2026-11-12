#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=../build/獬豸桌宠.app
rm -rf ../build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -framework AppKit -framework AVFoundation -lsqlite3 -o "$APP/Contents/MacOS/XiezhiPet" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Resources_icon_scale_black.png "$APP/Contents/Resources/icon_scale.png"
rsync -a --exclude '_*' --exclude '0[0-9]_*' --exclude '1[0-9]_*' --exclude '2[0-9]_*' ../assets "$APP/Contents/Resources/"
rsync -a ../assets/01_blink ../assets/12_look ../assets/13_hide "$APP/Contents/Resources/assets/"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
