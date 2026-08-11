# Contributing

Thanks for helping improve Rewatch.

## Local setup

Rewatch requires macOS 13 or newer and Swift 5.9 or newer.

```sh
git clone https://github.com/grinich/rewatch.git
cd rewatch
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

The version comes from `Resources/Info.plist`. To publish a release, update both bundle version fields and push a matching `v*` tag. GitHub Actions builds the universal, self-contained app and attaches `Rewatch-macOS.zip` plus its SHA-256 checksum to the release.
