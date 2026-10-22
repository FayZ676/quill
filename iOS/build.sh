#!/bin/bash
# Builds Quill for iOS and installs it on a connected iPhone or iPad, or with UPLOAD=1,
# archives it and uploads it to App Store Connect.
#
# Signs with the team in project.yml; Xcode must be signed in to that Apple account
# (Xcode › Settings › Accounts) so it can make the provisioning profile.
#
#   VERSION   version to stamp (default 1.0.0)
#   BUILD     build number (default: VERSION; with UPLOAD=1, the current time, so each upload is new)
#   DEVICE    devicectl identifier or name (default: the first available paired iPhone/iPad)
#   INSTALL=0 build only
#   UPLOAD=1  archive and upload; needs an App Store Connect API key in ASC_KEY_ID and
#             ASC_ISSUER_ID (the .p8 in ~/.appstoreconnect/private_keys, or ASC_KEY_PATH)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0.0}
UPLOAD=${UPLOAD:-0}
if [ "$UPLOAD" = 1 ]; then BUILD=${BUILD:-$(date +%Y%m%d%H%M)}; else BUILD=${BUILD:-$VERSION}; fi
OUT=build
APP="$OUT/DerivedData/Build/Products/Release-iphoneos/Quill.app"
command -v xcodegen >/dev/null || { echo "xcodegen is needed: brew install xcodegen" >&2; exit 1; }

echo "==> Drawing icon"
ICONSET="$OUT/Icon.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
ACCENT=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["colors"][0]["color"]["components"]; print("".join(c[k][2:] for k in ("red","green","blue")))' ../Resources/Assets.xcassets/AccentColor.colorset/Contents.json)
swift ../scripts/make-icon.swift "$ICONSET/icon-1024.png" "$ACCENT" ios
echo '{"info":{"author":"xcode","version":1}}' > "$OUT/Icon.xcassets/Contents.json"
cat > "$ICONSET/Contents.json" <<'JSON'
{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
 "info":{"author":"xcode","version":1}}
JSON

echo "==> Generating Xcode project"
VERSION=$VERSION BUILD=$BUILD xcodegen generate --quiet

if [ "$UPLOAD" = 1 ]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  ARCHIVE="$OUT/Quill.xcarchive"
  echo "==> Archiving $VERSION ($BUILD)"
  xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath "$OUT/DerivedData" \
    -archivePath "$ARCHIVE" "${AUTH[@]}" -quiet archive
  cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  echo "==> Uploading to App Store Connect"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" "${AUTH[@]}"
  echo "==> Uploaded $VERSION ($BUILD); it appears in App Store Connect once processed"
  exit 0
fi

echo "==> Compiling"
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$OUT/DerivedData" \
  -allowProvisioningUpdates -quiet build

[ "${INSTALL:-1}" = 0 ] && { echo "==> Built: $APP"; exit 0; }

if [ -z "${DEVICE:-}" ]; then
  JSON="$OUT/devices.json"
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("pairingState") == "paired" \
       and d["connectionProperties"].get("tunnelState") != "unavailable":
        print(d["identifier"]); break' "$JSON")
  [ -n "$DEVICE" ] || { echo "No paired iPhone or iPad is available. Unlock it and connect it (or join the same Wi-Fi)." >&2; exit 1; }
fi

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "App installed|bundleID" || true
echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE" com.faizififita.quill >/dev/null
echo "==> Done"
