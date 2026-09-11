#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=.local/signing-identity
if [[ ! -f "$CONFIG" ]]; then echo 'Missing .local/signing-identity; configure a persistent signing certificate.' >&2; exit 1; fi
IDENTITY=$(cat "$CONFIG")
[[ "$IDENTITY" != '-' && -n "$IDENTITY" ]] || exit 1
swift build -c release
APP=dist/WMRecorder.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WMRecorder "$APP/Contents/MacOS/WMRecorder"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.wuming.wmrecorder</string>
<key>CFBundleExecutable</key><string>WMRecorder</string>
<key>CFBundleName</key><string>WMRecorder</string>
<key>CFBundleDisplayName</key><string>悟鸣录屏</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>100</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>录制你的麦克风声音，并执行你授权的本机录音测试。</string>
<key>NSCameraUsageDescription</key><string>录制摄像头和画中画，并执行你授权的本机摄像头测试。</string>
<key>NSScreenCaptureUsageDescription</key><string>录制屏幕与系统音频，并执行你授权的本机录屏测试。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
SOURCE_HASH=$(python3 scripts/source-fingerprint.py)
/usr/libexec/PlistBuddy -c "Add :WMSourceFingerprint string $SOURCE_HASH" "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier com.wuming.wmrecorder "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ -d /Applications/WMRecorder.app ]]; then
 PREVIOUS=$(codesign -d -r- /Applications/WMRecorder.app 2>&1 | sed -n 's/^designated => //p')
 [[ -n "$PREVIOUS" ]]
 codesign --verify --strict -R "= $PREVIOUS" "$APP"
fi
