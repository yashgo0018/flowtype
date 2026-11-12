# Meeting transcription validation

Date: November 12, 2026. Checkout began clean on `main` at `0a239a8` (Flowtype 0.3.0). The initial implementation was left uncommitted; the later user-requested retrospective commit checkpoints are documented below. No pushes, PRs or messages to others were made. The prompt referenced `SECURITY-REVIEW.md`, but that file was not attached or present locally.

## Environment and commands

- Apple Silicon (`arm64`), macOS 26.7.3 (25G342).
- Xcode 27.2 (27B52), SDK macOS 27.2, Swift 6.4.2.
- Both production sources and tests were compiled with a **macOS 14 deployment target** through a temporary SwiftPM package using the repository’s exact lockfile: WhisperKit/argmax-oss-swift 0.18.0, Sparkle 2.10.0 and its pinned transitive dependencies. This is not a signed distribution-build validation.

The requested Xcode command was attempted:

```sh
xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype -destination 'platform=macOS,arch=arm64'
```

The initial attempts failed before compilation: `IDESimulatorFoundation` cannot load a required symbol from `/Library/Developer/PrivateFrameworks/DVTDownloads.framework`. Xcode reports a required plug-in failure and suggests `xcodebuild -runFirstLaunch`. An initial attempt with `-derivedDataPath /tmp/flowtype-meetings-build CODE_SIGNING_ALLOWED=NO` failed the same way. The initial implementation did not change global Xcode setup or signing configuration. See the guided follow-up below.

The fallback used this exact test command against a temporary package with symlinks to the checked-out Swift sources/tests and the original Package.resolved:

```sh
FLOWTYPE_SCREENSHOTS_DIR=/tmp/flowtype-meeting-screenshots \
CLANG_MODULE_CACHE_PATH=/tmp/flowtype-validation/module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/flowtype-validation/module-cache \
swift test --package-path /tmp/flowtype-validation \
  --cache-path /tmp/flowtype-validation/cache \
  --config-path /tmp/flowtype-validation/config \
  --security-path /tmp/flowtype-validation/security \
  --disable-sandbox --disable-keychain
```

To reproduce the same source/dependency compilation and test approach in a fresh temporary directory:

```sh
scripts/test-with-swiftpm.sh
# Optional visual outputs (uses only sample data):
FLOWTYPE_SCREENSHOTS_DIR=/tmp/flowtype-meeting-screenshots scripts/test-with-swiftpm.sh
```

The script requires network access for existing package dependencies. Apple integration tests use synthesized speech, not microphone/system capture. Installed Apple assets may require preparation/download. Screenshot tests are skipped unless the directory variable is set. Temporary build/package caches are deleted by the script after completion.

## Verified automatically

- Complete existing regression suite plus meeting state, source, storage and calendar tests. Final result recorded below.
- Duplicate starts, mutual exclusion with dictation/model preparation, start cancellation, stop/finalization, cancellation of pending transcription, and partial results on model/device/storage failures.
- A fake paste service confirms meetings never capture a paste target, insert text or become the dictation paste-last transcript. Groq dictation settings cannot select a cloud meeting engine.
- Bounded queue under a simulated **two-hour, two-source stalled consumer**. This verifies PCM bounds and visible backpressure notices, not real-time quality, process RSS or two-hour hardware behavior.
- 44.1 kHz and 48 kHz stereo test buffers convert independently to 16 kHz mono with aligned duration; overlapping source times and clock discontinuities are preserved/disclosed; stop flushes partial chunks.
- Transcript/audio opt-in, private directory/file permissions, retention, deletion, recovery markers, corrupt-store preservation. Testing found that `completeFileProtectionUnlessOpen` could make freshly written files unreadable; it was removed. The final implementation uses private file permissions and atomic writes.
- A **real on-disk store fixture** containing the unchanged pre-feature SwiftData schema and all six original model types was created, copied (including WAL/SHM when present), and reopened directly. Original text, snippets, notes, vocabulary, usage and category data survived. `NativeSchema.makeContainer()` fallback was never used. No personal existing store was read or modified; no schema migration is introduced.
- Calendar fake covers off/denied modes, selected calendars, attendees/link filters, all-day/cancelled events, distinct recurring occurrence IDs, deduplication across restart, moved/cancelled suggestions, overlaps, time-zone-equivalent dates and missed-on-wake behavior. Verified-source automatic capture passes `allowDownload: false`, starts once and stops when cancelled or calendar authorization is revoked.
- Standard shortcut aliases/conflicts, press-repeat-release latch, and rejection of Command+Fn in both modifier orders. These are software tests, not physical keyboard delivery tests.
- **Real Apple Speech recognition of synthesized audio** passed for the existing dictation path and meeting final results/source/timestamp offsets. No microphone or system-audio permission was requested for these tests.
- Meetings and Settings views rendered using sample data. Images were inspected after correcting transparent screenshot backgrounds; the saved session, source-labelled transcript and export/delete controls are visible. This is not a VoiceOver audit or a test of actual capture controls.
- Project/plist syntax and `git diff --check` pass.

