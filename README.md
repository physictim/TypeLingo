# TypeLingo · 打即通

**Type Chinese, instantly see the best English — learn as you type.**
打中文，即時看到最好的英文 — 邊打邊學的 macOS 翻譯浮窗。

> 繁體中文說明：[README.zh-Hant.md](README.zh-Hant.md)

| Live translation | English writing assistant |
|---|---|
| ![live translation](docs/panel.png) | ![english assistant](docs/english.png) |
| **Settings** | **Menu-bar toggle & styles** |
| ![settings](docs/settings.png) | ![menu](docs/menu.png) |

TypeLingo hooks into an open-source Chinese input method so that every sentence
you commit is translated to natural English in a floating panel, right where you
type — in **any app, including Microsoft Office**. It doubles as an English
writing assistant and a "select-anything-to-translate" tool.

> TypeLingo is a small Swift file + a few hook points you add to a
> [vChewing](https://github.com/vChewing/vChewing-macOS) fork. It is **not**
> affiliated with vChewing and does not use its name/trademark. See
> [INTEGRATION.md](INTEGRATION.md).

---

## ✨ Features

- **Live as-you-type translation** — commit Chinese, see streaming English appear
  inline, in any app (Office included), rendered by a native `NSPanel` (no webview
  throttling).
- **Learning note** — each translation comes with a short Traditional-Chinese note
- **Speak it** — a 🔊 at the end of the translation reads the whole sentence aloud (tap to stop). Uses the built-in system voice by default (offline, free); for the most natural voice, enable "high-quality TTS" in ⚙ and point it at an OpenAI-compatible endpoint such as a local **Kokoro-FastAPI**.
  explaining a key word choice / tone / grammar point.
- **English writing assistant** — type *English* and it rewrites it idiomatically,
  shows the Chinese meaning, and lists typo / grammar / usage suggestions.
- **Select to translate** — select text anywhere and press a hotkey (default
  ⌥⌘T) to translate/analyse it (via Accessibility). `⌘V` on the panel pastes &
  analyses the clipboard.
- **Precise mode** — understands the whole sentence, carries the last few
  sentences as context, applies a domain/terminology, and fixes colloquial /
  mis-segmented IME input.
- **Styles** — Business / Scientific / Casual, switchable from the panel or menu.
- **Local & self-hosted LLMs** — OpenAI, OpenRouter, **Ollama**, **LM Studio**, or
  any OpenAI-compatible endpoint (per-provider settings; local = free).
- **Token & cost meter**, resettable.
- **Polished panel** — translucent, draggable, resizable, opacity slider,
  per-provider profiles, on/off master switch.

## 🧠 How it works

| Capability | Mechanism |
|---|---|
| Live translation | IME `commit` hook → accumulate sentence → stream-translate |
| English capture | side-record ASCII keys (IME passes English through) |
| Select / paste translate | macOS Accessibility (`AXSelectedText`) + Carbon global hotkey |
| Display | native `NSVisualEffectView` panel (works on all Spaces, no throttling) |

## 📥 Download (prebuilt)

Grab the latest signed & notarized `TypeLingo.app` from
[**Releases**](https://github.com/physictim/TypeLingo/releases) — no building
required.

1. Unzip and move it into your input methods folder:
   ```bash
   cp -R TypeLingo.app ~/Library/Input\ Methods/
   ```
2. **System Settings → Keyboard → Input Sources → ＋ → Chinese, Traditional →
   TypeLingo → Add.**
3. Switch to TypeLingo, type Chinese → English streams into the panel.
4. Set your API key via the panel's ⚙ (or `~/.zhlearnime/config.json`).
5. For "select to translate" (⌥⌘T), grant **Accessibility** in System Settings →
   Privacy & Security.

> Requires macOS 13+. The release is de-sandboxed (so the Accessibility feature
> works) and Apple-notarized.

## 🚀 Build from source

You need a vChewing fork to host the hook. Full steps in
**[INTEGRATION.md](INTEGRATION.md)** (and [REBRAND.md](REBRAND.md) to ship it
under your own name):

1. Copy `ZhLearnHook.swift` into the vChewing assembly package.
2. Add four small hook points (menu, activate, commit, English capture) + an ATS
   key in `Info.plist`.
3. `bash scripts/build-sign-notarize.sh` (needs an Apple Developer ID — input
   methods on modern macOS must be notarized; we re-sign **without** the App
   Sandbox so Accessibility works).
4. Install into `~/Library/Input Methods/`, `pkill vChewing` to reload.

## ⚙️ Configuration

Settings live in `~/.zhlearnime/config.json` (see
[`config.example.json`](config.example.json)) or the gear (⚙) in the panel.

**Local LLM:** pick provider `ollama` / `lmstudio` (auto-targets `localhost`) or
fill a Base URL for a self-hosted server (e.g. `http://192.168.1.50:1234`); the
path is auto-completed to `/v1/chat/completions`. Each provider keeps its own
API key / model / Base URL.

> ⚠️ Don't expose a keyless local LLM to the public internet. Prefer a VPN such
> as Tailscale over port-forwarding.

**High-quality speech (Kokoro):** by default 🔊 uses the built-in system voice
(offline, free). For the most natural open-source voice, tick "high-quality TTS"
in ⚙ and run a local OpenAI-compatible TTS server — recommended:
[**Kokoro-FastAPI**](https://github.com/remsky/Kokoro-FastAPI) (Kokoro-82M,
Apache-2.0):

```bash
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu   # or the -gpu image
```

Then leave the ⚙ "TTS endpoint" at the default `http://localhost:8880`
(auto-completed to `/v1/audio/speech`) and set the voice to `af_heart` (others:
`af_bella` / `am_adam` / `bf_emma`…). Any OpenAI-compatible TTS works (including
cloud `tts-1`); if the endpoint is unreachable it falls back to the system voice.

## ⌨️ Usage

- Type Chinese → translation streams in the panel.
- Switch to English input → writing-assistant mode.
- Select text + **⌥⌘T** → translate the selection (grant Accessibility once).
- Click the panel + **⌘V** → translate the clipboard.
- Drag to move, drag the corner grip to resize, ⚙ for settings, ✕ to close.
- Menu bar (IME icon) → toggle "啟用即時翻譯" / switch style.

## 📄 License & credits

- TypeLingo code: **MIT** © 2026 Huang Yi-Hsiang.
- Designed to integrate with **vChewing** (MIT-NTL). TypeLingo is independent and
  does not use the vChewing name/trademark; if you build a derivative IME, comply
  with vChewing's license and rebrand it under your own name.

## ⚠️ Disclaimer

Building a notarized input method requires an Apple Developer account. Removing
the App Sandbox grants the input method normal file/network access — only build
and run input methods whose source you trust (this one is a single readable file).
Your committed text is sent to whichever LLM endpoint you configure.
