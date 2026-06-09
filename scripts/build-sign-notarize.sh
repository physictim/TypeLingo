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

APP="$VCHEWING_DIR/Build/Products/Release/vChewing.app"

echo "▶ Building (make release)…"
( cd "$VCHEWING_DIR" && make release )

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
echo "   rm -rf ~/Library/Input\\ Methods/vChewing.app"
echo "   cp -R \"$APP\" ~/Library/Input\\ Methods/"
echo "   pkill vChewing   # reload"
