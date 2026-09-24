# Flowtype

Native macOS dictation. Hold a key, speak, and the text is typed into whatever app you're using.

## Using it

- **Push-to-talk:** hold **Fn** (configurable), speak, release. The transcript is pasted into the focused field.
- **Hands-free:** press **⌃⌥Space** to start and again to stop. Holding it also works as push-to-talk.
- **Cancel:** **Esc** while dictating.
- **Paste last transcript:** **⌃⌘V**.
- The **Flow Bar** at the bottom of the screen shows a live waveform while recording. Hover it for a mic button.
- The **menu bar icon** opens the Hub (Home, History, Dictionary, Snippets, Notes, Settings) and has Quit.

**Dictionary** entries fix spellings and casing in every transcript and are sent to Groq as vocabulary hints. **Snippets** expand a spoken cue ("my calendar link") into saved text.

## Build

Open `Flowtype.xcodeproj` in Xcode 26+ and run the `Flowtype` scheme on My Mac, or:

```bash
xcodebuild -project Flowtype.xcodeproj -scheme Flowtype -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

## Test

```bash
xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype -configuration Debug -destination 'platform=macOS,arch=arm64'
```

## Permissions

- **Microphone** to record.
- **Accessibility** to paste into other apps (a synthesized ⌘V) and to detect the push-to-talk key. Without it, transcripts are copied to the clipboard instead.

macOS ties the Accessibility grant to the app's code signature. The project has no development team set, so each rebuild is ad-hoc signed and macOS silently stops trusting it, even though System Settings still shows it switched on. Use **Already on?** on the Home screen (it runs `tccutil reset Accessibility studio.infinitumlabs.flowtype` and asks again), or set a development team so the signature is stable.

For Fn push-to-talk, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing** so Fn doesn't also open the emoji picker.

## Notes

- Target: Apple Silicon, macOS 14+. Bundle ID: `studio.infinitumlabs.flowtype`.
- Transcription: on-device WhisperKit (English Base, Small or Large v3 Turbo; models are stored in `~/Library/Application Support/Flowtype/models`), or Groq `whisper-large-v3-turbo` with an API key stored in the Keychain.
- Audio is captured as 16 kHz mono in memory and never written to disk.
- Storage: SwiftData for history, usage, dictionary, snippets and notes; UserDefaults for settings.
