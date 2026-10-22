#!/bin/bash
# Builds Quill.app (universal) and packages it as a drag-to-install DMG in ./build.
#
# With a "Developer ID Application" certificate in the keychain, the app and DMG are signed
# with it and the DMG is notarized by Apple and stapled, so it opens without warnings on any
# Mac. Without one, it falls back to an ad hoc signature that only runs warning-free here.
#
#   SIGN_IDENTITY   certificate to use (default: first Developer ID Application found)
#   NOTARY_PROFILE  notarytool keychain profile (default: quill-notary), created once with
#                   xcrun notarytool store-credentials quill-notary --apple-id <email> --team-id <team>
#   NOTES           release notes shown in the in-app update prompt (plain text)
#
# Alongside the DMG it writes Quill.zip and appcast.xml, the Sparkle update and its feed, signed
# with the "quill" EdDSA key in the keychain. Attach all three to the GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

APP=Quill
VERSION=${VERSION:-1.0.0}
OUT=build
APPDIR="$OUT/$APP.app"
DMG="$OUT/$APP-$VERSION.dmg"
ZIP="$OUT/$APP.zip"
REPO=FayZ676/quill
SPARKLE=.build/artifacts/sparkle/Sparkle
NOTARY_PROFILE=${NOTARY_PROFILE:-quill-notary}
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Compiling (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP"

echo "==> Assembling $APP.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources/Fonts"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APPDIR/Contents/Info.plist"
cp Resources/Fonts/*.ttf Resources/Fonts/LICENSE.md "$APPDIR/Contents/Resources/Fonts/"
mkdir -p "$APPDIR/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APPDIR/Contents/Frameworks/Sparkle.framework"

echo "==> Compiling asset catalog (accent color)"
xcrun actool Resources/Assets.xcassets --compile "$APPDIR/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 \
  --output-partial-info-plist "$OUT/assets-info.plist" >/dev/null 2> >(grep -v "^dyld\[" >&2)

echo "==> Drawing icon"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
ACCENT=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["colors"][0]["color"]["components"]; print("".join(c[k][2:] for k in ("red","green","blue")))' Resources/Assets.xcassets/AccentColor.colorset/Contents.json)
swift scripts/make-icon.swift "$OUT/icon-1024.png" "$ACCENT"
for size in 16 32 128 256 512; do
  sips -z $size $size "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/AppIcon.icns"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with $SIGN_IDENTITY"
  # Notarization requires the hardened runtime and a secure timestamp. Sparkle's helpers are
  # signed inside out, as its docs lay out; the downloader keeps its sandbox entitlements.
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  FW="$APPDIR/Contents/Frameworks/Sparkle.framework/Versions/B"
  "${SIGN[@]}" "$FW/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$FW/Autoupdate" "$FW/Updater.app"
  "${SIGN[@]}" "$APPDIR/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" "$APPDIR"
else
  echo "==> Signing (ad hoc; no Developer ID Application certificate found)"
  codesign --force --deep --sign - "$APPDIR"
fi
codesign --verify --strict "$APPDIR"

echo "==> Creating DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# macOS won't let hdiutil copy Quill.app into a volume named "Quill" ("Operation not
# permitted"), so the image is made under another name and renamed before compressing.
RW="$OUT/$APP-rw.dmg"
hdiutil create -volname "$APP Stage" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
DEV=$(hdiutil attach -nobrowse -noverify "$RW" | awk -v vol="/Volumes/$APP Stage" 'index($0, vol) {print $1}')
diskutil rename "$DEV" "$APP" >/dev/null
hdiutil detach "$DEV" >/dev/null
hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null
rm -rf "$STAGE" "$ICONSET" "$RW"

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing (usually a few minutes)"
    RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$RESULT" | grep -E "id:|status:" | tail -2
    if ! echo "$RESULT" | grep -q "status: Accepted"; then
      ID=$(echo "$RESULT" | sed -n 's/^ *id: //p' | head -1)
      echo "Notarization failed. Apple's log:" >&2
      [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
      exit 1
    fi
    echo "==> Stapling ticket"
    xcrun stapler staple "$DMG" >/dev/null
    # The DMG's ticket covers the app inside it too, so the update zip opens offline as well.
    xcrun stapler staple "$APPDIR" >/dev/null
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  else
    echo "==> Skipping notarization: no notarytool profile named '$NOTARY_PROFILE'" >&2
  fi
fi

echo "==> Packaging the update"
ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$ZIP"
SIGNATURE=$("$SPARKLE/bin/sign_update" --account quill "$ZIP")
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP</title>
    <item>
      <title>$APP $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>${NOTES:-}</p>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$APP.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

echo "==> Done: $DMG, $ZIP, $OUT/appcast.xml"
