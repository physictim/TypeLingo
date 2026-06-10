# Third-party notices

TypeLingo bundles / downloads the following components for its optional
"high-quality local (Piper)" speech engine.

## sherpa-onnx (bundled binary)

- Project: https://github.com/k2-fsa/sherpa-onnx
- License: Apache License 2.0
- Used as: the prebuilt universal macOS `sherpa-onnx-offline-tts` executable,
  bundled at `TypeLingo.app/Contents/Helpers/` (re-signed with the distributor's
  Developer ID for macOS code-signing requirements; unmodified otherwise).

A copy of the Apache-2.0 license is available at
https://www.apache.org/licenses/LICENSE-2.0 and in the sherpa-onnx repository.

## Piper voice model (downloaded on first use)

- Project: https://github.com/rhasspy/piper (MIT) and
  https://github.com/rhasspy/piper-voices
- Voice: `en_US-amy-medium`, downloaded on demand from the sherpa-onnx
  `tts-models` release to `~/.zhlearnime/tts/` (not redistributed by TypeLingo).

## espeak-ng data (inside the voice package)

- Project: https://github.com/espeak-ng/espeak-ng
- License: GPL-3.0 (data/used as a separate phonemization resource by the
  sherpa-onnx process at runtime; downloaded with the voice package, not bundled
  in the TypeLingo app).
