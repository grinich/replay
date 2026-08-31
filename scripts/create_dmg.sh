#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_name="Replay"
volume_name="Replay"
app_path="${1:-$project_dir/dist/$app_name.app}"
output_dmg="${2:-$project_dir/dist/$app_name.dmg}"
background_path="$project_dir/Resources/DMG/background.tiff"
staging_dir="$project_dir/.build/dmg-staging"
rw_dmg="$project_dir/.build/$app_name-rw.dmg"
mount_dir="$project_dir/.build/dmg-mount"
mounted=0

cleanup() {
    if [[ "$mounted" == "1" ]]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    rm -rf "$staging_dir" "$rw_dmg" "$mount_dir"
}
trap cleanup EXIT

if [[ ! -d "$app_path" ]]; then
    echo "Missing app bundle: $app_path" >&2
    exit 1
fi

if [[ ! -f "$background_path" ]]; then
    echo "Missing DMG background: $background_path" >&2
    exit 1
fi

rm -rf "$staging_dir" "$rw_dmg" "$output_dmg" "$mount_dir"
mkdir -p "$staging_dir/.background" "$mount_dir"

ditto "$app_path" "$staging_dir/$app_name.app"
ln -s /Applications "$staging_dir/Applications"
cp "$background_path" "$staging_dir/.background/background.tiff"

hdiutil create \
    -quiet \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -format UDRW \
    -fs HFS+ \
    "$rw_dmg"

hdiutil attach \
    -quiet \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$mount_dir" \
    "$rw_dmg"
mounted=1

chflags hidden "$mount_dir/.background" || true
SetFile -a V "$mount_dir/.background" 2>/dev/null || true

osascript - "$mount_dir" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set mountedFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/background.tiff") as alias

    tell application "Finder"
        open mountedFolder
        set dmgWindow to container window of mountedFolder
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set bounds of dmgWindow to {100, 100, 760, 500}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to backgroundFile

        set position of item "Replay.app" of mountedFolder to {180, 200}
        set position of item "Applications" of mountedFolder to {480, 200}

        close dmgWindow
        open mountedFolder
        update mountedFolder without registering applications
        delay 1
    end tell
end run
APPLESCRIPT

sync
sleep 1
hdiutil detach "$mount_dir" -quiet
mounted=0

hdiutil convert \
    "$rw_dmg" \
    -quiet \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$output_dmg"

printf '%s\n' "$output_dmg"
