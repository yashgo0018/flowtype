# Meeting transcription

Meeting capture is separate from dictation. Open **Meetings** or choose **Start Meeting Capture** from the menu bar. The default global toggle is **Control–Command–M**, configurable in Settings. Stop from the same controls. The menu bar displays **REC** during capture and **Meeting…** during preparation/finalization. The Meetings window opens when recording starts. Quit waits for pending transcription to finish; forced termination can lose pending audio.

Obtain participants’ permission before recording. Calendar time cannot prove attendance or consent. Use headphones: speakers can feed remote speech back into the microphone, so both labels may contain it. There is no echo cancellation or participant diarization. **You** means microphone input, not a verified identity; **System audio** combines all apps, including notifications/music. Protected or unusual audio routes may be silent. Flowtype excludes its own process where Core Audio can identify it. System sounds and helper processes may still be included.

## Requirements and local operation

- Audio-only Core Audio process taps require **macOS 14.2+**. On 14.0/14.1 Flowtype displays a clear unsupported message; dictation continues to work. No virtual driver, output-device switch, screen video, screen capture entitlement, or screen recording permission is used.
- macOS requests **System Audio Recording** when starting the tap’s aggregate input; the permission is distinct from Microphone. Names/placement in Privacy & Security vary by OS. Enable both permissions for Flowtype. There is no public Core Audio API here to query system-audio authorization ahead of capture. Denial, missing callbacks and silent streams must be checked; silence alone cannot distinguish denial from no playback.
- Automatic engine selection uses Apple’s on-device SpeechAnalyzer on supported macOS 26+ Macs, otherwise local WhisperKit. The meeting engine/model/language are independent of dictation settings. Groq is **unsupported for meetings**, even if selected for dictation.
- Initial speech assets/model preparation can require a download. Once installed, recognition runs locally. Unsupported Apple locales fail before capture; select Whisper or another language. Whisper Base/Small `.en` models accept English only; Large v3 Turbo supports other Whisper languages. One selected language per session; no automatic code switching guarantee.
- Sources are decoded **serially**, in non-overlapping 20-second chunks. This avoids depending on simultaneous SpeechAnalyzer capacity. Only final Apple results are collected. Apple result ranges and Whisper segment times are offset onto the capture timeline; these are recognition estimates, not word-perfect clock guarantees. Chunk boundaries can split words or reduce context/accuracy. Speech under the silence threshold may be skipped. A transcript appears after each processed chunk and after stop; it is not guaranteed to be live.

## Storage and failure behavior

By default, meeting audio exists only in bounded memory. There are **no temporary audio files**. The callback queue holds six complete chunks plus two partial source chunks; the worker holds one additional chunk (at most 11.52 MB of 16 kHz float PCM, plus converter/model/text overhead). Model memory is separate and can be substantial. If decoding cannot keep up, dropped intervals receive timestamped notices. Stop closes capture and flushes pending partial chunks. During finalization you can cancel remaining transcription; completed text is preserved and discarded intervals are disclosed. Device changes, missing streams, sleep, storage/model errors and duration limits stop capture; partial results and notices remain available. Check the transcript’s status before relying on it. No speech yields an explicit unsuccessful result.

Meeting records use versioned `session.json` files under `~/Library/Application Support/Flowtype/Meetings/<UUID>/`. Directories are mode 0700 and files 0600. The meeting directory is excluded from system backups; existing external/manual backups and exported copies remain outside Flowtype’s control. It is not encrypted by Flowtype; use FileVault for disk protection. Atomic transcript checkpoints are written after each decoded chunk. Restart marks unfinished sessions interrupted and discloses that pending in-memory audio was lost. The uncommitted interval may be longer than one chunk if processing was behind. Corrupt/unknown records produce a visible storage error; they are not replaced or moved aside.

The existing SwiftData models and schema are unchanged. Meetings never enter dictation history, apply Dictionary/Snippets, capture a paste target or paste into another app.

**Save meeting transcripts** can be disabled. Unsaved text is available only in this app launch; export it before quitting. Transcript retention is independent of dictation history. Keep transcripts until deletion or expire them 24 hours after completion. Retention runs at launch and while idle in the running app, not while it is closed. Existing sessions retain their original policy.

