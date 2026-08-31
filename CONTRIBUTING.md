# Contributing

Thanks for helping improve Replay.

## Local setup

Replay requires macOS 13 or newer and Swift 5.9 or newer.

```sh
git clone https://github.com/grinich/replay.git
cd replay
./scripts/build_app.sh
./scripts/test.sh
```

Development builds use `yt-dlp`, `ffmpeg`, and optionally `deno` from the app bundle first, then fall back to Homebrew locations. Install local copies with:

```sh
brew install yt-dlp ffmpeg deno
```

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Run `swift build -c release` and `./scripts/test.sh` before opening a pull request.
- Do not commit downloaded media, app bundles, or files from `.build`.

## Releases

The version comes from `Resources/Info.plist`. To publish a release, update both bundle version fields and push a matching `v*` tag. GitHub Actions imports the Developer ID certificate, builds the universal self-contained app, notarizes and staples the app and DMG, and publishes both `Replay.dmg` and the updater's `Replay-macOS.zip` with SHA-256 checksums.

The release workflow requires these repository secrets:

- `DEVELOPER_ID_P12_BASE64`: password-protected Developer ID Application identity exported as a `.p12`, then base64 encoded
- `DEVELOPER_ID_P12_PASSWORD`: password used when exporting the `.p12`
- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_API_KEY_ID`: App Store Connect team API key identifier
- `APPLE_API_ISSUER_ID`: App Store Connect API issuer identifier
- `APPLE_API_PRIVATE_KEY_BASE64`: base64-encoded `.p8` private key for notarization
