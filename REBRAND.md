# Rebranding (ship under your own name)

vChewing is **MIT-NTL** — you may fork and redistribute, but you must **not** use
the "vChewing" / "威注音" name or trademark for your distribution. So if you ship
a binary, rebrand it first. These are the exact changes used to produce the
TypeLingo release (adapt the identifiers to your own).

> Run all commands from your integrated vChewing fork's root. Work on a branch.

## 1. Bundle identifier (everywhere, consistently)

The IME bundle id is woven through the Info.plist (input-mode IDs, connection
name), `Shared.swift` (mode enum raw values), the build plugin, and more. Replace
the exact string in all non-test source/plist files:

```bash
OLD='org.atelierInmu.inputmethod.vChewing'
NEW='com.yourname.inputmethod.yourapp'
grep -rlZ "$OLD" Sources Packages Plugins --include='*.swift' --include='*.plist' \
  | tr '\0' '\n' | grep -v '/Tests/' \
  | while IFS= read -r f; do perl -i -pe "s/\Q$OLD\E/$NEW/g" "$f"; done
```

The bundle id **must** contain `.inputmethod.` (IMKit convention; macOS won't
register it otherwise).

## 2. Product name

In `Plugins/BundleApps/plugin.swift`, the main-app substitution map:

```swift
"${PRODUCT_NAME}": "TypeLingo",   // was "vChewing"  (CFBundleName / display name)
```

(Leave `${EXECUTABLE_NAME}` as is — it must match the built binary file name.)

## 3. Visible labels + copyright — `Sources/vChewingIME_macOS/Resources/Info.plist`

- `TISIconLabels → Primary` for each mode (the menu-bar short label):
  `简唯 → 简英`, `繁唯 → 繁英` (or your own 1–2 chars).
- `NSHumanReadableCopyright`: your copyright **+ attribution** to vChewing.
- (Optional) remove the `UpdateInfo*` keys so it doesn't check vChewing's update
  feed.

### ⚠️ Also rebrand the localized `.strings` (easy to miss)

The bundle-id sweep in step 1 only touches `*.swift` / `*.plist`. The
**input-source display name** and the menu labels come from
`Sources/vChewingIME_macOS/Resources/*.lproj/{InfoPlist,Localizable}.strings`.
If you skip these, macOS shows the **raw bundle id** as the name (because the
localized name is keyed by the *old* id) and the menu still reads the old brand.

In every `*.lproj/InfoPlist.strings`:
- Re-key the two input-mode lines to your new bundle id and give them your name:
  `"com.yourname.inputmethod.yourapp.IMECHT" = "YourApp-CHT";` (and `.IMECHS`).
- `CFBundleName` / `CFBundleDisplayName` → your app name (this is also the dimmed
  section header macOS draws above the IME menu).

In every `*.lproj/Localizable.strings`, debrand the menu strings:
`i18n:Common.VChewing`, `i18n:Menu.vChewingSettings`,
`i18n:Menu.EditVChewingUserPhrases`, `i18n:Menu.AboutVChewing`,
`i18n:Menu.UninstallVChewing`.

> The menu-bar 2-char badge is `TISIconLabels → Primary` (step 3). macOS caches
> input-source labels/names aggressively — after reinstalling, **log out/in** to
> force a re-scan, or the old badge/name may linger.

## 4. App icon — `Sources/vChewingIME_macOS/Resources/Images.xcassets/AppIcon.appiconset`

Regenerate the PNGs from your own 1024×1024 icon:

```bash
DST=Sources/vChewingIME_macOS/Resources/Images.xcassets/AppIcon.appiconset
for sz in 16 32 64 128 256 512 1024; do
  sips -s format png -z $sz $sz your_icon.icns --out "$DST/icon_${sz}.png"
done
```

## 5. Build, rename, sign (no sandbox), notarize

```bash
make release
cd Build/Products/Release
cp -R vChewing.app TypeLingo.app        # the bundle is already branded inside
# de-sandbox sign + notarize — see scripts/build-sign-notarize.sh
```

`make release` always writes `vChewing.app` as the *file name*; the bundle's
identity (id, CFBundleName, icon, labels) is already yours, so just copy it to
`TypeLingo.app`. Then de-sandbox sign + notarize that.

## 6. Verify before releasing

- `plutil -extract CFBundleIdentifier raw TypeLingo.app/Contents/Info.plist`
- Install to `~/Library/Input Methods/`, **log out/in** if needed, then
  System Settings → Keyboard → Input Sources → ＋ → it must appear under
  Traditional Chinese. Type to confirm it works.