**Keep meeting audio** is a separate opt-in. It writes processed source chunks as 16 kHz mono PCM WAV files in the session’s `Audio` directory. Filenames contain source and approximate timeline start in milliseconds. This is an auditable set of chunks, not a synchronized playback UI or a continuous recording guarantee. Backpressure gaps are absent from the audio as well. Choose 1, 7 or 30 days. Delete audio separately or delete the entire meeting. If transcript saving is off but audio retention is on, only session metadata/notices and audio are stored; text is omitted from disk. No audio is uploaded.

Select a transcript to **Export transcript…** as timestamped Markdown, or **Delete…** to remove its managed files. Exported files are separate copies. A storage failure leaves the partial text in memory and asks you to export before quitting. No audio recovery is promised when retention was off.

## Apple Calendar

Calendar integration defaults to **Off**; no calendar access request occurs until enabling Suggest or Auto-start. EventKit requires **Full Access** to read event details on macOS 14+. Flowtype only reads; it does not create/edit/delete events or contact participants. Choose calendars explicitly (none selected by default). All-day/cancelled events are excluded. Optionally require recognized conferencing links, attendees, or both. With both filters off, every timed event in selected calendars qualifies. Recognition of conferencing URLs is heuristic.

**Suggest** shows a Start/Skip banner in Meetings at the chosen lead time and opens the window. It never starts capture without Start. No notification authorization is used.

**Auto-start** is a deliberate opt-in. It requires a successful manual capture of non-silent system audio and microphone buffers using the same preferences in the **current app launch**, so launching/restarting Flowtype never immediately records an unchecked source. It announces capture by opening Meetings and showing the menu indicator. Automatic preparation does not download missing speech models; prepare them manually first. Use Stop to skip an active automatic capture. OS permissions can be revoked after a source check; tap/start failures or missing callbacks stop the session and are disclosed. Verify permissions before enabling auto-start.

The scheduler polls every 15 seconds and refreshes on EventKit changes/wake. It uses absolute event dates (time-zone independent), stable series/occurrence identifiers hashed with SHA-256, and persisted claim times. Non-recurring moves retain one identity; recurring instances use the original occurrence date. Separate recurring instances can trigger separately; each claimed occurrence is handled at most once within the 90-day deduplication window. No event title, attendee, meeting URL or notes are saved. Calendar IDs and display names exist in settings/UI; only calendar IDs are persisted.

Overlaps are skipped while busy or while a suggestion is pending. Cancelled/moved suggestions are revalidated before Start. Missed events after launch/sleep are skipped rather than recorded retrospectively; the wake/launch grace window is 15 seconds. Active scheduled captures stop at event end/cancellation/move by default. You may turn that behavior off; every capture still stops at the configured maximum (default 120 minutes, maximum 480). Sleep always stops capture. A manual capture has no calendar auto-stop. No auto-joining calls.

## Keyboard and Shortcuts / Control Center

Command + Fn is intentionally **not supported**. Bare-Fn dictation starts on Fn-down; reliable coexistence would require arbitration of both modifier orders and testing real hardware, secure input and system shortcuts. Merely parsing a chord would risk brief dictation. Existing Fn handling is unchanged. The standard configurable Carbon chord works without requiring an Fn event from an external keyboard. Conflicts with dictation/paste-last shortcuts are rejected. Registration conflicts with another app are surfaced. Secure input and OS-reserved shortcuts may still prevent global delivery; use the menu controls.

Start/Stop Meeting Capture App Intents call the capture controller (not just open the app) and are exposed through an AppShortcutsProvider. They open Flowtype so the recording state and permission failures remain visible. Apple’s Shortcuts app can use these actions. macOS versions that support running a user Shortcut from Control Center may expose a user-created Shortcut there. **No native Control Center widget/extension or synchronized control state is shipped.** Discovery and Control Center execution require testing a signed, installed build in the user’s Shortcuts/Control Center UI. The unsigned validation build is not proof of that integration.

## API references

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [Apple: SpeechAnalyzer (including simultaneous resource limits)](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)

See `MEETINGS-VALIDATION.md` for actual validation and outstanding hardware checks.
