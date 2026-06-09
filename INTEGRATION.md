# Integrating TypeLingo into a vChewing fork

TypeLingo lives in a single file, `ZhLearnHook.swift`, plus **four small hook
points** in the host input method. The instructions below target
[vChewing-macOS](https://github.com/vChewing/vChewing-macOS); any open-source
Swift IMKit input method can be adapted similarly.

> Paths are relative to the vChewing repository root.

## 0. Add the core file

Copy `ZhLearnHook.swift` into:

```
Packages/vChewing_MainAssembly4Darwin/Sources/MainAssembly4Darwin/ZhLearnHook.swift
```

It is self-contained (translation engine, native `NSPanel`, settings window,
Carbon hotkey, streaming, per-provider profiles, cost meter). No other files
are added.

## 1. Menu + activate hook — `SessionController/SessionCtl.swift`

In `menu()`, append our items to the IME menu:

```swift
override public func menu() -> NSMenu {
  mainSync {
    let m = makeMenu()
    ZhLearnMenu.append(to: m, ctl: self)   // ← add
    return m
  }
}
```

In `activateServer(_:)`, reset state when the IME re-activates:

```swift
override public func activateServer(_ sender: any IMKTextInput) {
  core?.activateServer(sender)
  ZhLearnHook.imeActivated()               // ← add
}
```

## 2. Commit hook — `SessionController/InputSession_HandleStates.swift`

In `doCommit(_:)`, after the text is inserted, capture the committed Chinese and
the caret position:

```swift
func doCommit(_ theBuffer: String) {
  guard let client = client() else { return }
  client.insertText(theBuffer, replacementRange: replacementRange())
  var caretRect = NSRect.zero
  client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caretRect)
  ZhLearnHook.onCommit(theBuffer, caret: caretRect.origin)   // ← add
}
```

## 3. English capture — `Packages/vChewing_Typewriter/.../InputHandler/InputHandler_HandleStates.swift`

In `handleCapsLockAndAlphanumericalMode(input:)`, English (ASCII mode) is passed
straight through with `return false` and never reaches `doCommit`. Side-record
each printable English key (this does NOT change the IME's behaviour — it only
posts a notification before returning):

```swift
guard !shiftCapsLockHandling else {
  if input.charCode.isPrintableASCII {                       // ← add block
    NotificationCenter.default.post(name: .init("ZhLearnEnglishChar"), object: input.text)
  }
  return false
}

if session.isASCIIMode, !handleCapsLock {
  if input.charCode.isPrintableASCII {                       // ← add block
    NotificationCenter.default.post(name: .init("ZhLearnEnglishChar"), object: input.text)
  }
  return false
}
```

## 4. Allow local/self-hosted LLM over HTTP — `Sources/vChewingIME_macOS/Resources/Info.plist`

To reach Ollama / LM Studio / a self-hosted server over plain HTTP, add an App
Transport Security exception. **Use only `NSAllowsArbitraryLoads`** — adding
`NSAllowsLocalNetworking` alongside it makes macOS *ignore*
`NSAllowsArbitraryLoads`, which then blocks non-local HTTP:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

## 5. Build, sign (no sandbox), notarize

macOS 13+ requires input methods to be notarized, and the App Sandbox blocks the
Accessibility-based "select to translate" feature — so re-sign **without** the
sandbox entitlement. See `scripts/build-sign-notarize.sh` (edit the three
variables at the top for your Developer ID + notary profile), then:

```bash
bash scripts/build-sign-notarize.sh
```

Install the result into `~/Library/Input Methods/` and `pkill vChewing` to reload.

## 6. First run

- Put your settings in `~/.zhlearnime/config.json` (see `config.example.json`),
  or open the gear (⚙) in the floating panel.
- For "select to translate" (⌥⌘T by default), grant the input method
  **Accessibility** permission in System Settings → Privacy & Security.
