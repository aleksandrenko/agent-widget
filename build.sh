#!/bin/bash
# Builds Agent Widget.app (the desktop task panel) with the Command Line Tools' swiftc,
# installs it to ~/Applications and starts it. Needs no Xcode project and no Xcode licence.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
# Built outside the clone: a second copy with the same bundle id would answer agentwidget:// links too.
BUILD=$(mktemp -d)
APP="$BUILD/Agent Widget.app"
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$DEVELOPER_DIR/usr/bin/swiftc" -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos15.0 -sdk "$DEVELOPER_DIR/SDKs/MacOSX.sdk" \
    App/*.swift -o "$APP/Contents/MacOS/AgentWidget"
cp App/Resources/*.svg "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AgentWidget</string>
	<key>CFBundleIdentifier</key><string>com.nikolay.agentwidget</string>
	<key>CFBundleName</key><string>Agent Widget</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Показва колко срещи имаш днес и предупреждава преди следващата.</string>
	<key>CFBundleURLTypes</key>
	<array><dict>
		<key>CFBundleURLName</key><string>Agent Widget</string>
		<key>CFBundleURLSchemes</key><array><string>agentwidget</string></array>
	</dict></array>
</dict>
</plist>
PLIST
codesign --force --sign "${IDENTITY:--}" "$APP"

pkill -x AgentWidget || true
while pgrep -x AgentWidget >/dev/null; do sleep 0.2; done  # the old one must be gone, or the new one quits
mkdir -p ~/Applications ~/.agent-widget
touch ~/.agent-widget/collect.log
rm -rf ~/Applications/"Agent Widget.app"
cp -R "$APP" ~/Applications/
rm -rf "$BUILD"
open ~/Applications/"Agent Widget.app"
echo "Installed. The panel is on the desktop; drag its glass to move it."
