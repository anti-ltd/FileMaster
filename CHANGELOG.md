# Changelog

All notable changes to FileMaster are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-27

First production release.

### Added
- **Dens** — small floating shelves that hold files while you move them
  between apps. Compact (200×200) collapses to a single thumbnail stack;
  expanded (340×420) opens into a grid or list with multi-select.
- **Four ways to summon a den**: menu-bar item, global hotkey (default
  ⌥⇧D, rebindable), mouse-shake near the cursor, or drop onto the notch.
- **Drag-out as a multi-file stack** — one drag carries every item.
- **Recents** — closed dens remember what was in them.
- **Smart actions menu**, surfaced per file type: Open, Quick Look, Reveal,
  Copy, Duplicate, Copy Path, Compress to ZIP, Unarchive, Print, Set as
  Wallpaper, Combine to PDF, Share, Move to Trash.
- **PDF Tools** (PDFKit + CoreGraphics) — Merge, Split into Pages, Export
  Pages as Images, Extract Images, Extract Text. Outputs stage into a fresh
  den, not written next to the originals.
- **Image conversion** (ImageIO) — JPEG, HEIC, PNG, TIFF, WebP, AVIF (the
  last two surface only when the OS can encode them), plus Resize and
  Compress panels. Animated GIFs convert back to video.
- **Video conversion** (AVFoundation) — HEVC, MP4, MOV, GIF, Poster Frame,
  Extract Audio. Container changes rewrap losslessly when the codec allows.
- **Image editor** — three-pane editor inside the den: live adjustments
  (exposure, brightness, contrast, saturation, vibrance, warmth, highlights,
  shadows, sharpness), one-tap filters, interactive crop with aspect presets,
  rotate / straighten / flip, markup (pen, line, arrow, box, oval, highlight,
  text), redaction (blackout / pixelate, burned into pixels), one-tap
  background removal (Vision foreground-mask), full undo/redo. GPU-accelerated
  through Core Image + Metal.
- **Ask** — drop documents into a den and chat about them, entirely on
  device. Multi-format extraction (PDF with on-device OCR for scans, Word,
  RTF, HTML, Markdown, plain text, CSV/TSV, JSON/YAML/TOML/INI, source
  code). Hybrid retrieval: semantic search (`NLContextualEmbedding`) fused
  with BM25 (SQLite FTS5), Accelerate matrix multiply for sub-second search
  after indexing. Cited answers — click a chip to open the source passage
  in a third pane, highlighted in place. Calculator tool for exact
  arithmetic. Apple Intelligence writes the prose on macOS 26+ when
  available; older / non-Apple-Intelligence Macs fall back to passages-only
  with the same citations.
- **Notebooks** — save a set of documents as a named notebook; reopen from
  the menu bar to ask it again. Indexes cached.
- **BYO LLM** — opt into OpenAI, Ollama, or llama.cpp providers in
  Settings → AI when you don't want Apple Intelligence. User-configured,
  never on by default.
- **Floating progress HUD** for long jobs (mostly video). Stacks if several
  run at once; fast jobs never flash one.
- **Notch drop** — drag onto the notch (or the screen-top center on
  non-notch Macs) to open a fresh den below it.
- **Settings popover + pop-out window** sharing one tab catalogue
  (Settings, AI, About) via iUX-MacOS.
- **Manual "Check for updates"** in *About* — single user-initiated GET to
  `https://anti.ltd/api/version?app=filemaster`. No background polling, no
  identifiers in the request.
- Mac App Store distribution pipeline (`make build-mas`).
- Drag-to-install DMG pipeline (`make dmg`, signed; `make dist` for the
  Developer ID + notarized + stapled customer build).
- Stable-signing path (`FileMaster Dev` self-signed cert) so macOS keeps
  the Accessibility grant across local rebuilds.

### Security & privacy
- Ask runs entirely on Apple's on-device frameworks — `NaturalLanguage`
  embeddings, `Vision` OCR, `FoundationModels` for written prose (macOS 26+
  only, weak-linked). No document text, no embeddings, no questions, and no
  answers leave your Mac when the default Apple Intelligence provider is
  selected.
- BYO LLM providers (OpenAI / Ollama / llama.cpp) are off by default and
  must be opted into in *Settings → AI*. They send the user's question and
  the matched passages to the configured endpoint — disclosed in the README
  privacy section.
- The only other outbound call is the manual update check above; the MAS
  build declares `com.apple.security.network.client` solely to allow these
  two user-initiated paths.
- No analytics, no crash reporters, no identifiers in any request.
- Settings and the recents list live in `UserDefaults`.
- Tool outputs (PDF ops, image / video conversions, archives) stage under
  `~/Library/Application Support/counter-ltd/filemaster/Staging` and are
  cleared at launch. Search indexes live at `…/Indices`, saved notebooks
  at `…/Notebooks`. `make reset` wipes the whole tree.
- Sandboxed MAS build (`Resources/FileMaster.mas.entitlements`) declares
  only: `app-sandbox`, `files.user-selected.read-write`,
  `files.bookmarks.app-scope`, and `network.client` — each commented with
  its justification.
- Direct-distribution build (`Resources/FileMaster.entitlements`) is
  non-sandboxed so the same binary can hold a stable Accessibility grant
  across rebuilds for the menu-bar agent's hotkey + shake.
- Privacy manifest declares `UserDefaults` (CA92.1), file timestamps
  (C617.1), and disk-space probes (E174.1) — the API categories the app
  actually touches.
