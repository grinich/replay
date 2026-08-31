#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_tools_dir=$("$project_dir/scripts/prepare_runtime_tools.sh" | tail -1)
signing_identity="${REPLAY_SIGNING_IDENTITY:--}"
notarize="${REPLAY_NOTARIZE:-0}"
notary_profile="${REPLAY_NOTARY_PROFILE:-}"
notary_keychain="${REPLAY_NOTARY_KEYCHAIN:-}"

if [[ "$notarize" == "1" ]]; then
    if [[ "$signing_identity" == "-" || -z "$notary_profile" ]]; then
        echo "REPLAY_NOTARIZE=1 requires REPLAY_SIGNING_IDENTITY and REPLAY_NOTARY_PROFILE." >&2
        exit 1
    fi
fi

REPLAY_UNIVERSAL=1 \
REPLAY_BUNDLED_TOOLS_DIR="$runtime_tools_dir" \
REPLAY_SIGNING_IDENTITY="$signing_identity" \
    "$project_dir/scripts/build_app.sh"

archive="$project_dir/dist/Replay-macOS.zip"
checksum="$archive.sha256"
notary_archive="$project_dir/.build/Replay-notarization.zip"
dmg="$project_dir/dist/Replay.dmg"
dmg_checksum="$dmg.sha256"
rm -f "$archive" "$checksum" "$notary_archive" "$dmg" "$dmg_checksum"

notary_args=(--keychain-profile "$notary_profile")
if [[ -n "$notary_keychain" ]]; then
    notary_args+=(--keychain "$notary_keychain")
fi

if [[ "$notarize" == "1" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$project_dir/dist/Replay.app" "$notary_archive"
    xcrun notarytool submit "$notary_archive" "${notary_args[@]}" --wait --timeout 45m
    xcrun stapler staple "$project_dir/dist/Replay.app"
    xcrun stapler validate "$project_dir/dist/Replay.app"
    spctl --assess --type execute --verbose=2 "$project_dir/dist/Replay.app"
fi

ditto -c -k --sequesterRsrc --keepParent "$project_dir/dist/Replay.app" "$archive"
(
    cd "$(dirname "$archive")"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
)

"$project_dir/scripts/create_dmg.sh" "$project_dir/dist/Replay.app" "$dmg"

if [[ "$signing_identity" != "-" ]]; then
    codesign --force --sign "$signing_identity" --timestamp "$dmg"
fi

if [[ "$notarize" == "1" ]]; then
    xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --timeout 45m
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

hdiutil verify "$dmg"
(
    cd "$(dirname "$dmg")"
    shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg_checksum")"
)

printf '%s\n%s\n%s\n%s\n' "$archive" "$checksum" "$dmg" "$dmg_checksum"