## Requires interactive hardware / signed application verification

These broader checks have **not** been claimed as passed in full. The short user-operated capture and follow-up export/relaunch checks reported below cover parts of items 1 and 7:

1. Grant Microphone and System Audio Recording access in a normally signed/installed app. With headphones and consent, capture known microphone and system playback separately, then together. Check labels, relative timestamps, recording indicators, stop/finalization, transcript export and optional WAV chunks. Test denial/revocation, silent playback, input/output changes and unavailable selected devices.
2. Perform a long real recording. Measure process RSS (model memory is separate from bounded PCM), recognition quality, chunk-boundary loss and processing speed. Interrupt with sleep/forced quit and confirm partial recovery/lost-audio disclosure. Check disk-full behavior on a disposable volume; automated tests inject storage failure, not a physically full disk.
3. Test actual Whisper recognition on macOS 14.2/15 with a local model present, and both engines without network after installation. Deployment-target compilation and a real Apple engine test do not prove older-OS runtime behavior or Whisper model quality.
4. Use a disposable Calendar event to verify EventKit permission prompts/denial, chosen calendars, suggest and auto-start, event moves/cancellation/recurrence, wake and revocation. Auto-start requires manual source verification with the current preferences in this app launch. No real Calendar access was requested in tests.
5. Verify the configurable regular chord on the user’s keyboard, including secure input and OS/app shortcut conflicts. Command+Fn is deliberately unavailable; no physical chord reliability claim is made. Existing Fn dictation handling is unchanged.
6. Verify Start/Stop actions are discovered in Shortcuts from a signed installed build and actually reach the live controller. No native Control Center widget/extension ships. macOS versions offering a Control Center user-Shortcut control may run these actions, but that route/state display is unverified. No signing/distribution changes were introduced for an extension.
7. Test VoiceOver focus/announcement, keyboard-only navigation, window sizing and retention behavior across a real app relaunch. Export/deletion service behavior is tested; native save-panel interaction is not automated.

## Final automated result

**73 XCTest tests passed, 0 failures, 0 skipped**, in 30.074 seconds of test execution (30.098 seconds including suite overhead). This run included both optional screenshot tests and both real Apple Speech tests. Before first-launch setup was completed, the Xcode retry outside the sandbox exited 70 with the same plug-in failure.

Local session logs: `/tmp/flowtype-final-tests.log`, `/tmp/flowtype-xcode-final.log`; sample-data view captures: `/tmp/flowtype-meeting-screenshots/meetings.png` and `meeting-settings.png`. These temporary outputs may be removed by the OS.


## Guided follow-up: Xcode setup resolved

Xcode’s required system components were installed through its **Install Required** dialog. `xcodebuild -checkFirstLaunchStatus` now exits 0, and this project test command completed successfully:

```sh
xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/flowtype-xcode-build CODE_SIGNING_ALLOWED=NO
```

