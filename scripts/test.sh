#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

compile_and_run() {
    local name="$1"
    shift
    swiftc "$@" -o "$scratch_dir/$name"
    "$scratch_dir/$name"
}

compile_and_run url_intake \
    "$project_dir/Sources/WatchLater/URLIntake.swift" \
    "$project_dir/tools/url_intake_check.swift"

compile_and_run retry_policy \
    "$project_dir/Sources/WatchLater/DownloadRetryPolicy.swift" \
    "$project_dir/tools/retry_policy_check.swift"

compile_and_run resume_model \
    "$project_dir/Sources/WatchLater/WatchItem.swift" \
    "$project_dir/Sources/WatchLater/ChapterMetadata.swift" \
    "$project_dir/tools/resume_model_check.swift"

compile_and_run subtitle_parser \
    "$project_dir/Sources/WatchLater/VideoSubtitles.swift" \
    "$project_dir/tools/subtitle_parser_check.swift"

compile_and_run power_mode \
    "$project_dir/Sources/WatchLater/PowerModeMonitor.swift" \
    "$project_dir/tools/power_mode_check.swift"

compile_and_run playback_command \
    "$project_dir/Sources/WatchLater/LocalVideoPlayer.swift" \
    "$project_dir/tools/playback_command_check.swift"

compile_and_run activation_click \
    "$project_dir/Sources/WatchLater/VisualStyle.swift" \
    "$project_dir/tools/activation_click_check.swift"
