<div align="center">

<img src="Resources/banner.png" alt="FileDen">

<br>

<img src="https://raw.githubusercontent.com/opensourcevillain/resources/bc6072cd7f49dc155b47c88e79daa9d49ece9b7e/OpenSourceVillain/Banner.png" alt="Open Source Villain">

<br><br>

<img src="Resources/screenshots/app-icon.png" width="140" alt="FileDen">

# FileDen

**A floating shelf for the files you're working with right now.**

![Platform](https://img.shields.io/badge/macOS%2014%2B-black?style=flat-square)
![Language](https://img.shields.io/badge/Swift%205.10-orange?style=flat-square&logo=swift)
[![License](https://img.shields.io/badge/license-CLL%20v1.2-blue?style=flat-square)](LICENSE.md)
![Bundle](https://img.shields.io/badge/bundle-1.9%20MB-brightgreen?style=flat-square)
![CPU](https://img.shields.io/badge/idle%20CPU-%3C0.1%25-brightgreen?style=flat-square)

`drag · drop · stash · ask · share`

</div>

---

> Inspired by Yoink and FilePane. Built because the macOS desktop is not a staging area, the dock is not a clipboard, and a shelf you can summon anywhere shouldn't cost $10.

---

## Screenshots

<div align="center">
<img src="Resources/screenshots/shelf-framed.png" width="380" alt="A den of stashed files"> <img src="Resources/screenshots/ask-framed.png" width="380" alt="Ask — chat about your documents">

<br><br>

<img src="Resources/screenshots/editor-adjust.png" width="380" alt="Image editor — tone adjustments"> <img src="Resources/screenshots/editor-markup.png" width="380" alt="Image editor — markup & redaction">
</div>

---

## What it is

FileDen is a tiny floating window — a "den" — that holds files while you move them between apps, archives, uploads, and conversations. Drag in. Drag out. Drop a folder, get a zip. Shake your mouse, get a fresh den near the cursor. Hit a hotkey, same. Close it, the contents go to recents.

And now it can *read* them: drop documents into a den and **ask questions about them** in a conversation, getting grounded, cited answers entirely on-device. See [Ask](#ask-chat-about-your-documents). It can also *edit* them — a full image editor lives right inside the den. See [Image editor](#image-editor).

Built in Swift + AppKit + SwiftUI for macOS 14+. No Electron, no background daemons, no telemetry. Document Q&A and image editing both run on Apple's on-device frameworks — nothing leaves your Mac.

---

## Highlights

- **Ask your documents, offline.** Drop in PDFs (scans included), Word, Markdown, text, or code, hit *Ask*, and have a conversation about them with cited answers — fully on-device. [Details ↓](#ask-chat-about-your-documents)
- **Full image editor, built in.** Open any image into an inline editor: live tone adjustments and filters, crop / rotate / straighten / flip, freehand markup, shapes, text, redaction (blackout / pixelate), and one-tap background removal — all GPU-accelerated and on-device. Export to a new den or overwrite the original. [Details ↓](#image-editor)
- **Multiple dens.** Spawn as many as you want — each is independent.
- **Drag-out as multi-file.** One drag carries the whole stack.
- **Smart actions menu.** Open, Quick Look, Reveal, Copy, Duplicate, Copy Path, Compress to ZIP, Unarchive, Print, Set as Wallpaper, Combine to PDF, Share, Move to Trash — surfaced based on file type.
- **PDF tools.** Select PDFs and a *PDF Tools* submenu appears: merge, split into pages, export pages as images, extract embedded images, extract text. Results land in a fresh den, staged for you to drag wherever they belong.
- **Convert image & video.** Visually-lossless format conversion, all native. Images → JPEG / HEIC / PNG / TIFF / WebP / AVIF (ImageIO; WebP/AVIF shown only where the OS can encode them). Video → HEVC (smaller), MP4, MOV, GIF, Poster Frame, or Extract Audio (AVFoundation) — container changes rewrap losslessly when the codec allows. Animated GIFs convert back to video. Results stage into a new den.
- **Progress, when it's worth it.** Long jobs (mostly video) show a small floating progress HUD that stacks if several run at once. Fast jobs never flash one.
- **Notch drop.** Drag onto the notch (or its area on non-notch Macs) to open a fresh den below it.
- **Mouse-shake to summon.** Wiggle the cursor; a new den appears near it.
- **Global hotkey.** Default ⌥⇧D, fully rebindable.
- **Recents.** Closed dens remember what was in them.
- **Auto-zip folders on share.** Optional. Toggleable.

---

## The den

A den has two modes:

| Mode | Behavior |
|------|----------|
| **Compact** | 200×200, dashed drop zone when empty, file thumbnail / stacked cards when full. Bottom-right action button. |
| **Expanded** | 340×420, grid or list view of all items, multi-select with ⌘/⇧/⌃-click, actions button. |
| **Ask** | Expands into a side-by-side split — files on the left, a chat about the documents on the right. Clicking a cited source opens a third pane showing it highlighted. Everything stays in the one den window. |
| **Edit** | A three-pane image editor — files on the left (doubling as image tabs), the live canvas in the middle, the tool controls on the right. Click another image to switch tabs; each keeps its own edits. |

Tap the file/stack to expand. Chevron back to collapse. The window floats above other apps and follows you across spaces.

---

## Spawning a den

There are four ways to get a new den on screen:

1. **Menu bar icon** → click → **New Den**.
2. **Global hotkey** (default ⌥⇧D). Configure in Settings.
3. **Mouse shake**. Wiggle the cursor in tight strokes. Toggleable in Settings.
4. **Drag files onto the notch** (or the screen-top center on Macs without one).

The shortcut shown in the menu auto-mirrors whatever is configured. Disable the hotkey and the menu shortcut disappears too.

---

## Actions menu

The actions button (•••) replaces the share button and adapts to selection:

- Always: Open, Quick Look, Reveal in Finder, Copy, Duplicate, Copy Path, Share…, Move to Trash.
- Any searchable document in the selection (PDF / Word / Markdown / text / code / …) → **Ask AI…** — opens an inline [chat](#ask-chat-about-your-documents) about it.
- Folders or multiple items → **Compress to ZIP**.
- All archives → **Unarchive**.
- All printable (pdf/img/txt/rtf) → **Print**.
- All images → **Set as Wallpaper**, **Combine to PDF**, **Convert Image** ▸ To JPEG / HEIC / PNG / TIFF / WebP / AVIF (the last two appear only where the OS can encode them), plus quick **Resize…** and **Compress Image…** panels. All GIFs also get → **To Video (MP4)**.
- A single image → **Edit Image…** — opens the full inline [image editor](#image-editor).
- All PDFs → **PDF Tools** ▸ Merge PDFs (2+), Split into Pages, Export Pages as Images, Extract Images, Extract Text.
- All videos → **Convert Video** ▸ To HEVC (smaller), To MP4, To MOV, To GIF, Poster Frame, Extract Audio.

PDF, image, and video tools all run natively (PDFKit + CoreGraphics + ImageIO + AVFoundation, no external binaries). Conversions are visually lossless — lossy targets use a near-1.0 quality, lossless targets are exact, and video container changes rewrap without re-encoding when the codec allows. (GIF is the exception: it's a 256-colour format, so a clip exported to GIF is necessarily lossy.) Long jobs show a floating progress HUD; output is staged into a new den — nothing is written next to your originals until you drag it there.

The actions button is a compact ••• icon, right-aligned in the expanded view's bottom bar; it acts on the current selection (or every item, when nothing is selected).

---

## Ask: chat about your documents

Drop documents into a den and hit **Ask** to have a conversation about them — entirely on-device, no network, no API keys, no subscription. The den widens into a split: your files on the left, the chat on the right. Built for the two things every other "chat with your PDFs" tool gets wrong: **accuracy** and **speed**.

- **A real chat, not one-shot Q&A.** Multi-turn — ask a follow-up and it keeps the thread. Every answer is grounded in your own documents.
- **Many formats, not just PDF.** PDF (with on-device OCR for scanned pages), Word (`.docx`), RTF, HTML, Markdown, plain text, CSV/TSV, JSON/YAML/TOML/INI, and source code.
- **Hybrid retrieval = accuracy.** Semantic search (Apple's `NLContextualEmbedding`) *and* keyword search (SQLite FTS5/BM25) are fused, so it catches both meaning *and* exact names, IDs, codes, and figures. Vectors are pre-normalised and scored with a single Accelerate matrix multiply — search is **sub-second** after indexing, not the minute-plus other tools take.
- **Cited, and clickable.** Each answer carries a small **sources** chip; open it for a quick rundown, then click a source to open it in a third pane — PDFs jump to the page with the passage highlighted; text / Markdown / HTML / RTF / DOCX scroll to the highlighted span. One window holds everything — no floating clutter.
- **It uses tools.** The model can call a calculator for exact arithmetic, so "total revenue" returns the right number instead of a guess. The tool system is built to grow (document actions are next).
- **Never a dead end.** No Apple Intelligence (older Macs, or it's switched off), or the model declines? Ask falls back to the most relevant passages with citations — same retrieval, just without the written prose. It never shows a failure.
- **Notebooks.** Save a set of documents as a named notebook and reopen it from the menu bar to ask it anytime. Indexes are cached, so reopening is instant.

Open it from the **Ask AI…** item in a den's actions menu (or the sparkle button on a compact den), or by opening a saved **Notebook** from the menu bar. Turn the whole feature on or off — and toggle written answers vs. passages-only — in **Settings → AI**.

**Requirements.** Indexing, retrieval, OCR, and passage search run on macOS 14+. Written answers use Apple's Foundation Models and need macOS 26 with Apple Intelligence enabled; the framework is weak-linked, so FileDen runs fine without it.

---

## Image editor

Open any image into a full editor that lives right inside the den — no separate app, no upload. The den widens into three panes: your files on the left (doubling as image **tabs** — click another image to switch, and each tab keeps its own edits), the live canvas in the middle, and the tool controls on the right. Everything is GPU-accelerated through Core Image + Metal and runs entirely on-device, so adjustments preview in real time and the CPU stays idle when you're not dragging.

<div align="center">
<img src="Resources/screenshots/editor-crop.png" width="380" alt="Image editor — crop, rotate, straighten"> <img src="Resources/screenshots/editor-filters.png" width="380" alt="Image editor — filter presets">
</div>

- **Adjust.** Live exposure, brightness, contrast, saturation, vibrance, warmth, highlights, shadows, and sharpness — click any value to reset it.
- **Filters.** One-tap looks (Mono, Noir, Fade, Chrome, Instant, Process, Transfer, Sepia), shown as live thumbnails of your own image.
- **Crop & geometry.** Interactive crop with a rule-of-thirds grid and aspect presets (Free / 1:1 / 4:3 / 3:2 / 16:9 / 9:16), 90° rotate, flip, and fine straighten.
- **Markup.** Freehand pen, line, arrow, box, oval, highlighter, and text — pick a colour and thickness. Drawn vector-clean and baked in only on export.
- **Redaction.** Blackout or pixelate any region; redactions are burned into the pixels, so they can't be peeled back off the exported file.
- **Background removal.** One-tap on-device subject isolation (Vision), straight onto transparency.
- **Undo / redo** the full edit history, or reset to the original in one click.
- **Export** to a new den in any format (PNG / JPEG / HEIC / TIFF / WebP / AVIF) with quality and scale — or **Overwrite Original** (behind a confirmation) to replace the file in place, keeping its format.

Open it from **Edit Image…** in a den's actions menu, or the wand button on a compact den. Runs on macOS 14+; background removal uses the Vision foreground-mask API.

---

## Privacy

Everything stays local — including the AI. The document chat runs entirely on Apple's on-device frameworks (`NaturalLanguage` embeddings, `Vision` OCR, `FoundationModels`); no text, no embeddings, and no questions or answers ever leave your Mac. No network calls, no analytics, no crash-reporters.

Settings and the recents list live in `UserDefaults`. Files produced by tools (PDF ops, conversions, archives) are staged under `~/Library/Application Support/counter-ltd/fileden/Staging` and cleared at launch. Ask's search indexes live under `…/Indices` and saved notebooks under `…/Notebooks` (kept across launches — clear indexes from *Settings → AI*, or wipe everything with `make reset`).

---

## Building

Requires **macOS 14+, Swift 5.10, Xcode CLT**.

```bash
make build      # size-optimised release build (-Osize, -wmo, -dead_strip)
make bundle     # assemble FileDen.app under build/ (strips symbols, ad-hoc signs)
make run        # bundle + launch
make release    # clean + bundle, ready to ship
make debug      # debug build + run in foreground
make icon       # rebuild AppIcon.icns
make clean      # clear SwiftPM + build/
make reset      # wipe ~/Library/Application Support/counter-ltd/fileden
```

There are no third-party dependencies — everything is built on system frameworks (AppKit, SwiftUI, PDFKit, AVFoundation, ImageIO, Core Image + Metal for the image editor, plus NaturalLanguage, Accelerate, Vision, SQLite, and a weak-linked FoundationModels for the Ask feature).

Codesigning uses a local `FileDen Dev` code-signing certificate if one exists in your keychain, otherwise it falls back to ad-hoc.

FileDen needs **Accessibility** access for the global hotkey and mouse-shake. macOS ties that grant to the app's signing identity, and an ad-hoc signature changes on every rebuild — so you'd have to re-grant after each build. To make the grant stick, create a reusable self-signed `FileDen Dev` certificate once (Keychain Access → Certificate Assistant → Create a Certificate → type *Code Signing*); `make build` / `make run` pick it up automatically.
