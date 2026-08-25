#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/dist/Replay.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
macos_dir="$contents_dir/MacOS"
helpers_dir="$contents_dir/Helpers"
iconset_dir="$project_dir/.build/Replay.iconset"
bundled_tools_dir="${REPLAY_BUNDLED_TOOLS_DIR:-}"

if [[ "${REPLAY_UNIVERSAL:-0}" == "1" ]]; then
    arm_build="$project_dir/.build/release-arm64"
    intel_build="$project_dir/.build/release-x86_64"
    swift build --package-path "$project_dir" --scratch-path "$arm_build" -c release --arch arm64 --product Replay
    swift build --package-path "$project_dir" --scratch-path "$arm_build" -c release --arch arm64 --product ReplayUpdater
    swift build --package-path "$project_dir" --scratch-path "$intel_build" -c release --arch x86_64 --product Replay
    swift build --package-path "$project_dir" --scratch-path "$intel_build" -c release --arch x86_64 --product ReplayUpdater
    arm_binary="$arm_build/arm64-apple-macosx/release/Replay"
    intel_binary="$intel_build/x86_64-apple-macosx/release/Replay"
    arm_updater_binary="$arm_build/arm64-apple-macosx/release/ReplayUpdater"
    intel_updater_binary="$intel_build/x86_64-apple-macosx/release/ReplayUpdater"
else
    swift build --package-path "$project_dir" -c release --product Replay
    swift build --package-path "$project_dir" -c release --product ReplayUpdater
    bin_dir=$(swift build --package-path "$project_dir" -c release --show-bin-path)
fi

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$helpers_dir" "$resources_dir" "$iconset_dir"
if [[ "${REPLAY_UNIVERSAL:-0}" == "1" ]]; then
    lipo -create "$arm_binary" "$intel_binary" -output "$macos_dir/Replay"
    lipo -create "$arm_updater_binary" "$intel_updater_binary" -output "$helpers_dir/ReplayUpdater"
else
    cp "$bin_dir/Replay" "$macos_dir/Replay"
    cp "$bin_dir/ReplayUpdater" "$helpers_dir/ReplayUpdater"
fi
chmod 755 "$helpers_dir/ReplayUpdater"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

sips -z 16 16 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_512x512.png" >/dev/null
cp "$project_dir/Resources/AppIcon-1024.png" "$iconset_dir/icon_512x512@2x.png"
iconutil -c icns "$iconset_dir" -o "$resources_dir/Replay.icns"

if [[ -n "$bundled_tools_dir" ]]; then
    test -x "$bundled_tools_dir/yt-dlp"
    test -x "$bundled_tools_dir/ffmpeg"
    test -x "$bundled_tools_dir/deno"
    mkdir -p "$resources_dir/Tools" "$resources_dir/Runtime Licenses"
    cp "$bundled_tools_dir/yt-dlp" "$resources_dir/Tools/yt-dlp"
    cp "$bundled_tools_dir/ffmpeg" "$resources_dir/Tools/ffmpeg"
    cp "$bundled_tools_dir/deno" "$resources_dir/Tools/deno"
    chmod 755 "$resources_dir/Tools/yt-dlp" "$resources_dir/Tools/ffmpeg" "$resources_dir/Tools/deno"
    if [[ -d "$bundled_tools_dir/licenses" ]]; then
        ditto "$bundled_tools_dir/licenses" "$resources_dir/Runtime Licenses"
    fi
fi

codesign --force --deep --sign - "$app_dir"
printf '%s\n' "$app_dir"
