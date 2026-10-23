#!/bin/bash
# Builds BirdWatcher.app (the desktop task panel) with the Command Line Tools' swiftc, installs it to
# /Applications (or ~/Applications), puts it on the Desktop and starts it. No Xcode project or licence needed.
#
#     ./build.sh            build for this Mac and install
#     ./build.sh --release  universal app (Apple silicon + Intel) in dist/BirdWatcher.dmg, nothing installed
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
# Built outside the clone: a second copy with the same bundle id would answer agentwidget:// links too.
BUILD=$(mktemp -d)
APP="$BUILD/BirdWatcher.app"
DEST=/Applications
[ -w "$DEST" ] || DEST=~/Applications
RELEASE=false; [ "${1:-}" = "--release" ] && RELEASE=true
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true); VERSION=${VERSION:-1.0}
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
$RELEASE && IDENTITY=-  # ad-hoc for others' Macs; Gatekeeper asks once either way

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCHS=arm64; $RELEASE && ARCHS="arm64 x86_64"
for arch in $ARCHS; do
    "$DEVELOPER_DIR/usr/bin/swiftc" -O -swift-version 5 -parse-as-library \
        -target $arch-apple-macos15.0 -sdk "$DEVELOPER_DIR/SDKs/MacOSX.sdk" \
        App/*.swift -o "$BUILD/BirdWatcher-$arch"
done
lipo -create "$BUILD"/BirdWatcher-* -output "$APP/Contents/MacOS/BirdWatcher"
cp App/Resources/*.svg App/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/collector" && cp collector/collect.py "$APP/Contents/Resources/collector/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BirdWatcher</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleDisplayName</key><string>BirdWatcher</string>
	<key>CFBundleIdentifier</key><string>com.nikolay.agentwidget</string>
	<key>CFBundleName</key><string>BirdWatcher</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Показва колко срещи имаш днес и предупреждава преди следващата.</string>
	<key>CFBundleURLTypes</key>
	<array><dict>
		<key>CFBundleURLName</key><string>BirdWatcher</string>
		<key>CFBundleURLSchemes</key><array><string>agentwidget</string></array>
	</dict></array>
</dict>
</plist>
PLIST
sed -i '' "s/<string>VERSION</<string>$VERSION</" "$APP/Contents/Info.plist"
codesign --force --sign "${IDENTITY:--}" "$APP"

if $RELEASE; then
    mkdir -p dist "$BUILD/dmg"
    cp -R "$APP" "$BUILD/dmg/"
    ln -s /Applications "$BUILD/dmg/Applications"
    rm -f dist/BirdWatcher.dmg
    hdiutil create -quiet -volname BirdWatcher -srcfolder "$BUILD/dmg" -format UDZO dist/BirdWatcher.dmg
    echo "dist/BirdWatcher.dmg ($VERSION, $(lipo -archs "$APP/Contents/MacOS/BirdWatcher"))"
    rm -rf "$BUILD"
    exit 0
fi

pkill -x BirdWatcher || true
pkill -x AgentWidget || true  # the app's name before BirdWatcher
while pgrep -x BirdWatcher >/dev/null || pgrep -x AgentWidget >/dev/null; do sleep 0.2; done  # or the new one quits
mkdir -p "$DEST" ~/.agent-widget
touch ~/.agent-widget/collect.log
rm -rf ~/Applications/"Agent Widget.app" "$DEST/BirdWatcher.app"
cp -R "$APP" "$DEST/"
rm -rf "$BUILD"
ln -sfn "$DEST/BirdWatcher.app" ~/Desktop/BirdWatcher  # an icon on the desktop
open "$DEST/BirdWatcher.app"
echo "Installed $DEST/BirdWatcher.app. The panel is on the desktop; drag it to move it."
