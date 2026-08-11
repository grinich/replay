<p align="center">
  <img src="Resources/AppIcon-1024.png" width="144" height="144" alt="Replay app icon">
</p>

<h1 align="center">Replay</h1>

<p align="center">
  A beautiful offline video queue for macOS.<br>
  Paste a link, let it download, and watch without the surrounding website.
</p>

<p align="center">
  <a href="https://github.com/grinich/replay/releases/latest/download/Replay-macOS.zip"><strong>Download the latest macOS build</strong></a>
  ·
  <a href="https://github.com/grinich/replay/releases">All releases</a>
</p>

<p align="center">
  <a href="https://github.com/grinich/replay/actions/workflows/ci.yml"><img src="https://github.com/grinich/replay/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/grinich/replay/releases/latest"><img src="https://img.shields.io/github/v/release/grinich/replay" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

## Screenshots

<p align="center">
  <a href="docs/images/replay-player.png"><img src="docs/images/replay-player.png" width="49%" alt="Replay playing a video with the offline queue and chapter timeline visible"></a>
  <a href="docs/images/replay-chapters.png"><img src="docs/images/replay-chapters.png" width="49%" alt="Replay playing a video with the chapter sidebar expanded"></a>
</p>

## Install

1. [Download the latest build](https://github.com/grinich/replay/releases/latest/download/Replay-macOS.zip).
2. Unzip it and move **Replay.app** into Applications.
3. Because the open-source build is not yet Apple-notarized, Control-click the app and choose **Open** the first time.

The release is universal for Apple silicon and Intel Macs and includes yt-dlp, ffmpeg, and Deno. No Homebrew setup is required. Replay requires macOS 13 or newer.

## Add something to watch

- Copy any block of text containing one or many links, bring Replay forward, and press **Command-V**.
- Paste into the field at the top of the queue.
- Drag a URL, `.webloc`, or `.url` file onto the app window or its Dock icon.

New items download in the background and are stored locally for offline playback. YouTube and X are the main targets, and other non-DRM sites supported by yt-dlp may work too.

## Highlights

- Offline playback with a focused, distraction-free native player
- Persistent resume position, playback speed, volume, subtitles, and chapter-pane state
- YouTube creator chapters displayed in the timeline and a collapsible chapter inspector
- Offline English subtitles when creator or automatic captions are available
- Queue reordering, inline renaming, watched archive, thumbnails, and batch URL extraction
- 10-second seek controls, keyboard shortcuts, media-key support, fullscreen, AirPlay, and a compact background player
- Automatic retry after transient network failures and pause-on-Low-Power-Mode behavior
- No autoplay after a download or relaunch

## Keyboard and trackpad

| Input | Action |
| --- | --- |
| `Command-V` | Add every URL on the clipboard |
| `Space` | Play or pause |
| `Left` / `Right` | Skip backward or forward 10 seconds |
| `Up` / `Down` | Change playback speed by 0.1× |
| `F` | Toggle video fullscreen |
| Vertical scroll over video | Change volume |

## Why Deno is included

YouTube presents JavaScript challenges that yt-dlp needs to evaluate to discover the complete set of playable formats. Deno is yt-dlp's recommended restricted JavaScript runtime for that job. It is not used to render the app UI and is only launched by yt-dlp while resolving supported videos.

The release also bundles a portable ffmpeg build for merging separate video and audio streams, thumbnail conversion, and subtitle conversion. The runtime tools and their license notices live inside the app at `Contents/Resources`.

## Data and privacy

- Downloaded media: `~/Movies/Replay`
- Queue metadata: `~/Library/Application Support/Replay/queue.json`
- No analytics, accounts, or cloud sync
- No browser-cookie import
- No DRM decryption

Use Replay only for media you are authorized to download. Site terms and copyright rules still apply.

## Build from source

```sh
git clone https://github.com/grinich/replay.git
cd replay
./scripts/build_app.sh
./scripts/test.sh
```

The development build is written to `dist/Replay.app`. It uses bundled runtime tools when supplied by the release packager, then falls back to Homebrew paths for local development:

```sh
brew install yt-dlp ffmpeg deno
```

To create the same self-contained universal archive published on GitHub:

```sh
./scripts/package_release.sh
```

The first packaging run downloads checksum-verified yt-dlp and Deno release binaries and builds a portable LGPL ffmpeg from official source. Subsequent builds reuse the cached runtime artifacts under `.build`.

## Release workflow

`main` is built and tested by GitHub Actions. A tag matching the version in `Resources/Info.plist`, such as `v0.4.0`, triggers the release workflow, which:

1. Builds arm64 and x86_64 app binaries and combines them into a universal app.
2. Bundles universal yt-dlp, ffmpeg, and Deno runtimes plus license notices.
3. Verifies the app signature and runtime executables.
4. Publishes `Replay-macOS.zip` and its SHA-256 checksum to GitHub Releases.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and release details.

## License

Replay is available under the [MIT License](LICENSE). Bundled runtime components retain their respective upstream licenses.
