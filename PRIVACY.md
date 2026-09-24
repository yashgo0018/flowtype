# Flowtype Privacy Policy

_Last updated: September 24, 2026_

Flowtype is a macOS dictation app published by Infinitum Consulting LLC. It is designed to keep your voice and text on your Mac.

## What Flowtype collects

Nothing is sent to us. Flowtype has no accounts, analytics, telemetry or crash reporting.

## Your audio

- Audio is recorded only while you dictate. The dictation bar shows a waveform and timer whenever the microphone is on.
- Audio is kept in memory and is never written to disk. It is discarded as soon as it has been transcribed.
- **On-device transcription (the default):** audio is transcribed on your Mac and never leaves it.
- **Groq cloud transcription (optional, off by default):** if you choose Groq in Settings and add your own API key, each dictation's audio, plus the words in your Dictionary as spelling hints, is sent to Groq, Inc. for transcription. Groq's handling of that data is governed by [Groq's privacy policy](https://groq.com/privacy-policy/). Your API key is stored in your macOS Keychain.

## Your text and data

Stored only on your Mac, in `~/Library/Application Support/Flowtype` and the app's preferences:

- **Transcript history.** You can keep it, auto-delete it after 24 hours, or turn saving off in Settings → Privacy, and delete it at any time.
- **Usage statistics** (daily word counts and dictation time) that power the Home screen.
- **Your Dictionary, Snippets and Notes.**

Flowtype never records or saves dictations into password fields.

## Clipboard

To insert text, Flowtype places the transcript on the clipboard, simulates ⌘V, and then restores what you had copied before. The temporary entry is marked so clipboard managers ignore it.

## Network connections

Flowtype connects to the internet only to:

- download speech models from Hugging Face (`huggingface.co`) when you first use a model;
- send audio to Groq, if you enabled it;
- check for app updates on GitHub (`github.com`), which shares only your app version and macOS version, as any web request would.

## Permissions

- **Microphone:** to record while you dictate.
- **Accessibility:** to paste into the app you're using and to detect your push-to-talk key. Flowtype does not read or store what you type.

## Contact

Questions: open an issue at https://github.com/yashgo0018/flowtype/issues.
