# Releasing Flowtype

Releases are signed with Developer ID, notarized by Apple, and published as a DMG on GitHub Releases. Installed copies update themselves with [Sparkle](https://sparkle-project.org), which reads `appcast.xml` from the latest release. The website links to `releases/latest/download/Flowtype.dmg`, so every release also uploads the DMG under that fixed name.

## One-time setup

1. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security → App-Specific Passwords), then run the command below. Leave out `--password` so you're prompted for it and it stays out of your shell history.
   ```bash
   xcrun notarytool store-credentials flowtype-notary --apple-id <you@example.com> --team-id HZHNBYQCWN
   ```
2. **Developer ID certificate.** In Xcode → Settings → Accounts → Manage Certificates, add a **Developer ID Application** certificate (Account Holder only). It signs the DMG. Back up its private key: in Keychain Access → My Certificates, export it as a password-protected `.p12`.
3. **Sparkle signing key.** It lives in the release machine's login keychain under the account `studio.infinitumlabs.flowtype`; its public half is `SUPublicEDKey` in `Flowtype/Info.plist`. Back it up, because without it existing installs can never be updated:
   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account studio.infinitumlabs.flowtype -x sparkle-private-key.txt
   ```
   Keep the file in a password manager, never in the repo.

## Each release

1. On `main`, bump `MARKETING_VERSION` in the project and commit. The build number comes from the git commit count.
2. Run `scripts/release.sh`. It archives, exports with Developer ID, notarizes and staples the app and the DMG, and writes `build/release/Flowtype-<version>.dmg` and `appcast.xml`. Notarization usually takes a few minutes.
   - If it's interrupted (network drop, Mac asleep), run `scripts/release.sh --resume`. It continues without rebuilding or resubmitting. While the Mac is locked the keychain is unavailable, so notarization checks pause until you unlock it.
3. Install from the DMG and test it.
4. Run `scripts/release.sh --publish`. It uploads exactly the files you tested, pushes `main` and the tag, and creates the GitHub release. It refuses if the code changed after the build or if you're not on `main`.

## Website and screenshots

The site in `docs/` is served by GitHub Pages from `main`. Preview it locally:

```bash
python3 -m http.server 4173 --directory docs
```

Screenshots are rendered from the real views with sample data. Regenerate them after UI changes:

```bash
TEST_RUNNER_FLOWTYPE_SCREENSHOTS_DIR="$PWD/docs/assets/screenshots" \
  xcodebuild test -project Flowtype.xcodeproj -scheme Flowtype \
  -destination 'platform=macOS,arch=arm64' -only-testing:FlowtypeTests/ScreenshotGenerator
```

The app icon is drawn by `scripts/render-icon.swift`:

```bash
swift scripts/render-icon.swift Flowtype/Assets.xcassets/AppIcon.appiconset
```
