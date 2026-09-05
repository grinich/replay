# Security

Please do not open a public issue for a vulnerability that could put users at risk. Instead, use GitHub's private vulnerability reporting for this repository.

Replay executes bundled copies of yt-dlp, ffmpeg, and Deno with fixed arguments and never invokes them through a shell. Downloaded media should still be treated as untrusted input.

YouTube browser authentication is opt-in. The persisted setting is an allowlisted browser name, not a credential or arbitrary command argument. Only HTTP(S) YouTube URLs receive `--cookies-from-browser`; other sites continue without browser authentication. Replay does not export cookies to a file or print cookie values. The selected browser's normal cookie storage and macOS Keychain access controls remain in effect.
