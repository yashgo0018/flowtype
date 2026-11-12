# Flowtype Privacy Policy

_Last updated: November 12, 2026_

Flowtype is a macOS dictation and meeting transcription app published by Infinitum Consulting LLC. It is designed to keep your voice and text on your Mac.

## What Flowtype collects

Nothing is sent to us. Flowtype has no accounts, analytics, telemetry or crash reporting.

## Your audio

- Dictation audio is recorded only while you dictate. The dictation bar shows a waveform and timer whenever the microphone is on.
- Dictation audio is kept in memory and is never written to disk. It is discarded as soon as it has been transcribed.
- **On-device transcription (the default):** audio is transcribed on your Mac and never leaves it, whether you use Apple's built-in speech model (macOS 26 and later) or Whisper.
- **Groq cloud transcription (optional, off by default):** if you choose Groq in Settings and add your own API key, each dictation's audio, plus the words in your Dictionary as spelling hints, is sent to Groq, Inc. for transcription. Groq's handling of that data is governed by [Groq's privacy policy](https://groq.com/privacy-policy/). Your API key is stored in your macOS Keychain.

## Meeting capture and Calendar

- Meeting capture records your microphone and **system audio from all apps**, not only the selected call. No screen video is captured. The menu bar shows REC and Meetings opens at capture start. Get participants’ permission before recording; a calendar event does not establish attendance or consent.
- Meeting recognition is local only (Apple Speech or Whisper), independent of dictation’s Groq setting. Initial model installation may need internet. No meeting audio, transcript or event content is sent to Groq, to us, or to participants.
- By default meeting audio stays in bounded memory with no temporary audio files. Queued audio is discarded after processing; forced quit/crash loses pending audio. Failed/dropped intervals are disclosed in the transcript. Recovery preserves text already checkpointed to disk.
- **Keep meeting audio** is a separate explicit opt-in. It saves separate source WAV chunks locally, with independent 1/7/30-day retention and per-meeting audio deletion. These chunks are not a continuous playable recording guarantee. Deleting a meeting removes its managed text and audio.
- Meeting transcripts are saved by default, independently of dictation history. Turn off saving, keep until deletion, or delete after 24 hours from completion in meeting settings. Retention runs at launch and while the app is running and idle; it cannot delete while the app is closed. Each session keeps its original policy. With saving off, text remains only in this app launch unless exported. Optional retained audio still has minimal session metadata, without transcript text.
- Meeting files are under `~/Library/Application Support/Flowtype/Meetings`, with private directory/file permissions, atomic transcript checkpoints and a backup-exclusion flag. Flowtype does not encrypt them. FileVault, external backups and exported copies have their own protection/retention. Delete exported/backed-up copies separately.
- Calendar integration defaults to Off. Enabling Suggest or Auto-start requests EventKit Full Access, required to read event details on macOS 14+. Flowtype only reads selected calendars, never edits events or contacts attendees. Event details are used transiently for eligibility, not saved with a transcript or logged. Settings retain selected calendar IDs; deduplication retains SHA-256 occurrence hashes and trigger times for up to 90 days. Calendar names are displayed in the UI.
- Suggest requires an explicit Start. Auto-start is deliberate opt-in, requires a manual source check during the current app launch, opens Meetings visibly and has configurable event-end stop and a mandatory duration limit. Sleep interrupts capture. No participant notifications or automatic joining are performed. No notification permission is requested.
- Meeting capture requires macOS 14.2+ and asks for system-audio-only recording permission through Core Audio, plus Microphone. It does not request screen capture access, change the default output device or install a driver.

See [meeting documentation](docs/MEETINGS.md) for source, language, timestamp, retention and recovery limitations.

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

- download Whisper speech models from Hugging Face (`huggingface.co`) when you first use one (Apple's speech model is downloaded and managed by macOS itself, from Apple);
- send audio to Groq, if you enabled it;
- check for app updates on GitHub (`github.com`), which shares only your app version and macOS version, as any web request would.

## Permissions

- **Microphone:** to record while you dictate or capture a meeting.
- **System Audio Recording (meetings only):** to transcribe output from all apps, without screen video.
- **Calendar Full Access (optional):** to read details for selected-calendar meeting suggestions or auto-start.
- **Accessibility:** to paste into the app you're using and to detect your push-to-talk key. Flowtype does not read or store what you type.

## Contact

Questions: open an issue at https://github.com/yashgo0018/flowtype/issues.
