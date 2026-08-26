# Chapter Enrichment: per-chapter summaries + exercises via pi-on-Deno

> **Status: implemented.** See `Sources/Replay/ChapterEnrichment.swift`
> (models, transcript slicing, prompt, parsing), `Sources/Replay/EnrichmentEngine.swift`
> (deno+pi subprocess orchestration), `QueueStore` (triggering, persistence,
> activity state), the `ChapterSidebar` in `ContentView.swift` (expandable
> rows + footer controls), and `tools/chapter_enrichment_check.swift` (tests,
> wired into `scripts/test.sh`).
>
> **Field notes from implementation:**
> - pi runs fine under the bundled Deno via `deno run -A npm:@earendil-works/pi-coding-agent@0.84.1`.
> - Default provider/model: **openai-codex / gpt-5.6-sol** (verified end-to-end:
>   a real chapter enriched in ~18s). Override with `defaults write com.mg.replay
>   enrichmentPiProvider/enrichmentPiModel/enrichmentPiPackage ...` or the
>   `REPLAY_PI_PROVIDER` / `REPLAY_PI_MODEL` / `REPLAY_PI_PACKAGE` env vars.
> - **Deno version matters:** the Codex provider opens a WebSocket, which
>   crashes on Deno < 2.9 (`Cannot assign to read only property
>   'Symbol(Symbol.toStringTag)' of MessageEvent` in undici). The app bundles
>   Deno v2.9.5, which works. Dev builds falling back to an older Homebrew
>   deno will hit this; `--provider anthropic --model claude-sonnet-4-5`
>   (SSE-based) works even on old Deno.
> - pi is run fully hermetic: `-p --no-session -ne --no-skills
>   --no-prompt-templates --no-context-files --no-tools` (extensions can open
>   WebSockets, which also crash under Deno).
> - Enrichment JSON lives at `Application Support/Replay/Enrichment/<item-id>/enrichment.json`
>   with per-chapter prompt/stdout/stderr files beside it for debugging.
>   Videos without creator chapters first run `chapter-plan.prompt.md` through
>   pi; the validated generated outline is persisted in the same JSON.
>   The Deno npm cache is pinned to `Application Support/Replay/DenoCache`.

## Goal

For any downloaded video with subtitles, generate a **small summary and a few
exercises per chapter**, viewable inline in the chapter sidebar, fully offline
after generation. When creator chapters are absent, first ask pi to derive a
semantic, timestamped chapter outline from the transcript. Modeled on
`~/Documents/Notes/Clippings/enrich_clippings_agentic.py`
(pi sub-agent per unit of work, strict output contract), but running pi through
the **Deno binary already bundled in Replay** — no Node install required.

## What we already have

| Piece | Where | Notes |
|---|---|---|
| Chapters (title, start, end) | `WatchItem.chapters` via `ChapterMetadata.swift` | populated from yt-dlp info JSON |
| Offline transcript | `WatchItem.subtitleFilePath` + `VideoSubtitles.swift` | VTT cues with start/end times — sliceable per chapter |
| Deno binary | `Resources/Tools/deno` via `DownloadEngine.findTool` | already used for yt-dlp `--js-runtimes` |
| pi under Deno | verified: `deno run -A npm:@earendil-works/pi-coding-agent -p ...` | reads `~/.pi` auth/config; reached the model API in a live test |
| Persistence pattern | `QueueStore` → `queue.json` in Application Support | same dir can hold enrichment JSON per item |

## Architecture

```
User clicks "Enrich chapters" (or auto after download, opt-in)
        │
        ▼
EnrichmentEngine (new, Swift actor — sibling of DownloadEngine)
  1. Load VideoSubtitleTrack. If creator chapters are absent, run a dedicated
     pi subprocess to propose semantic boundaries and titles, then snap and
     validate its timestamps against subtitle cues (fixed windows are the
     deterministic fallback).
  2. Slice cues into per-chapter transcript text and build a prompt file
     (Application Support/Enrichment/<item-id>/chapter-03.prompt.md).
  3. Spawn pi subprocess per chapter, bounded concurrency (2–3):
        deno run -A npm:@earendil-works/pi-coding-agent@<pinned> \
            -p --no-session @chapter-03.prompt.md
     with DENO_DIR pinned to Application Support/DenoCache.
  4. Parse strict-format output → ChapterEnrichment.
  5. Persist enrichment.json next to prompts; update WatchItem.
        │
        ▼
ChapterSidebar rows become expandable → summary + exercises (+ solutions
behind a disclosure), with per-chapter status (pending/running/done/failed).
```

### New model types

