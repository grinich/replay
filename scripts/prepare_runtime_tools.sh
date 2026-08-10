#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="$project_dir/.build/runtime-tools"
downloads_dir="$runtime_root/downloads"
source_dir="$runtime_root/source"
output_dir="$runtime_root/universal"

yt_dlp_version="2026.07.04"
deno_version="v2.9.5"
ffmpeg_version="8.1.1"

mkdir -p "$downloads_dir" "$source_dir" "$output_dir"
rm -rf "$output_dir/licenses"
mkdir -p "$output_dir/licenses"

download() {
    local url="$1"
    local destination="$2"
    if [[ ! -f "$destination" ]]; then
        local partial="$destination.partial"
        rm -f "$partial"
        curl \
            --fail \
            --location \
            --retry 8 \
            --retry-all-errors \
            --retry-delay 2 \
            --connect-timeout 30 \
            --max-time 600 \
            "$url" \
            --output "$partial"
        mv "$partial" "$destination"
    fi
}

verify_sha256_file() {
    local archive="$1"
    local checksum_file="$2"
    local expected
    expected=$(awk '{print $1; exit}' "$checksum_file")
    local actual
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || {
        printf 'Checksum mismatch for %s\n' "$archive" >&2
        exit 1
    }
}

yt_binary_download="$downloads_dir/yt-dlp_macos-$yt_dlp_version"
yt_checksums="$downloads_dir/yt-dlp-$yt_dlp_version-SHA2-256SUMS"
download "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/yt-dlp_macos" "$yt_binary_download"
download "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/SHA2-256SUMS" "$yt_checksums"
yt_expected=$(awk '$2 == "yt-dlp_macos" { print $1 }' "$yt_checksums")
yt_actual=$(shasum -a 256 "$yt_binary_download" | awk '{print $1}')
[[ -n "$yt_expected" && "$yt_actual" == "$yt_expected" ]] || {
    printf 'Checksum mismatch for yt-dlp\n' >&2
    exit 1
}
cp "$yt_binary_download" "$output_dir/yt-dlp"
chmod 755 "$output_dir/yt-dlp"
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/LICENSE" "$output_dir/licenses/yt-dlp-LICENSE"
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/THIRD_PARTY_LICENSES.txt" "$output_dir/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt"

for arch in aarch64 x86_64; do
    deno_archive="$downloads_dir/deno-$deno_version-$arch-apple-darwin.zip"
    deno_checksum="$downloads_dir/deno-$deno_version-$arch-apple-darwin.zip.sha256sum"
    download "https://github.com/denoland/deno/releases/download/$deno_version/deno-$arch-apple-darwin.zip" "$deno_archive"
    download "https://github.com/denoland/deno/releases/download/$deno_version/deno-$arch-apple-darwin.zip.sha256sum" "$deno_checksum"
    verify_sha256_file "$deno_archive" "$deno_checksum"
    rm -rf "$source_dir/deno-$arch"
    mkdir -p "$source_dir/deno-$arch"
    ditto -x -k "$deno_archive" "$source_dir/deno-$arch"
done
lipo -create \
    "$source_dir/deno-aarch64/deno" \
    "$source_dir/deno-x86_64/deno" \
    -output "$output_dir/deno"
chmod 755 "$output_dir/deno"
download "https://raw.githubusercontent.com/denoland/deno/$deno_version/LICENSE.md" "$output_dir/licenses/Deno-LICENSE.md"

ffmpeg_archive="$downloads_dir/ffmpeg-$ffmpeg_version.tar.xz"
download "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" "$ffmpeg_archive"
if [[ ! -d "$source_dir/ffmpeg-$ffmpeg_version" ]]; then
    tar -xf "$ffmpeg_archive" -C "$source_dir"
fi

build_ffmpeg() {
    local arch="$1"
    local build_dir="$runtime_root/ffmpeg-build-$arch"
    local prefix_dir="$runtime_root/ffmpeg-prefix-$arch"
    rm -rf "$build_dir" "$prefix_dir"
    mkdir -p "$build_dir" "$prefix_dir"
    (
        cd "$build_dir"
        "$source_dir/ffmpeg-$ffmpeg_version/configure" \
            --prefix="$prefix_dir" \
            --target-os=darwin \
            --arch="$arch" \
            --cc="clang -arch $arch" \
            --extra-cflags="-mmacosx-version-min=13.0" \
            --extra-ldflags="-mmacosx-version-min=13.0" \
            --disable-autodetect \
            --disable-shared \
            --enable-static \
            --disable-doc \
            --disable-debug \
            --disable-x86asm \
            --disable-ffplay \
            --disable-ffprobe \
            --enable-securetransport \
            --enable-audiotoolbox \
            --enable-videotoolbox
        make -j "$(sysctl -n hw.logicalcpu)" ffmpeg
    )
    cp "$build_dir/ffmpeg" "$runtime_root/ffmpeg-$arch"
}

if [[ ! -x "$runtime_root/ffmpeg-arm64" ]]; then
    build_ffmpeg arm64
fi
if [[ ! -x "$runtime_root/ffmpeg-x86_64" ]]; then
    build_ffmpeg x86_64
fi
lipo -create "$runtime_root/ffmpeg-arm64" "$runtime_root/ffmpeg-x86_64" -output "$output_dir/ffmpeg"
chmod 755 "$output_dir/ffmpeg"
cp "$source_dir/ffmpeg-$ffmpeg_version/COPYING.LGPLv2.1" "$output_dir/licenses/FFmpeg-COPYING.LGPLv2.1"

file "$output_dir/yt-dlp" "$output_dir/ffmpeg" "$output_dir/deno"
printf '%s\n' "$output_dir"
