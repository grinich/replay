#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_tools_dir=$("$project_dir/scripts/prepare_runtime_tools.sh" | tail -1)

REWATCH_UNIVERSAL=1 \
REWATCH_BUNDLED_TOOLS_DIR="$runtime_tools_dir" \
    "$project_dir/scripts/build_app.sh"

archive="$project_dir/dist/Rewatch-macOS.zip"
checksum="$archive.sha256"
rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$project_dir/dist/Rewatch.app" "$archive"
(
    cd "$(dirname "$archive")"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
)

printf '%s\n%s\n' "$archive" "$checksum"
