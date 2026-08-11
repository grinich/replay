# Security

Please do not open a public issue for a vulnerability that could put users at risk. Instead, use GitHub's private vulnerability reporting for this repository.

Rewatch executes bundled copies of yt-dlp, ffmpeg, and Deno with fixed arguments and never invokes them through a shell. Downloaded media should still be treated as untrusted input.
