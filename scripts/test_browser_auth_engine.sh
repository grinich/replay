#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
app_dir="$scratch_dir/BrowserAuthEngineCheck.app"
tools_dir="$app_dir/Contents/Resources/Tools"
mkdir -p "$app_dir/Contents/MacOS" "$tools_dir" "$scratch_dir/home/Library" "$scratch_dir/calls"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mg.replay.tests.browser-auth-engine</string>
<key>CFBundleExecutable</key><string>BrowserAuthEngineCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# These fixtures only inspect argv and create tiny local files. No real
# downloader, browser process, browser database, or network request is used.
cat > "$tools_dir/yt-dlp" <<'FAKE'
#!/bin/bash
set -euo pipefail
call_file=$(/usr/bin/mktemp "$REPLAY_AUTH_CHECK_ROOT/calls/call.XXXXXX")
printf '%s\0' "$@" > "$call_file"
paths=""
output=""
skip_download=false
thumbnail=false
subtitle=false
preview=false
resolver=false
source=""
while (($#)); do
    case "$1" in
        --paths) paths="$2"; shift ;;
        --output) output="$2"; shift ;;
        --skip-download) skip_download=true ;;
        --write-thumbnail) thumbnail=true ;;
        --write-subs) subtitle=true ;;
        --get-url) resolver=true ;;
        --print) [[ "$2" == WL_PREVIEW* ]] && preview=true; shift ;;
        http://*|https://*) source="$1" ;;
    esac
    shift
done
if [[ "$source" == *fail-auth00* ]]; then
    printf '%s\n' "ERROR: [youtube] Sign in to confirm you're not a bot." >&2
    exit 1
fi
if $resolver; then
    printf '%s\n' 'https://fixture.invalid/progressive.mp4'
    exit 0
fi
if $preview; then
    printf 'WL_PREVIEW\t"Offline fixture"\t"Replay test"\t12\tnull\n'
    exit 0
fi
if [[ -n "$output" ]]; then
    prefix="${output%%.*}"
    $thumbnail && : > "$paths/$prefix.jpg"
    $subtitle && printf '1\n00:00:00,000 --> 00:00:01,000\nFixture\n' > "$paths/$prefix.en.srt"
    if ! $skip_download; then
        : > "$paths/$prefix.mp4"
        printf 'WL_META\t"Offline fixture"\t"Replay test"\t12\t[]\n'
        printf 'WL_PROGRESS\t50%%\t1KiB/s\t00:01\n'
        printf 'WL_DONE\t"%s"\t"Offline fixture"\t"Replay test"\t12\t[]\n' "$paths/$prefix.mp4"
    fi
else
    printf 'WL_META\t"Offline fixture"\t"Replay test"\t12\t[]\n'
fi
FAKE
cat > "$tools_dir/ffmpeg" <<'FAKE'
#!/bin/bash
# yt-dlp fixture creates converted sidecars itself; executing ffmpeg is a bug.
exit 99
FAKE
cp "$tools_dir/ffmpeg" "$tools_dir/deno"
chmod +x "$tools_dir/yt-dlp" "$tools_dir/ffmpeg" "$tools_dir/deno"

swiftc -module-cache-path "$scratch_dir/module-cache" \
    "$project_dir/Sources/Replay/WatchItem.swift" \
    "$project_dir/Sources/Replay/ChapterMetadata.swift" \
    "$project_dir/Sources/Replay/URLIntake.swift" \
    "$project_dir/Sources/Replay/YouTubePreview.swift" \
    "$project_dir/Sources/Replay/DownloadAuthentication.swift" \
    "$project_dir/Sources/Replay/DownloadEngine.swift" \
    "$project_dir/tools/browser_auth_engine_check.swift" \
    -o "$app_dir/Contents/MacOS/BrowserAuthEngineCheck"

# Foundation's user directory override keeps even download logs in this fixture.
# The Swift check verifies isolation before calling any DownloadEngine method.
CFFIXED_USER_HOME="$scratch_dir/home" REPLAY_AUTH_CHECK_ROOT="$scratch_dir" \
    "$app_dir/Contents/MacOS/BrowserAuthEngineCheck"
