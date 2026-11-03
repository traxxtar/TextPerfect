#!/bin/bash
# Builds TextPerfect.app next to this script. Needs Xcode or the Command Line Tools.
# Usage:  cd ~/TextPerfect && ./build_app.sh && open TextPerfect.app
#         ./build_app.sh install    also copies the app into ~/Applications
#         ./build_app.sh release    also notarizes it and makes TextPerfect-<version>.zip
set -e
cd "$(dirname "$0")"

VERSION="1.1"
BUILD="2"

# Developer ID certificate to sign with (by SHA-1, since the keychain holds two with the same
# name). On a Mac without it, the app is signed ad hoc and runs only on that Mac.
SIGN_ID="CBA88C35B561BCF5B29EAA83013E98E065F17897"
# notarytool keychain profile, made once per Mac with `xcrun notarytool store-credentials`.
NOTARY_PROFILE="TextPerfect-notary"

# Universal: runs on Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TextPerfect"

APP="TextPerfect.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TextPerfect"
# Icon: AppIcon.icns and AppIcon_1024.png are made from Icon.png by make_icon.swift.
# Rebuild them whenever Icon.png is newer, so swapping in new artwork is just a rebuild.
if [ -f Icon.png ] && { [ ! -f AppIcon.icns ] || [ Icon.png -nt AppIcon.icns ]; }; then
    swift make_icon.swift
fi
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f AppIcon_1024.png ]; then
    cp AppIcon_1024.png "$APP/Contents/Resources/SplashIcon.png"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TextPerfect</string>
    <key>CFBundleDisplayName</key><string>TextPerfect</string>
    <key>CFBundleIdentifier</key><string>com.dlm7072.textperfect</string>
    <key>CFBundleExecutable</key><string>TextPerfect</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__BUILD__</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Files TextPerfect accepts on its Dock icon and in Finder's Open With: its own .lp
         documents, and any plain text (as an alternate, so it doesn't take over .txt). -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>TextPerfect Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.dlm7072.textperfect.lp</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Plain Text</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.dlm7072.textperfect.lp</string>
            <key>UTTypeDescription</key><string>TextPerfect Document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>lp</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF
sed -i '' -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$APP/Contents/Info.plist"

# Finder info or resource forks on the bundle (e.g. an icon pasted in Get Info) break the signature.
xattr -cr "$APP"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    # Hardened runtime and a secure timestamp are what notarization requires.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    echo "Signed with Developer ID"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed"
    echo "Signed ad hoc (Developer ID certificate not on this Mac)"
fi

# The bundle was just deleted and recreated at the same path; make Finder and the Dock
# pick up its icon instead of showing a stale or generic one.
touch "$APP"
"$LSREGISTER" -f "$APP"

echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/TextPerfect"))"

if [ "$1" = "release" ]; then
    ZIP="TextPerfect-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # Staple the ticket into the app so it opens without a network check, then zip it again.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute -v "$APP"
    echo "Made $ZIP"
fi

if [ "$1" = "install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP"
    cp -R "$APP" "$HOME/Applications/$APP"
    touch "$HOME/Applications/$APP"
    "$LSREGISTER" -f "$HOME/Applications/$APP"
    echo "Installed $HOME/Applications/$APP"
fi

echo "Screen margins compiled into this build:"
grep -h "let leftMargin\|let topMargin" Sources/TextPerfect/ScreenView.swift