```swift
struct ChapterEnrichment: Codable, Hashable {
    var chapterID: String            // VideoChapter.id
    var summary: String              // 3–5 sentences
    var keyPoints: [String]          // 2–5 bullets
    var exercises: [Exercise]        // 2–4 items
    var generatedAt: Date
    var model: String?
}

struct Exercise: Codable, Hashable {
    var question: String
    var solution: String
}

enum EnrichmentState: Codable { case none, running(progress: Double), ready, failed(String) }
```

`WatchItem` gains `enrichmentFilePath: String?` (mirrors `subtitleFilePath`);
the enrichment JSON itself lives in Application Support so `queue.json` stays
small. Cached results are reused; a "Regenerate" action forces re-run
(the `--force` idea from the clippings script).

### Prompt contract (per chapter)

Inputs: video title/author, chapter title + index + duration, the chapter's
transcript slice (truncated to a token budget, e.g. ~12k chars, head+tail),
and the list of all chapter titles for context. The guide prompt classifies
technical chapters and requires every exercise to apply the material through
tracing, derivation, implementation, debugging, experiment design, benchmark
critique, prediction, or engineering trade-offs. Speaker-recall and bare
listing questions are forbidden and filtered during parsing.

Output: **JSON only**, fenced, matching `ChapterEnrichment` fields — same
"hard rules / required shape" style as `markdown_prompt_for_link` in the
clippings script, but JSON is easier to parse in Swift than delimited
Markdown. Anti-hallucination rule: only claim what the transcript supports.

Run pi with tools disabled (`-ne` equivalent) since no browsing is needed —
faster, cheaper, deterministic. Note from the clippings script: `-ne` also
disables auth extensions; if the user's provider needs one (e.g.
`pi-anthropic-auth`), re-enable it explicitly via `-e`, or skip `-ne` and rely
on the prompt to forbid tool use.

### Videos without chapters / without subtitles

- **No chapters:** show the chapter-guide sidebar and offer **Generate chapters
  & guide**. A pi subprocess proposes semantic titles and cue-aligned starts;
  invalid output falls back to roughly six-minute cue-aligned sections.
  Generated chapters are visibly labeled and persisted separately from source
  metadata.
- **No subtitles:** keep the sidebar visible with an explanatory empty state;
  generation remains disabled. Later option: whisper/ffmpeg transcription.

## Key decisions & risks

1. **Pinned package version.** `npm:@earendil-works/pi-coding-agent@X.Y.Z`
   pinned in code; first run downloads to `DENO_DIR` (needs network once).
   Optionally pre-warm the cache right after a download completes.
2. **Auth.** pi reads `~/.pi`. If no provider is configured, fail fast with a
   friendly "Set up pi first" message (check by running `pi --version`-style
   probe or catching the auth error). Replay itself stores no keys in v1.
3. **Cost/latency.** One model call per chapter; a 20-chapter video = 20 calls.
   Mitigations: bounded concurrency, per-chapter caching (re-runs only
   failures), and a batched mode (all chapters in one call) for videos under
   ~15 min of transcript.
4. **Sandboxing.** Replay already shells out to yt-dlp/deno with network, so
   no new entitlement work expected.
5. **Output parsing.** Reuse the clippings script's lesson: strip fenced
   wrapper, tolerate minor deviations, write `.stderr.txt` beside outputs for
   debugging, never crash the queue on a bad chapter — mark it `failed`.

## Milestones

1. **Spike (throwaway script)** — `scripts/enrich_chapters_spike.sh`: take an
   existing downloaded item's VTT + chapters JSON, produce per-chapter
   enrichment via bundled deno + pi. Validates prompt, output shape, timing,
   cost. *(~half day)*
2. **EnrichmentEngine + models** — Swift actor, subtitle slicing, subprocess
   management, JSON persistence, caching. Unit-check harness in `tools/`
   (`chapter_enrichment_check.swift`, matching the existing check style) for
   slicing + parsing logic. *(~1 day)*
3. **UI** — expandable chapter rows in `ChapterSidebar`, status indicators,
   "Enrich chapters" / "Regenerate" actions, error surfacing. *(~1 day)*
4. **Polish** — settings toggle (auto-enrich after download), concurrency
   limits, cancellation when item is deleted, Low Power Mode pause parity
   with downloads. *(~half day)*

## Open questions

- Auto-enrich after every download, or manual-only in v1? (Suggest manual.)
- Show exercises inline in the sidebar, or a dedicated "Study" pane per video?
- Should solutions be generated up front (offline-first) or on demand?
  (Suggest up front — one call anyway.)
- Model choice: pi's default, or a cheap/fast override baked into the prompt
  command (`--model`)?
