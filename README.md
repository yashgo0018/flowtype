# Flowtype

Native macOS implementation of the Flowtype dictation app. This lives beside the Python prototype and starts with fresh native settings/data.

## Build

Open `Flowtype.xcodeproj` in Xcode 26+ and run the `Flowtype` scheme on My Mac.

Command line:

```bash
xcodebuild -project Flowtype.xcodeproj -scheme Flowtype -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

## Test

```bash
xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype -configuration Debug -destination 'platform=macOS,arch=arm64'
```

## Notes

- Target: Apple Silicon, macOS 14+.
- Bundle ID: `com.yashgoyal.Flowtype`.
- Transcription: local WhisperKit with default model `openai_whisper-small.en`.
- Storage: SwiftData and UserDefaults under the native app, with no Python data migration.
- Permissions: microphone for recording and Accessibility for global shortcuts/paste.
