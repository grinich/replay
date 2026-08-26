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
    "$project_dir/Sources/Replay/URLIntake.swift" \
    "$project_dir/tools/url_intake_check.swift"

compile_and_run retry_policy \
    "$project_dir/Sources/Replay/DownloadRetryPolicy.swift" \
    "$project_dir/tools/retry_policy_check.swift"

compile_and_run resume_model \
    "$project_dir/Sources/Replay/WatchItem.swift" \
    "$project_dir/Sources/Replay/ChapterMetadata.swift" \
    "$project_dir/tools/resume_model_check.swift"

compile_and_run subtitle_parser \
    "$project_dir/Sources/Replay/VideoSubtitles.swift" \
    "$project_dir/tools/subtitle_parser_check.swift"

compile_and_run chapter_enrichment \
    "$project_dir/Sources/Replay/WatchItem.swift" \
    "$project_dir/Sources/Replay/VideoSubtitles.swift" \
    "$project_dir/Sources/Replay/ChapterEnrichment.swift" \
    "$project_dir/tools/chapter_enrichment_check.swift"

compile_and_run power_mode \
    "$project_dir/Sources/Replay/PowerModeMonitor.swift" \
    "$project_dir/tools/power_mode_check.swift"

compile_and_run playback_command \
    "$project_dir/Sources/Replay/LocalVideoPlayer.swift" \
    "$project_dir/tools/playback_command_check.swift"

compile_and_run activation_click \
    "$project_dir/Sources/Replay/VisualStyle.swift" \
    "$project_dir/tools/activation_click_check.swift"

compile_and_run replay_migration \
    "$project_dir/Sources/Replay/ReplayMigration.swift" \
    "$project_dir/tools/replay_migration_check.swift"

compile_and_run update_version \
    "$project_dir/Sources/Replay/UpdateVersion.swift" \
    "$project_dir/tools/update_version_check.swift"

swiftc -parse-as-library \
    "$project_dir/Sources/Replay/UpdateVersion.swift" \
    "$project_dir/Sources/Replay/AppUpdater.swift" \
    "$project_dir/tools/updater_integration_check.swift" \
    -o "$scratch_dir/updater_integration"
"$scratch_dir/updater_integration"

swiftc "$project_dir/Sources/ReplayUpdater/main.swift" -o "$scratch_dir/ReplayUpdater"
swiftc "$project_dir/tools/updater_helper_check.swift" -o "$scratch_dir/updater_helper_check"
"$scratch_dir/updater_helper_check" "$scratch_dir/ReplayUpdater"
