# Flowtype

Native macOS dictation. Hold a key, speak, and the text is typed into whatever app you're using.

## Using it

- **Push-to-talk:** hold **Fn** (configurable), speak, release. The transcript is pasted into the focused field.
- **Hands-free:** press **⌃⌥Space** to start and again to stop. Holding it also works as push-to-talk.
- **Cancel:** **Esc** while dictating.
- **Paste last transcript:** **⌃⌘V**.
- The **dictation bar** at the bottom of the screen shows a live waveform while recording. Hover it for a mic button.
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

## Releasing

Releases are signed with Developer ID, notarized, and shipped as a DMG on GitHub Releases. Installed copies update themselves through Sparkle, which reads `appcast.xml` from the latest release.

One-time setup:

1. Store notarization credentials in your keychain. Create an app-specific password at [account.apple.com](https://account.apple.com) first.
   ```bash
   xcrun notarytool store-credentials flowtype-notary --apple-id <you@example.com> --team-id HZHNBYQCWN --password <app-specific-password>
   ```
2. The Sparkle signing key is already in your login keychain (account `studio.infinitumlabs.flowtype`). Its public half is `SUPublicEDKey` in `Info.plist`. **Back it up**: without it you can never ship another update to existing installs.
   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account studio.infinitumlabs.flowtype -x sparkle-private-key.txt
   ```
   Store that file in a password manager, not in the repo.

Each release:

1. Bump `MARKETING_VERSION` in the project and commit. The build number comes from the git commit count.
2. Run `scripts/release.sh` to produce `build/release/Flowtype-<version>.dmg` and `appcast.xml`.
3. Run `scripts/release.sh --publish` to also tag the release and upload both files to GitHub.

The app icon is drawn by `scripts/render-icon.swift`; rerun it to regenerate `AppIcon.appiconset`.

## Permissions

- **Microphone** to record.
- **Accessibility** to paste into other apps (a synthesized ⌘V) and to detect the push-to-talk key. Without it, transcripts are copied to the clipboard instead.

macOS ties the Accessibility grant to the app's code signature. Builds are signed with the Infinitum Consulting team, so the grant survives rebuilds. If it ever stops working while System Settings still shows it switched on (for example after switching between a development build and a release), use **Already on?** on the Home screen. It runs `tccutil reset Accessibility studio.infinitumlabs.flowtype` and asks again.

For Fn push-to-talk, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing** so Fn doesn't also open the emoji picker.

## Notes

- Target: Apple Silicon, macOS 14+. Bundle ID: `studio.infinitumlabs.flowtype`.
- Transcription: on-device WhisperKit (English Base, Small or Large v3 Turbo; models are stored in `~/Library/Application Support/Flowtype/models`), or Groq `whisper-large-v3-turbo` with an API key stored in the Keychain.
- Audio is captured as 16 kHz mono in memory and never written to disk.
- Storage: SwiftData for history, usage, dictionary, snippets and notes; UserDefaults for settings. See [PRIVACY.md](PRIVACY.md).
- Logs: Console.app, subsystem `studio.infinitumlabs.flowtype`. Transcript text is never logged.