The xcresult summary reports **73 total tests: 71 passed, 2 optional screenshot tests skipped, 0 failures**, with no runtime warnings. Result bundle: `/tmp/flowtype-xcode-build/Logs/Test/Test-Flowtype-2026.11.12_22-33-33-+0400.xcresult`; build log: `/tmp/flowtype-xcode-guided.log`.

A separate temporary manual-test copy was prepared at `/tmp/flowtype-manual.iIN4q4/Flowtype.app`, with its embedded XCTest bundle removed and the app/Sparkle copy signed ad hoc for local use. `codesign --verify --deep --strict` passed. This does not validate Developer ID signing, notarization, distribution, or Shortcuts discovery. The app was launched and its Meetings screen verified visible. No microphone/system-audio recording was started by the agent; the next test requires the user to start capture and grant the native permissions.

## Guided capture crash: callback isolation corrected

The first user-initiated recording crashed with `EXC_BREAKPOINT` on AVFoundation’s `RealtimeMessenger.mServiceQueue`. The symbolicated frame was the microphone callback inside `MeetingCapture.start`, following Swift’s executor-isolation check. The callback had been created in the `@MainActor` capture method and incorrectly inherited main-actor isolation. The callback entered on AVFoundation’s background audio queue. The original tests exercised converters and controller fakes but did not invoke the registered callback blocks off the main actor.

Both microphone and Core Audio callback blocks now come from explicit `nonisolated` factories with `@Sendable` closures. They capture only the per-source converter, the synchronized bounded inbox and a timeline origin. They do not access the main-actor controller. The system-buffer wrapper lives in the source-confined converter so the raw buffer is consumed synchronously within its callback lifetime.

Two added regression tests create the production callback blocks from a main-actor test and invoke them on separate serial background queues using synthetic stereo PCM. Both pass with source labels, durations and timestamp offsets checked. They use no microphone or system capture permissions. These tests are not a claim of verified hardware capture.

Full Xcode regression run after this correction: **75 total tests, 73 passed, 2 optional screenshot tests skipped, 0 failures, no runtime warnings**. Command unchanged from the guided Xcode run above. Log: `/tmp/flowtype-crash-fix-tests.log`; xcresult: `/tmp/flowtype-xcode-build/Logs/Test/Test-Flowtype-2026.11.12_22-45-01-+0400.xcresult`.

The local manual-test app at `/tmp/flowtype-manual.iIN4q4/Flowtype.app` was replaced with the rebuilt, ad-hoc-signed copy and its deep/strict signature verification passed. It was reopened on Meetings without starting capture. The interrupted session was visibly recovered with an explicit pending-audio-loss notice and no transcript text. A fresh user-initiated capture is still required to verify the physical input/tap path after this fix. Local permission prompts may recur when the ad-hoc build’s code signature changes.

## Guided permission recovery: install location corrected

The user encountered a microphone prompt that remained open after clicking Allow. It outlived the requesting app instance. The user manually force-quit UserNotificationCenter to dismiss it. The next capture attempt immediately reported unavailable microphone access without a new prompt, and Flowtype was absent from the Microphone list in System Settings. Privacy-service logs explicitly reported that no Application URL could be found for `studio.infinitumlabs.flowtype`, although Launch Services contained records for the temporary app copies. A scoped microphone reset at the temporary location had failed with bundle-not-found; it changed no permissions.

The idle app was quit, and the same signed local test build was copied to `~/Applications/Flowtype.app` (no pre-existing copy was overwritten). Deep/strict code signature verification passed. After registering that copy, `tccutil reset Microphone studio.infinitumlabs.flowtype` succeeded. Only Flowtype’s microphone decision was reset; access was not granted and other apps’ decisions were not reset. The installed copy reopened with an Allow button for Microphone instead of Open Settings. A fresh user grant and physical microphone/system-audio test remain pending. The app is still ad hoc signed; this is not distribution-signing validation.

## User-operated short capture succeeded

