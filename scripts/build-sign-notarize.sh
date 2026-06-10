#!/bin/bash
#
# TypeLingo — build + de-sandbox sign + notarize a vChewing fork that has the
# TypeLingo hook integrated. macOS 13+ rejects input methods that are not
# notarized, and the App Sandbox blocks the Accessibility ("select to translate")
# feature, so we re-sign WITHOUT the sandbox entitlement and notarize.
#
# REQUIREMENTS (set these for your own machine):
#   - A paid Apple Developer account + "Developer ID Application" certificate.
#   - A notarytool keychain profile (create once):
#       xcrun notarytool store-credentials <PROFILE_NAME> \
#         --apple-id you@example.com --team-id YOURTEAMID --password <app-specific-password>
#
# EDIT THE THREE VARIABLES BELOW, then run:  bash build-sign-notarize.sh
set -euo pipefail

# ---- EDIT THESE ----
VCHEWING_DIR="${VCHEWING_DIR:-$HOME/Projects/vChewing-macOS}"   # your integrated vChewing fork
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-your-notary-profile}"
# --------------------

BUILT="$VCHEWING_DIR/Build/Products/Release/vChewing.app"
APP="$VCHEWING_DIR/Build/Products/Release/TypeLingo.app"

echo "▶ Building (make release)…"
( cd "$VCHEWING_DIR" && make release )

# make release always emits the file name vChewing.app; the bundle identity
# (id / name / icon) is already rebranded inside, so just give it the right name.
echo "▶ Renaming to TypeLingo.app…"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

# Optional: bundle the sherpa-onnx engine so the "high-quality local (Piper)"
# 🔊 option works. The voice model is auto-downloaded by the app on first use;
# here we only embed the (Apache-2.0) inference binary, signed with your ID.
# Set SKIP_TTS=1 to skip.
if [ "${SKIP_TTS:-0}" != "1" ]; then
  SHERPA_VER="${SHERPA_VER:-v1.13.2}"
  echo "▶ Embedding sherpa-onnx TTS engine ($SHERPA_VER)…"
  TMP=$(mktemp -d)
  curl -sL -o "$TMP/s.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/$SHERPA_VER/sherpa-onnx-$SHERPA_VER-osx-universal2-static.tar.bz2"
  tar xjf "$TMP/s.tar.bz2" -C "$TMP"
  mkdir -p "$APP/Contents/Helpers"
  cp "$TMP/sherpa-onnx-$SHERPA_VER-osx-universal2-static/bin/sherpa-onnx-offline-tts" \
    "$APP/Contents/Helpers/sherpa-onnx-offline-tts"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/sherpa-onnx-offline-tts"
  rm -rf "$TMP"
fi

# `make release` converts the menu-bar icons to .tiff, but the Info.plist still
# references "MenuIcon-*.png" (vChewing's original keys). With only the .tiff
# present, macOS can't resolve the icon and falls back to the TISIconLabels text.
# Ship the exact-named PNGs too so the input-source icon actually shows.
ICONSRC="$VCHEWING_DIR/Sources/vChewingIME_macOS/Resources/MenuIcons"
if [ -d "$ICONSRC" ]; then
  echo "▶ Adding menu-icon PNGs (so the input-source icon resolves)…"
  cp "$ICONSRC"/MenuIcon-*CVIM*.png "$APP/Contents/Resources/" 2>/dev/null || true
fi

echo "▶ Writing no-sandbox entitlements…"
ENT=/tmp/typelingo_nosandbox.plist
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
EOF

echo "▶ Re-signing without App Sandbox (hardened runtime kept)…"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | grep -qi sandbox \
  && echo "⚠️  sandbox still present" || echo "✅ sandbox removed"

echo "▶ Notarizing…"
ditto -c -k --keepParent "$APP" /tmp/typelingo.zip
xcrun notarytool submit /tmp/typelingo.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f /tmp/typelingo.zip
xcrun stapler validate "$APP"

echo ""
echo "✅ Done. Install with:"
echo "   rm -rf ~/Library/Input\\ Methods/TypeLingo.app"
echo "   cp -R \"$APP\" ~/Library/Input\\ Methods/"
echo "   killall vChewing 2>/dev/null   # reload (the executable inside is named vChewing)"