The user subsequently reported success and supplied a screenshot taken at 23:22 on November 12. It shows a session started at 23:21 with status **Completed**, Apple Speech on device, timestamped **System audio** results and a separate **You** microphone result. This is the first observed successful short two-source capture and finalization after the callback and installation-location corrections. No crash was reported for this run. An earlier same-minute session shows “No transcript — review capture notices”; its notices report that system audio stopped delivering buffers at 12 seconds and no audible system audio or speech transcript was detected. The reason that source was unavailable on the earlier attempt is not established.

The completed session was exported through the actual Export transcript button and native save panel to a unique temporary folder. The 471-byte UTF-8 Markdown file was checked for the correct session start/status, two system-audio segments, one microphone segment and timestamps. Flowtype was then quit (confirmed no longer running), relaunched from `~/Applications/Flowtype.app`, and the same completed transcript was visible with all three segments and timestamps intact. The Home view also showed Microphone granted after relaunch. Local test export: `/tmp/flowtype-export-check.4WD3F3/Meeting-export-check.md`; its speech text was not copied into this repository.

This evidence does not establish long-duration stability, transcription accuracy, timestamp accuracy or the remaining hardware/permission test matrix. The sidebar’s “Setup needed” status belongs to the dictation setup checks; the relaunched Home view showed Accessibility still awaiting a grant. Meeting capture does not require that access.

## Retrospective red, green and refactor commit checkpoints

The user requested separate failing-test, green-implementation and green-refactor commits after implementation and the interactive capture check. This sequence is reconstructed retrospectively; it does not claim that the existing feature was originally developed test-first. A copy and SHA-256 manifest of every previously changed/new file were preserved outside the checkout before creating the local `codex/meeting-transcription` branch.

The red commit `aeca808` contains only five new tests in the existing SettingsStoreTests file. They exercise meeting shortcut registration, canonicalization/persistence, invalid/disabled settings and conflicts through pre-existing settings APIs. An isolated export of original revision `0a239a8`, plus exactly this test-file change, compiled successfully and ran **8 settings tests: 3 failed, 5 passed**. Failures were assertions for the absent meeting binding and unhandled stored meeting settings, not compilation failures. No production change is included in that commit. The existing working feature was preserved in the main checkout throughout.

The green commit `bd6c18e` includes the existing complete meeting implementation, its previously written regression tests, documentation and test script. The full native suite ran with the five new settings tests: **80 total, 78 passed, 2 optional screenshot tests skipped, 0 failures, no runtime warnings**. The original 26 changed/new feature files still matched the preserved snapshot before adding these checkpoint notes. The extensive meeting tests enter with the implementation; they are not represented as having been committed before it.

Commands used the same Xcode project/scheme, Apple Silicon destination, `/tmp/flowtype-xcode-build` derived data and `CODE_SIGNING_ALLOWED=NO`, with `-disableAutomaticPackageResolution`. The red run additionally selected `-only-testing:FlowtypeTests/SettingsStoreTests`. Logs: `/tmp/flowtype-tdd-red-tests.log` (exit 65) and `/tmp/flowtype-tdd-green-tests.log` (exit 0). Result bundles: `Test-Flowtype-2026.11.12_23-36-19-+0400.xcresult` and `Test-Flowtype-2026.11.12_23-37-30-+0400.xcresult` under the derived data’s `Logs/Test` directory.

After the green commit, the refactor extracted a shared nonisolated callback timestamp conversion and a named meeting-shortcut loading helper/key. Missing preferences still use the default, invalid/empty preferences still disable the binding, and both callbacks retain their host-time/uptime fallback and source separation. No test assertions or expected values were changed for this step. The full native suite passed again: **80 total, 78 passed, 2 optional screenshot tests skipped, 0 failures, no runtime warnings**. Log: `/tmp/flowtype-tdd-refactor-tests.log` (exit 0); result bundle: `Test-Flowtype-2026.11.12_23-39-19-+0400.xcresult`. The installed manual-test app was not replaced with a newly signed copy during this Git checkpoint work; no new hardware capture was claimed for the refactor.

All three commits use `simon+agent@schmid.io` for author and committer and are unsigned. They remain local on `codex/meeting-transcription`.
