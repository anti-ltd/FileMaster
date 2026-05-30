// Reel showcase — compiled only in `--showcase` builds (FILEMASTER_SHOWCASE).
// See Makefile: `make showcase`. Never included in production builds.
//
// A self-recording 9:16 product reel, ~14 s loop. It crossfades through the
// REAL FileMaster UI — the same `ShelfView` / `QAView` the app ships, rendered
// with throwaway placeholder files (the AppStageCapture technique) — over a
// branded backdrop, with a short caption per beat. A quick, informative
// showcase: no competitor jabs, just the app doing its thing.
// Design space: 360×640. Capture window: 1080×1920 (3×).
// Output: ~/Desktop/FileMaster-Reel-<timestamp>.mp4
//
// IMPORTANT concurrency note (macOS 26.5):
//   `swift_task_isCurrentExecutorWithFlagsImpl` crashes when called from
//   non-async contexts (Timer callbacks). So the director is NOT @MainActor,
//   its Timer callback calls tick() directly, and audio lives in a standalone
//   non-isolated `ReelAudio`. State is "main-thread by convention" (Timer on
//   RunLoop.main; SwiftUI renders on main).

#if FILEMASTER_SHOWCASE

import AppKit
import SwiftUI
import FileMasterCore
import FileMasterAI

// MARK: - Palette

private enum Reel {
    static let bg      = Color(red: 0.012, green: 0.014, blue: 0.020)
    static let accentA = Color(red: 0.27, green: 0.62, blue: 1.0)   // bright blue
    static let accentB = Color(red: 0.20, green: 0.85, blue: 0.86)  // cyan
}

// MARK: - Synthetic demo content
//
// Real, empty placeholder files in a temp dir so the den shows proper type
// icons via NSWorkspace without touching any of the user's files or the app's
// real support directory. The Ask transcript is pre-built — no indexer, no LLM.

enum ReelDemo {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("filemaster-reel-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // Each placeholder is created at a realistic logical size via a sparse
    // truncate — the den shows "1.8 MB", "47.5 MB", etc. instead of "Zero KB"
    // without ever writing those bytes to disk. Type icons come from the
    // extension via NSWorkspace, so empty content is fine — EXCEPT for image /
    // video types, whose thumbnailer tries to *decode* the (empty) file and
    // renders a garbled smear. Those get real, tiny renderable content (see
    // `makeImage`); everything else stays sparse and shows a crisp type icon.
    private static func make(_ specs: [(String, Int)]) -> [URL] {
        specs.map { name, bytes in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                if let fh = try? FileHandle(forWritingTo: url) {
                    try? fh.truncate(atOffset: UInt64(bytes))
                    try? fh.close()
                }
            }
            return url
        }
    }

    /// A real, renderable PNG so the den's image thumbnail is a clean little
    /// branded card — and, scaled up in the image-editor stage, a crisp
    /// "moodboard" with enough going on to make crop/markup/adjust read well.
    private static func makeImage(_ name: String, _ px: CGFloat) -> URL {
        let url = dir.appendingPathComponent(name)
        let size = NSSize(width: px, height: px * 0.66)
        let img = NSImage(size: size)
        img.lockFocus()
        let blue  = NSColor(red: 0.27, green: 0.62, blue: 1.0, alpha: 1)
        let cyan  = NSColor(red: 0.20, green: 0.85, blue: 0.86, alpha: 1)
        let ink   = NSColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1)
        NSGradient(colors: [blue, cyan])?.draw(in: NSRect(origin: .zero, size: size), angle: 55)
        // A soft "horizon" band and a sun — reads as a landscape composition.
        ink.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size.width, height: size.height * 0.42)).fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.14, y: size.height * 0.52,
                                    width: size.height * 0.40, height: size.height * 0.40)).fill()
        // A few swatch tiles bottom-right, like a palette strip.
        let swatches = [blue, cyan, NSColor.white.withAlphaComponent(0.85), ink.withAlphaComponent(0.6)]
        for (i, c) in swatches.enumerated() {
            c.setFill()
            let w = size.width * 0.12
            NSBezierPath(roundedRect: NSRect(x: size.width * 0.40 + CGFloat(i) * (w + size.width * 0.02),
                                             y: size.height * 0.10, width: w, height: size.height * 0.16),
                         xRadius: 6, yRadius: 6).fill()
        }
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }

    /// Real text content so QuickLook renders a legible document page in the
    /// expanded grid/list — an empty `.md` thumbnails as a stark blank card.
    private static func makeText(_ name: String, _ body: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? body.data(using: .utf8)?.write(to: url)
        return url
    }

    // Order matters: the compact den's stack shows the first three, so they lead
    // with crisp, instantly-readable type icons (PDF · DOCX · Markdown). The
    // image and the heavier files round out the expanded grid.
    static let denFiles: [URL] = {
        let icons = make([
            ("Q3 Report.pdf", 1_840_000),
            ("Contract.docx", 246_000),
        ])
        let notes = makeText("Release Notes.md", """
        # FileMaster 1.0

        - Floating den: drag anything in, stash it instantly.
        - PDF tools, format conversions, a built-in image editor.
        - Ask your documents — fully on-device, nothing uploaded.
        """)
        let image = makeImage("Brand Moodboard.png", 1280)
        let rest = make([
            ("assets.zip", 12_400_000),
            ("walkthrough.mov", 47_500_000),
        ])
        return icons + [notes, image] + rest
    }()

    // ── TikTok cut: a funny, grounded Ask exchange is the star. The model roasts
    //    the user's own deck (with a real [1] citation back to Q3 Report.pdf),
    //    the user concedes, then it flexes that none of it ever left the Mac.
    //    Stable per-turn ids so each answer fills its own bubble in place — the
    //    "Thinking…" placeholder becomes the answer with no crossfade flicker,
    //    exactly like the app's real streaming.
    // Stable per-message ids so each bubble fills in place across reveal phases
    // (the "Thinking…" placeholder becomes the answer with no remount flicker).
    private static let user1ID = UUID()
    private static let user2ID = UUID()
    private static let turn1ID = UUID()
    private static let turn2ID = UUID()

    static func thinking(_ id: UUID) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: "", isStreaming: true)
    }

    /// One TikTok joke: a two-beat Ask exchange (the AI roasts the user's own
    /// den with a real [1] citation, the user concedes, the AI flexes on-device).
    /// Every variant reuses the exact same visuals, timeline and audio — only the
    /// text and the cited file change — so adding a reel is just adding a script.
    struct ReelScript {
        let user1: String
        let answer1: String       // include "[1]" where the citation chip should read
        let citeFile: Int         // index into denFiles for the [1] source
        let citeText: String
        let citeLines: ClosedRange<Int>
        let user2: String
        let answer2: String       // the on-device payoff
        // When true, skip the file-drop den intro and open straight on the Ask
        // chat — the chat is the whole video. (The drop-montage cuts didn't land
        // as well as the chat itself.)
        var chatOnly = false
    }

    /// Pick a reel by name (see ShowcaseRunner / `make reel REEL=<name>`).
    static let scripts: [String: ReelScript] = [
        // The original — keep as the default "tour".
        "tour": ReelScript(
            user1: "what's even in this den? i forgot 💀",
            answer1: "A contract you never signed [1], a moodboard from 2am, and a 47MB “walkthrough.mov” you'll never watch. Rundown, or shall we keep pretending?",
            citeFile: 1, citeText: "Employment Agreement (draft). Signature block: blank.", citeLines: 1...3,
            user2: "...keep pretending",
            answer2: "Respect. 🫡 Filed under “future me's problem.” Btw — I read every one of these right here on your Mac. Nothing touched the cloud. 🔒"),

        // "messy" — the relatable Downloads-folder roast. Chat-only.
        "messy": ReelScript(
            user1: "be honest. how bad is it in here?",
            answer1: "Six files, zero structure. A Q3 report you skimmed once [1], a “moodboard” that's three gradients, and a contract aging like milk. It's giving chaos.",
            citeFile: 0, citeText: "Q3 Report — revenue up 23% YoY. You opened this once.", citeLines: 9...12,
            user2: "...so what do i do",
            answer2: "Drag, drop, ask, zip, convert — all in here. And I judged your whole mess on-device. Your shame never left the Mac. 🔒",
            chatOnly: true),

        // "lawyer" — the unsigned-contract bit. Chat-only.
        "lawyer": ReelScript(
            user1: "tldr this contract, i'm not reading it",
            answer1: "They get 30 days notice, they own your work-hours output, and you get a signature line you still haven't signed [1]. Bold strategy.",
            citeFile: 1, citeText: "Employment Agreement — 30-day notice. Signature block: blank.", citeLines: 4...9,
            user2: "i'll sign it later",
            answer2: "Sure you will. Meanwhile I read every page right here — no cloud, no “oops we trained on your contract.” 🔒",
            chatOnly: true),

        // "snoop" — the privacy flex. The AI admits it read everything… then
        // lands that none of it ever left the Mac. Chat-only.
        "snoop": ReelScript(
            user1: "wait… you can read ALL my files?",
            answer1: "Every word. Your Q3 numbers [1], the contract you didn't sign, that 2am moodboard — yeah, I read it.",
            citeFile: 0, citeText: "Q3 Report — revenue +23% YoY, churn 2.1%. Slide 9.", citeLines: 9...12,
            user2: "should i be scared",
            answer2: "Nope. I read it all right here on your Mac. No cloud, no servers, no “we value your privacy” email. 🔒",
            chatOnly: true),

        // "deadline" — the AI keeps the receipts on what you were meant to do.
        // Chat-only.
        "deadline": ReelScript(
            user1: "what was i supposed to do this week 😭",
            answer1: "Per your own notes: ship 1.0, sign the contract, and stop hoarding 47MB “walkthrough” clips [1]. Progress so far: none.",
            citeFile: 2, citeText: "Release Notes — FileMaster 1.0 ship checklist.", citeLines: 1...3,
            user2: "rude. but fair.",
            answer2: "I keep the receipts — all of them, on-device. Now go sign the contract before I bring it up again. 🔒",
            chatOnly: true),
    ]

    /// The active script, exposed so the director can read its `chatOnly` flag.
    static var current: ReelScript { scripts[scriptName] ?? scripts["tour"]! }

    /// Which script the next render uses. Set by ShowcaseRunner before recording.
    static var scriptName = "tour"
    private static var script: ReelScript { scripts[scriptName] ?? scripts["tour"]! }

    static var askUser1: ChatMessage { ChatMessage(id: user1ID, role: .user, text: script.user1) }
    static var askUser2: ChatMessage { ChatMessage(id: user2ID, role: .user, text: script.user2) }

    static var askAnswer1: ChatMessage {
        let s = script
        let chunk = Chunk(
            sourceURL: denFiles[s.citeFile], ordinal: 0,
            text: s.citeText,
            locator: .textRange(charRange: 0..<max(1, min(s.citeText.count, 200)), lineRange: s.citeLines)
        )
        let citation = Citation(id: 1, chunk: StoredChunk(id: 1, chunk: chunk), score: 0.95)
        return ChatMessage(id: turn1ID, role: .assistant, text: s.answer1,
                           citations: [citation], isStreaming: false)
    }

    static var askAnswer2: ChatMessage {
        ChatMessage(id: turn2ID, role: .assistant, text: script.answer2)
    }

    /// Messages for an Ask reveal phase:
    /// 1 q1 · 2 thinking · 3 answer1 · 4 q2 · 5 thinking · 6 answer2.
    static func askMessages(_ phase: Int) -> [ChatMessage] {
        switch phase {
        case 1: return [askUser1]
        case 2: return [askUser1, thinking(turn1ID)]
        case 3: return [askUser1, askAnswer1]
        case 4: return [askUser1, askAnswer1, askUser2]
        case 5: return [askUser1, askAnswer1, askUser2, thinking(turn2ID)]
        case 6: return [askUser1, askAnswer1, askUser2, askAnswer2]
        default: return []
        }
    }

    // ── Wide (Reddit/YouTube) cut: a longer, informative-with-light-wit Ask.
    //    Three grounded turns — read the deck, flag the contract, then the
    //    on-device payoff — each citing a real den file. Stable per-turn ids so
    //    answers fill their bubble in place.
    private static let wTurn1ID = UUID()
    private static let wTurn2ID = UUID()
    private static let wTurn3ID = UUID()

    static let wideUser1 = ChatMessage(role: .user, text: "what's in the Q3 report?")
    static let wideUser2 = ChatMessage(role: .user, text: "and the contract — anything I should flag?")
    static let wideUser3 = ChatMessage(role: .user, text: "is any of this leaving my Mac?")

    static let wideAnswer1: ChatMessage = {
        let chunk = Chunk(
            sourceURL: denFiles[0], ordinal: 0,           // Q3 Report.pdf
            text: "Q3 revenue +23% YoY · net churn down to 2.1%. Highlights on slide 9.",
            locator: .textRange(charRange: 0..<70, lineRange: 9...12)
        )
        let citation = Citation(id: 1, chunk: StoredChunk(id: 1, chunk: chunk), score: 0.95)
        return ChatMessage(
            id: wTurn1ID, role: .assistant,
            text: "Revenue's up 23% year-over-year and net churn fell to 2.1% — the highlights are on slide 9. [1]",
            citations: [citation],
            isStreaming: false
        )
    }()

    static let wideAnswer2: ChatMessage = {
        let chunk = Chunk(
            sourceURL: denFiles[1], ordinal: 0,           // Contract.docx
            text: "Employment Agreement — monthly salary; 30-day notice; signature block blank.",
            locator: .textRange(charRange: 0..<78, lineRange: 4...9)
        )
        let citation = Citation(id: 1, chunk: StoredChunk(id: 1, chunk: chunk), score: 0.93)
        return ChatMessage(
            id: wTurn2ID, role: .assistant,
            text: "Monthly pay, they own work-hours output, 30-day notice. Heads up — the signature block's still blank. [1]",
            citations: [citation],
            isStreaming: false
        )
    }()

    static let wideAnswer3 = ChatMessage(
        id: wTurn3ID, role: .assistant,
        text: "Nope — every document was indexed and answered right here, on your Mac. Fully on-device. 🔒"
    )

    /// Wide Ask reveal phases (1–9): three q · thinking · answer beats.
    static func wideAskMessages(_ phase: Int) -> [ChatMessage] {
        switch phase {
        case 1: return [wideUser1]
        case 2: return [wideUser1, thinking(wTurn1ID)]
        case 3: return [wideUser1, wideAnswer1]
        case 4: return [wideUser1, wideAnswer1, wideUser2]
        case 5: return [wideUser1, wideAnswer1, wideUser2, thinking(wTurn2ID)]
        case 6: return [wideUser1, wideAnswer1, wideUser2, wideAnswer2]
        case 7: return [wideUser1, wideAnswer1, wideUser2, wideAnswer2, wideUser3]
        case 8: return [wideUser1, wideAnswer1, wideUser2, wideAnswer2, wideUser3, thinking(wTurn3ID)]
        case 9: return [wideUser1, wideAnswer1, wideUser2, wideAnswer2, wideUser3, wideAnswer3]
        default: return []
        }
    }
}

// MARK: - Backdrop chrome

private struct GridBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 32
            var p = Path()
            for x in stride(from: 0, through: size.width, by: spacing) {
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(Color.white.opacity(0.022)), lineWidth: 1)
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.clear, .black.opacity(0.85)]),
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: min(size.width, size.height) * 0.30,
                    endRadius: max(size.width, size.height) * 0.74
                )
            )
        }
    }
}

private struct AmbientHalo: View {
    let opacity: Double
    @State private var breathing = false
    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Reel.accentA.opacity(0.30), Reel.accentB.opacity(0.10), .clear],
                center: .center, startRadius: 0, endRadius: 300))
            .frame(width: 640, height: 640)
            .scaleEffect(breathing ? 1.05 : 0.95)
            .blur(radius: 30)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

private struct AppIconImage: View {
    let size: CGFloat
    var body: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 6)
                .shadow(color: Reel.accentA.opacity(0.30), radius: 18)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Reel.accentA, Reel.accentB],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
                .shadow(color: Reel.accentA.opacity(0.4), radius: 18)
        }
    }
}

private struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 8) {
            AppIconImage(size: 24)
            Text("FileMaster")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Reel.accentA.opacity(0.35), radius: 8)
        }
    }
}

private struct CaptionBadge: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Reel.accentB)
            Text(text)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.70))
                .overlay(Capsule().strokeBorder(Reel.accentA.opacity(0.45), lineWidth: 1))
                .shadow(color: Reel.accentA.opacity(0.30), radius: 10)
        )
        .fixedSize()
    }
}

private struct SparkleRing: View {
    private static let count = 14
    @State private var rotation: Double = 0
    @State private var pulsing = false
    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { i in
                let angle = Double(i) / Double(Self.count) * 360
                Circle()
                    .fill(Reel.accentB)
                    .frame(width: 4, height: 4)
                    .shadow(color: Reel.accentB.opacity(pulsing ? 0.8 : 0.4), radius: 6)
                    .opacity(pulsing ? 0.9 : 0.5)
                    .offset(x: 96, y: 0)
                    .rotationEffect(.degrees(angle))
            }
        }
        .rotationEffect(.degrees(rotation))
        .frame(width: 210, height: 210)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { rotation = 360 }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }
}

private struct Footer: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Reel.accentB).frame(width: 5, height: 5)
                .shadow(color: Reel.accentB, radius: 4)
            Text("BY  ANTI.LTD")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(3.5)
        }
    }
}

// MARK: - Director (NOT @MainActor — see file header)

@Observable
final class ReelDirector: @unchecked Sendable, ReelControl {

    // 0 compact den · 1 expanded grid · 2 list · 3 Ask
    var stage = 0
    var askPhase = 0             // Ask reveal: 0 none · 1 question · 2 thinking · 3 answer
    var denReveal = 0.0          // the den pops in (0→1)
    var denCount = 0             // cards landed in the compact den's stack (0→3)
    var denScale = 1.0           // bounces when a file lands / on a cut
    var cutFlash = 0.0           // accent flash on each whip cut
    var brandScale = 0.8         // brand lockup bounces in
    var montageOpacity = 1.0
    var haloOpacity = 0.55

    var bumperOpacity = 0.0
    var bumperScale = 0.8

    // Chat-only variants drop the file-drop intro, so they run shorter.
    let cycleLength = ReelDemo.current.chatOnly ? 12.5 : 15.5
    private var chatOnly: Bool { ReelDemo.current.chatOnly }

    private var events: [(t: Double, run: () -> Void)] = []
    private var elapsed = 0.0
    private var cycleStart: CFTimeInterval = 0
    private var ticker: Timer?
    private let audio = ReelAudio()

    static let captions: [(String, String)] = [
        ("bolt.fill",            "stash anything, instantly"),
        ("square.grid.2x2.fill", "all your files, one window"),
        ("list.bullet",          "names, sizes, actions"),
        ("sparkles",             "ask your docs · 100% on-device"),
    ]

    func showIdleFrame() {
        reset()
        stage = 1
        denReveal = 1.0
        denCount = ReelDemo.denFiles.count
        brandScale = 1.0
        montageOpacity = 1
    }

    func start() {
        ticker?.invalidate()
        reset()
        buildTimeline()
        cycleStart = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        audio.setVolume(1.0)
        showIdleFrame()
    }

    private func reset() {
        stage = 0; askPhase = 0
        denReveal = 0.0; denCount = 0
        denScale = 1.0
        cutFlash = 0; brandScale = 0.8
        montageOpacity = 1
        haloOpacity = 0.55
        bumperOpacity = 0; bumperScale = 0.8
        events = []; elapsed = 0
        audio.setVolume(1.0)
    }

    private func tick() {
        // Wall-clock based — robust to Timer slip under recording load. (If we
        // summed 1/60 per tick, a Timer throttled to 30 Hz by the compositing +
        // H.264 load would play the whole timeline at half speed.)
        elapsed = CACurrentMediaTime() - cycleStart
        while !events.isEmpty, events[0].t <= elapsed {
            events.removeFirst().run()
        }
        if elapsed >= cycleLength {
            reset(); buildTimeline()
            cycleStart = CACurrentMediaTime()
        }
    }

    private func at(_ t: Double, _ run: @escaping () -> Void) {
        let ev = (t: t, run: run)
        if let idx = events.firstIndex(where: { $0.t > t }) {
            events.insert(ev, at: idx)
        } else {
            events.append(ev)
        }
    }

    // A snappy whip-cut between real-UI stages: punch the den, flash the accent,
    // pulse the halo, swoosh. The kick lands from the four-on-the-floor pulse.
    private func cut(to s: Int) {
        stage = s                          // scene animates the transition on `stage`
        denPunch(1.10)
        flash()
        haloPulse()
        audio.play("whoosh")
    }

    private func denPunch(_ peak: Double) {
        denScale = peak                    // instant jump…
        withAnimation(.spring(response: 0.34, dampingFraction: 0.42)) { denScale = 1.0 } // …bouncy settle
    }

    private func flash() {
        cutFlash = 0.24
        withAnimation(.easeOut(duration: 0.45)) { cutFlash = 0 }
    }

    private func haloPulse() {
        haloOpacity = 0.95
        withAnimation(.easeOut(duration: 0.7)) { haloOpacity = 0.55 }
    }

    // MARK: - Timeline — beat-synced at 120 BPM (every 0.5 s); cuts land on the beat.

    private func buildTimeline() {
        if chatOnly { buildChatOnlyTimeline(); return }

        // Four-on-the-floor kick pulse drives the montage; cuts land on the beat.
        for i in 0...25 {                  // 0.5 … 13.0 s
            let t = 0.5 + Double(i) * 0.5
            at(t) { self.audio.play("kick", gain: 0.30) }
        }

        // ── Intro. The empty drop-target den pops in; the recorder's capture
        //    warm-up is absorbed by a settle delay BEFORE the timeline starts
        //    (see ReelRecorder), so the whole drop animation lands on tape. ──
        at(0.15) {
            self.audio.play("whoosh")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { self.brandScale = 1.0 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { self.denReveal = 1.0 }
            self.haloPulse()
        }

        // Files drop in on the beat and the stack BUILDS card by card, exactly
        // like the real den: the dashed drop-target gives way to one card, then a
        // fanned stack of three, then the "6 Files" subtitle. `denCount` (0→3) is
        // sprung so each card slides down into its slot — no remount, no flicker.
        for i in 0..<3 {
            at(1.0 + Double(i) * 0.5) {
                self.audio.play("thunk", gain: i == 2 ? 1.0 : 0.85)
                withAnimation(.spring(response: 0.44, dampingFraction: 0.68)) {
                    self.denCount = i + 1
                }
                self.denPunch(1.08)
            }
        }
        at(2.05) { self.audio.play("pop"); self.flash() }

        // ── Straight from the drop into the Ask exchange — the star of this
        //    TikTok cut. Two funny, grounded beats, each with a long beat to read. ──
        at(3.0) { self.cut(to: 3); self.askPhase = 1 }                   // question 1 slides in
        at(3.9) { self.askPhase = 2; self.audio.play("pop") }            // thinking…
        at(4.8) { self.askPhase = 3; self.audio.play("ding") }           // the rundown lands (cited)
        at(8.1) { self.askPhase = 4; self.audio.play("pop", gain: 0.6) } // "...keep pretending" (3.3s to read)
        at(8.7) { self.askPhase = 5 }                                    // thinking…
        at(9.6) { self.askPhase = 6; self.audio.play("ding") }           // on-device punchline

        // ── Riser into the closing bumper. ──
        at(12.9) { self.audio.play("riser") }                            // 3.3s to read the punchline
        at(13.2) { withAnimation(.easeIn(duration: 0.25)) { self.montageOpacity = 0 } }
        at(13.35) {
            self.audio.play("kick", gain: 0.9)
            self.audio.play("ding", gain: 0.7)
            self.haloOpacity = 1.0
            withAnimation(.easeOut(duration: 0.9)) { self.haloOpacity = 0.6 }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
                self.bumperOpacity = 1; self.bumperScale = 1.0
            }
        }

        // Audio fade — ends ≥0.15 s before the 15.5 s reset for a clean tail.
        let fadeSteps = 8
        for i in 0..<fadeSteps {
            let t = 14.2 + Double(i) * (1.0 / Double(fadeSteps))
            let vol = 1.0 - Double(i + 1) / Double(fadeSteps)
            at(t) { self.audio.setVolume(Float(vol)) }
        }
    }

    // MARK: - Chat-only timeline (cycleLength 12.5)
    //
    // No file-drop intro: open straight on the Ask card and let the two-beat
    // exchange carry the whole video, then the bumper. Same audio + bumper
    // machinery as the full timeline.
    private func buildChatOnlyTimeline() {
        // Light kick bed, stopping before the closing card.
        for i in 0...21 {
            let t = 0.5 + Double(i) * 0.5
            if t > 9.5 { break }
            at(t) { self.audio.play("kick", gain: 0.26) }
        }

        // Brand in, then the chat card whips on immediately.
        at(0.2) {
            self.audio.play("whoosh")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { self.brandScale = 1.0 }
            self.haloPulse()
        }
        at(0.5) { self.cut(to: 3); self.askPhase = 1 }                   // question 1 slides in
        at(1.3) { self.askPhase = 2; self.audio.play("pop") }           // thinking…
        at(2.2) { self.askPhase = 3; self.audio.play("ding") }          // the rundown lands (cited)
        at(5.5) { self.askPhase = 4; self.audio.play("pop", gain: 0.6) } // reply (3.3s to read)
        at(6.1) { self.askPhase = 5 }                                    // thinking…
        at(7.0) { self.askPhase = 6; self.audio.play("ding") }          // on-device punchline

        // ── Riser into the closing bumper (≈3s on the punchline). ──
        at(10.0) { self.audio.play("riser") }
        at(10.3) { withAnimation(.easeIn(duration: 0.25)) { self.montageOpacity = 0 } }
        at(10.45) {
            self.audio.play("kick", gain: 0.9)
            self.audio.play("ding", gain: 0.7)
            self.haloOpacity = 1.0
            withAnimation(.easeOut(duration: 0.9)) { self.haloOpacity = 0.6 }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
                self.bumperOpacity = 1; self.bumperScale = 1.0
            }
        }

        // Audio fade — ends ≥0.15 s before the 12.5 s reset.
        let fadeSteps = 8
        for i in 0..<fadeSteps {
            let t = 11.1 + Double(i) * (1.0 / Double(fadeSteps))
            let vol = 1.0 - Double(i + 1) / Double(fadeSteps)
            at(t) { self.audio.setVolume(Float(vol)) }
        }
    }
}

// MARK: - Real-UI stage cards

/// Wraps a real FileMaster view the way AppStageCapture does for screenshots:
/// an opaque window-coloured backing, clipped to a rounded card, forced dark.
private struct StageCard<Content: View>: View {
    let corner: CGFloat
    let content: Content
    init(corner: CGFloat = 24, @ViewBuilder _ content: () -> Content) {
        self.corner = corner; self.content = content()
    }
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
            .shadow(color: Reel.accentA.opacity(0.18), radius: 30)
    }
}

// MARK: - Scene content

struct ReelSceneContent: View {
    let director: ReelDirector

    // Built once on first render (main actor). Starts empty; the director drives
    // a staged reveal (question → thinking → answer) via `askPhase`.
    @State private var askSession = QASession(demoMessages: [], fileCount: 3)

    var body: some View {
        ZStack {
            Reel.bg
            GridBackground()
            AmbientHalo(opacity: director.haloOpacity)

            // Montage — brand, the live UI card, a caption, footer.
            VStack(spacing: 0) {
                Spacer().frame(height: 46)
                BrandLockup()
                    .scaleEffect(director.brandScale)
                Spacer().frame(height: 14)

                // Card zone — real UI whips through here, with a punch on cuts.
                ZStack {
                    if director.stage == 0 {
                        // The compact den, building its stack card by card as
                        // files drop in — same chrome, same StackedFilesView fan
                        // geometry, same thumbnail cards as the shipping den.
                        StageCard {
                            DropDen(count: director.denCount)
                        }
                        .scaleEffect(0.6 + 0.4 * director.denReveal)
                        .opacity(director.denReveal)
                    }
                    if director.stage == 1 {
                        StageCard { ShelfView(initialURLs: ReelDemo.denFiles,
                                              initiallyExpanded: true) }
                            .transition(stageTransition)
                    }
                    if director.stage == 2 {
                        StageCard { ShelfView(initialURLs: ReelDemo.denFiles,
                                              initiallyExpanded: true,
                                              initialViewMode: .list) }
                            .transition(stageTransition)
                    }
                    if director.stage == 3 {
                        StageCard(corner: 18) { QAView(session: askSession) }
                            .frame(width: 440, height: 436)
                            .scaleEffect(0.79)
                            .transition(stageTransition)
                    }
                }
                .frame(height: 432)
                .scaleEffect(director.denScale)
                .animation(.spring(response: 0.36, dampingFraction: 0.72), value: director.stage)

                Spacer().frame(height: 12)

                // Caption — informative, swaps with the stage.
                let cap = ReelDirector.captions[min(director.stage, ReelDirector.captions.count - 1)]
                CaptionBadge(symbol: cap.0, text: cap.1)
                    .id(director.stage)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: director.stage)

                Spacer()
                Footer()
                Spacer().frame(height: 26)
            }
            .frame(width: 360, height: 640)
            .opacity(director.montageOpacity)

            // Accent flash on each whip cut.
            Rectangle()
                .fill(Reel.accentB)
                .opacity(director.cutFlash)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // Closing bumper.
            VStack(spacing: 18) {
                ZStack {
                    SparkleRing()
                    AppIconImage(size: 116)
                }
                .frame(height: 200)
                VStack(spacing: 6) {
                    Text("FileMaster")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(
                            colors: [.white, .white.opacity(0.78)],
                            startPoint: .top, endPoint: .bottom))
                        .shadow(color: Reel.accentA.opacity(0.35), radius: 14)
                    Text("drag · drop · stash · ask · share")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Reel.accentB.opacity(0.9))
                        .tracking(1)
                    Text("BY  ANTI.LTD")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(5)
                        .padding(.top, 2)
                }
            }
            .scaleEffect(director.bumperScale)
            .opacity(director.bumperOpacity)
        }
        .frame(width: 360, height: 640)
        .clipped()
        // Drive the Ask transcript reveal off the director's phase.
        .onChange(of: director.askPhase) { _, phase in
            // Phases 3 & 6 fill an existing bubble in place (Thinking… → answer):
            // swap with animations disabled so the answer SNAPS in cleanly instead
            // of crossfading the placeholder against the answer text. Every other
            // phase adds a new bubble, which should slide in.
            if phase == 3 || phase == 6 {
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) { askSession.demoSet(ReelDemo.askMessages(phase)) }
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    askSession.demoSet(ReelDemo.askMessages(phase))
                }
            }
        }
    }

    // A horizontal whip: the incoming card snaps in from the trailing edge as
    // the outgoing one flies off the leading edge.
    private var stageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.9)).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
    }
}

// MARK: - Compact den with a card-by-card drop build
//
// A faithful rebuild of the shipping compact den (ShelfView's `compactView`):
// the same chrome, the same StackedFilesView fan (rotations [-8,-3,3] / offsets
// [(-6,6),(-2,2),(0,0)]), the same ThumbnailView cards. As `director.denCount`
// climbs 0→3 each card drops down into its slot and the dashed drop-target
// gives way to the stack — so it builds exactly the way the real den does when
// you drop files onto it, with no remount flicker and no empty-state showing
// through the incoming files.

private struct DropDen: View {
    let count: Int                  // cards landed so far (0…3)

    // Landing order = the real den's draw order (back → middle → front/top),
    // so the leading PDF lands last and sits on top, matching ShelfView's
    // `StackedFilesView` for these same files.
    private static let cards: [(url: URL, dx: CGFloat, dy: CGFloat, rot: Double)] = [
        (ReelDemo.denFiles[2], -6, 6, -8),   // back  — Release Notes.md
        (ReelDemo.denFiles[1], -2, 2, -3),   // middle — Contract.docx
        (ReelDemo.denFiles[0],  0, 0,  3),   // front — Q3 Report.pdf
    ]

    var body: some View {
        ZStack {
            // Match ShelfView's body fill so the tone is identical to the
            // expanded stages it whip-cuts to.
            RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.03))

            DropTarget()
                .opacity(count == 0 ? 1 : 0)
                .scaleEffect(count == 0 ? 1 : 1.12)
                .animation(.easeOut(duration: 0.3), value: count == 0)

            ForEach(Array(Self.cards.enumerated()), id: \.offset) { i, c in
                DropCard(url: c.url, dx: c.dx, dy: c.dy, rot: c.rot, landed: count > i)
                    .zIndex(Double(i))
            }

            chrome(count: count)
        }
        .frame(width: 200, height: 200)
        .environment(\.colorScheme, .dark)
    }

    // ×/＋ top, ✨ · wand bottom-left, ⋯ bottom-right, "N Files" centred — the
    // shipping compact den's controls, rendered as static visuals.
    @ViewBuilder
    private func chrome(count: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                glyph("xmark", size: 30, font: 12)
                Spacer()
                glyph("plus", size: 30, font: 14)
            }
            .padding(.horizontal, 12).padding(.top, 12)
            Spacer()
            HStack(spacing: 8) {
                glyph("sparkles", size: 28, font: 13, tint: Reel.accentA)
                glyph("wand.and.stars", size: 28, font: 13, tint: Reel.accentA)
                Spacer()
                glyph("ellipsis", size: 28, font: 13)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(width: 200, height: 200)

        Text("\(ReelDemo.denFiles.count) Files")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .opacity(count >= 3 ? 1 : 0)
            .animation(.easeIn(duration: 0.25), value: count >= 3)
            .frame(width: 200, height: 200, alignment: .bottom)
            .padding(.bottom, 15)
    }

    private func glyph(_ symbol: String, size: CGFloat, font: CGFloat,
                       tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.regularMaterial, in: Circle())
    }
}

/// The empty den's drop-target: the app's dashed well plus a soft, breathing
/// accent ring that invites a drop — without the harsh full-card blue border.
private struct DropTarget: View {
    @State private var breathe = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Reel.accentA.opacity(breathe ? 0.40 : 0.14), lineWidth: 2)
                .frame(width: 122, height: 122)
                .blur(radius: 6)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.30),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(width: 120, height: 120)
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary.opacity(0.30))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// One stacked file card. Pre-landing it sits just above the den (clipped away
/// by the StageCard); when `landed` flips it springs down into its fan slot —
/// reading as a file dropped onto the den.
///
/// Renders the crisp file-type icon directly (not ThumbnailView): the demo files
/// are empty, so QuickLook would thumbnail them as blank white pages — the type
/// icon is the clean, instantly-correct card the real den shows for these types.
private struct DropCard: View {
    let url: URL
    let dx: CGFloat
    let dy: CGFloat
    let rot: Double
    let landed: Bool

    private let nudgeY: CGFloat = -4   // the stack rides a touch above centre

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 78, height: 94)
            // No shadow while parked above the den — otherwise the blur bleeds
            // past the clip edge and you see a file's shadow before it drops in.
            .shadow(color: .black.opacity(landed ? 0.45 : 0), radius: landed ? 8 : 0,
                    x: 0, y: landed ? 5 : 0)
            .rotationEffect(.degrees(landed ? rot : rot - 12))
            .scaleEffect(landed ? 1 : 1.12)
            .offset(x: dx, y: nudgeY + (landed ? dy : dy - 150))
    }
}

struct ReelSceneViewBound: View {
    let director: ReelDirector
    var body: some View { ReelSceneContent(director: director) }
}

// MARK: - Holder

@Observable
final class ReelHolder: @unchecked Sendable {
    let director = ReelDirector()
    private var recorder: ReelRecorder?
    var isRecording = false
    var isPlaying = false

    init() { director.showIdleFrame() }

    func togglePlay() {
        if isPlaying { director.stop(); isPlaying = false }
        else { director.start(); isPlaying = true }
    }

    func toggleRecord() {
        if isRecording {
            recorder?.stopSync(); recorder = nil
            isRecording = false; director.stop(); isPlaying = false
        } else {
            director.stop(); director.start(); isPlaying = true
            let rec = ReelRecorder(
                control: director,
                designSize: CGSize(width: 360, height: 640),
                outputSize: CGSize(width: 1080, height: 1920),
                rootView: { [director] in AnyView(ReelSceneViewBound(director: director)) }
            )
            recorder = rec; isRecording = true
            Task { await rec.start() }
        }
    }
}

// MARK: - Preview window (manual use)

public struct ReelSceneView: View {
    @State private var holder = ReelHolder()
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ReelSceneContent(director: holder.director)
                .frame(width: 360, height: 640)

            HStack(spacing: 10) {
                Button(holder.isPlaying ? "⏸  Pause" : "▶  Play") { holder.togglePlay() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(holder.isRecording)

                Button(holder.isRecording ? "⏹  Stop Recording" : "⏺  Record 9:16") {
                    holder.toggleRecord()
                }
                .buttonStyle(.borderedProminent)
                .tint(holder.isRecording ? .red : .blue)
                .controlSize(.regular)

                Spacer()
                if holder.isRecording {
                    Text("Saving to Desktop…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.black)
        }
        .frame(width: 360)
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - Wide showcase (16:9, ~61 s, Reddit/YouTube)
//
// A landscape feature tour rendered with the REAL app views: drag-drop den →
// grid → list → actions (PDF/convert/zip) → image editor → on-device Ask →
// bumper. Reuses the portrait reel's backdrop chrome and the parameterized
// ReelRecorder. Driven by its own ~61 s timeline.
// ════════════════════════════════════════════════════════════════════════════

@Observable
final class WideDirector: @unchecked Sendable, ReelControl {
    // 0 intro/drop · 1 grid · 2 list · 3 actions · 4 editor · 5 ask
    var stage = 0
    var denReveal = 0.0
    var denCount = 0
    var denScale = 1.0
    var cutFlash = 0.0
    var brandScale = 0.8
    var haloOpacity = 0.55
    var montageOpacity = 1.0
    var actionsReveal = 0
    var bumperOpacity = 0.0
    var bumperScale = 0.8

    // Synthetic cursor that drives the tour so it feels used, not slideshowed.
    var cursorPos = CGPoint(x: 545, y: 312)
    var cursorVisible = false
    var cursorPressed = false
    var clickSeq = 0
    var clickAt = CGPoint.zero

    // Ask transcript, driven directly so answers stream in word by word.
    var askMessages: [ChatMessage] = []
    private var askAcc: [ChatMessage] = []

    let cycleLength = 60.0

    // Cursor targets in the 640×360 design space (approximate control positions
    // for the smaller, zoomed-out cards).
    static let denCenter = CGPoint(x: 320, y: 165)
    static let tabsList  = CGPoint(x: 336, y: 98)
    static let moreBtn   = CGPoint(x: 378, y: 240)
    static let itemMood  = CGPoint(x: 272, y: 200)
    static let edSliders = CGPoint(x: 452, y: 122)
    static let edImage   = CGPoint(x: 300, y: 165)
    static let askBtn    = CGPoint(x: 250, y: 238)
    static let askField  = CGPoint(x: 320, y: 236)

    private var events: [(t: Double, run: () -> Void)] = []
    private var elapsed = 0.0
    private var cycleStart: CFTimeInterval = 0
    private var ticker: Timer?
    private let audio = ReelAudio()

    static let captions: [(String, String)] = [
        ("bolt.fill",               "stash anything — just drag it in"),
        ("square.grid.2x2.fill",    "all your files, one window"),
        ("list.bullet",             "names, sizes, instant actions"),
        ("wand.and.stars",          "PDF tools · convert · zip — one click"),
        ("paintbrush.pointed.fill", "built-in image editor"),
        ("sparkles",                "ask your docs · 100% on-device"),
    ]

    func showIdleFrame() {
        reset(); stage = 1; denReveal = 1; brandScale = 1; montageOpacity = 1
    }

    func start() {
        ticker?.invalidate(); reset(); buildTimeline()
        cycleStart = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); ticker = t
    }

    func stop() { ticker?.invalidate(); ticker = nil; audio.setVolume(1.0); showIdleFrame() }

    private func reset() {
        stage = 0; denReveal = 0; denCount = 0; denScale = 1
        cutFlash = 0; brandScale = 0.8; haloOpacity = 0.55; montageOpacity = 1
        actionsReveal = 0; bumperOpacity = 0; bumperScale = 0.8
        cursorVisible = false; cursorPressed = false; clickSeq = 0
        cursorPos = CGPoint(x: 545, y: 312); clickAt = .zero
        askMessages = []; askAcc = []
        events = []; elapsed = 0; audio.setVolume(1.0)
    }

    private func tick() {
        elapsed = CACurrentMediaTime() - cycleStart
        while !events.isEmpty, events[0].t <= elapsed { events.removeFirst().run() }
        if elapsed >= cycleLength { reset(); buildTimeline(); cycleStart = CACurrentMediaTime() }
    }

    private func at(_ t: Double, _ run: @escaping () -> Void) {
        let ev = (t: t, run: run)
        if let idx = events.firstIndex(where: { $0.t > t }) { events.insert(ev, at: idx) }
        else { events.append(ev) }
    }

    private func cut(to s: Int) {
        withAnimation(.easeInOut(duration: 0.5)) { stage = s }
        denPunch(1.03); flash(); haloPulse(); audio.play("whoosh")
    }
    private func denPunch(_ peak: Double) {
        denScale = peak
        withAnimation(.spring(response: 0.34, dampingFraction: 0.45)) { denScale = 1.0 }
    }
    private func flash() { cutFlash = 0.12; withAnimation(.easeOut(duration: 0.45)) { cutFlash = 0 } }
    private func haloPulse() { haloOpacity = 0.9; withAnimation(.easeOut(duration: 0.7)) { haloOpacity = 0.55 } }

    private func moveCursor(_ to: CGPoint, _ dur: Double) {
        withAnimation(.easeInOut(duration: dur)) { cursorPos = to }
    }
    private func clickFX(_ p: CGPoint) {
        clickAt = p; clickSeq += 1
        cursorPressed = true
        withAnimation(.easeOut(duration: 0.16)) { cursorPressed = false }
        audio.play("pop", gain: 0.4)
    }
    /// Schedules one Q → thinking → streamed-answer beat; appends to `askAcc`.
    private func askBeat(user: ChatMessage, answer: ChatMessage,
                         q: Double, think: Double, stream: Double, per: Double) {
        at(q)     { self.audio.play("pop", gain: 0.6); self.askMessages = self.askAcc + [user] }
        at(think) { self.askMessages = self.askAcc + [user, ReelDemo.thinking(answer.id)] }
        let words = answer.text.split(separator: " ").map(String.init)
        for k in 1...words.count {
            at(stream + Double(k - 1) * per) {
                let partial = words.prefix(k).joined(separator: " ")
                let streaming = k < words.count
                self.askMessages = self.askAcc + [user,
                    ChatMessage(id: answer.id, role: .assistant, text: partial,
                                citations: streaming ? [] : answer.citations, isStreaming: streaming)]
                if k == 1 { self.audio.play("ding") }
            }
        }
        at(stream + Double(words.count) * per) { self.askAcc = self.askAcc + [user, answer] }
    }

    private func buildTimeline() {
        // Subtle kick bed (stops before the closing card).
        for i in 0...120 {
            let t = 0.5 + Double(i) * 0.5
            if t > 53 { break }
            at(t) { self.audio.play("kick", gain: 0.18) }
        }

        // ── Intro — brand + drag-drop build, then the cursor "clicks" to expand. ──
        at(0.3) {
            self.audio.play("whoosh")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { self.brandScale = 1.0 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { self.denReveal = 1.0 }
            self.haloPulse()
        }
        for i in 0..<3 {
            at(1.4 + Double(i) * 0.7) {
                self.audio.play("thunk", gain: i == 2 ? 1.0 : 0.85)
                withAnimation(.spring(response: 0.44, dampingFraction: 0.68)) { self.denCount = i + 1 }
                self.denPunch(1.08)
            }
        }
        at(3.0) { self.audio.play("pop"); self.flash() }
        at(3.8) { self.cursorVisible = true }
        at(4.0) { self.moveCursor(Self.denCenter, 1.4) }
        at(5.6) { self.clickFX(Self.denCenter) }
        at(5.75) { self.cut(to: 1) }                      // expand → grid

        // ── Grid → click the List tab. ──
        at(7.4) { self.moveCursor(Self.tabsList, 1.0) }
        at(8.7) { self.clickFX(Self.tabsList) }
        at(8.85) { self.cut(to: 2) }

        // ── List → hover rows, then the ⋯ actions button. ──
        at(10.2) { self.moveCursor(CGPoint(x: 300, y: 140), 0.7) }
        at(11.2) { self.moveCursor(CGPoint(x: 300, y: 185), 0.7) }
        at(12.4) { self.moveCursor(Self.moreBtn, 0.9) }
        at(13.6) { self.clickFX(Self.moreBtn) }
        at(13.75) { self.cut(to: 3) }
        for i in 0..<5 {
            at(14.1 + Double(i) * 0.45) {
                self.audio.play("pop", gain: 0.45)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { self.actionsReveal = i + 1 }
            }
        }
        at(16.6) { self.moveCursor(CGPoint(x: 398, y: 138), 0.55) }
        at(17.3) { self.moveCursor(CGPoint(x: 398, y: 162), 0.55) }
        at(18.0) { self.moveCursor(CGPoint(x: 398, y: 186), 0.55) }

        // ── Head to the image and double-click → editor. ──
        at(18.9) { self.moveCursor(Self.itemMood, 1.1) }
        at(20.2) { self.clickFX(Self.itemMood) }
        at(20.42) { self.clickFX(Self.itemMood) }          // double-click
        at(20.6) { self.cut(to: 4) }

        // ── Editor — glide over the controls / image to keep it alive. ──
        at(22.2) { self.moveCursor(Self.edSliders, 1.1) }
        at(23.6) { self.moveCursor(CGPoint(x: 470, y: 165), 0.8) }
        at(24.8) { self.moveCursor(Self.edImage, 1.3) }
        at(26.4) { self.moveCursor(CGPoint(x: 470, y: 108), 1.0) }   // tabs
        at(28.0) { self.moveCursor(Self.edImage, 1.3) }
        at(29.6) { self.moveCursor(CGPoint(x: 300, y: 210), 1.0) }
        at(30.6) { self.moveCursor(Self.askBtn, 1.0) }
        at(31.4) { self.clickFX(Self.askBtn) }
        at(31.55) { self.cut(to: 5); self.askAcc = [] }

        // ── Ask — answers stream in word by word; cursor rests by the field. ──
        at(32.1) { self.moveCursor(Self.askField, 1.0) }
        askBeat(user: ReelDemo.wideUser1, answer: ReelDemo.wideAnswer1, q: 32.5, think: 33.5, stream: 34.5, per: 0.13)
        at(37.0) { self.moveCursor(CGPoint(x: 300, y: 226), 0.8) }
        askBeat(user: ReelDemo.wideUser2, answer: ReelDemo.wideAnswer2, q: 39.8, think: 40.8, stream: 41.8, per: 0.13)
        at(44.4) { self.moveCursor(CGPoint(x: 340, y: 226), 0.8) }
        askBeat(user: ReelDemo.wideUser3, answer: ReelDemo.wideAnswer3, q: 47.0, think: 48.0, stream: 49.0, per: 0.13)
        at(50.8) { self.moveCursor(CGPoint(x: 320, y: 230), 0.8) }

        // ── Riser into the closing bumper. ──
        at(53.5) { self.audio.play("riser"); self.cursorVisible = false }
        at(54.0) { withAnimation(.easeIn(duration: 0.3)) { self.montageOpacity = 0 } }
        at(54.2) {
            self.audio.play("kick", gain: 0.9); self.audio.play("ding", gain: 0.7)
            self.haloOpacity = 1.0
            withAnimation(.easeOut(duration: 0.9)) { self.haloOpacity = 0.6 }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
                self.bumperOpacity = 1; self.bumperScale = 1.0
            }
        }

        let fadeSteps = 8
        for i in 0..<fadeSteps {
            let t = 57.6 + Double(i) * (1.0 / Double(fadeSteps))
            let vol = 1.0 - Double(i + 1) / Double(fadeSteps)
            at(t) { self.audio.setVolume(Float(vol)) }
        }
    }
}

// MARK: - Wide scene content

struct WideSceneContent: View {
    let director: WideDirector
    @State private var askSession = QASession(demoMessages: [], fileCount: 3)

    var body: some View {
        ZStack {
            Reel.bg
            GridBackground()
            AmbientHalo(opacity: director.haloOpacity)

            // Montage layer.
            ZStack {
                VStack { HStack { BrandLockup().scaleEffect(director.brandScale * 0.72); Spacer() }; Spacer() }
                    .padding(.leading, 24).padding(.top, 18)

                cardZone.scaleEffect(director.denScale)

                let cap = WideDirector.captions[min(director.stage, WideDirector.captions.count - 1)]
                VStack {
                    Spacer()
                    CaptionBadge(symbol: cap.0, text: cap.1)
                        .scaleEffect(0.62)
                        .id(director.stage)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: director.stage)
                    Spacer().frame(height: 18)
                }

                VStack { Spacer(); HStack { Spacer(); Footer().scaleEffect(0.8).padding(.trailing, 22).padding(.bottom, 14) } }
            }
            .frame(width: 640, height: 360)
            .opacity(director.montageOpacity)

            Rectangle().fill(Reel.accentB).opacity(director.cutFlash)
                .blendMode(.screen).allowsHitTesting(false)

            // Synthetic cursor, isolated in its own view so its continuous motion
            // only re-renders the pointer — NOT the heavy ShelfView/editor card.
            // (Reading cursorPos here would re-evaluate the whole scene body every
            // animation frame, which is what made the recording lag throughout.)
            CursorLayer(director: director)

            wideBumper
                .scaleEffect(director.bumperScale)
                .opacity(director.bumperOpacity)
        }
        .frame(width: 640, height: 360)
        .clipped()
        .onChange(of: director.askMessages) { _, msgs in
            // A brand-new question bubble slides in; streamed answer tokens snap
            // (so the text just grows, no per-token crossfade).
            let newUser = msgs.count > askSession.messages.count && msgs.last?.role == .user
            if newUser {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { askSession.demoSet(msgs) }
            } else {
                var txn = Transaction(); txn.disablesAnimations = true
                withTransaction(txn) { askSession.demoSet(msgs) }
            }
        }
    }

    @ViewBuilder private var cardZone: some View {
        ZStack {
            switch director.stage {
            case 0:
                StageCard { DropDen(count: director.denCount) }
                    .scaleEffect(0.78 * (0.6 + 0.4 * director.denReveal))
                    .opacity(director.denReveal)
            case 1:
                StageCard { ShelfView(initialURLs: ReelDemo.denFiles, initiallyExpanded: true) }
                    .scaleEffect(0.4)
                    .transition(stageTransition)
            case 2:
                StageCard { ShelfView(initialURLs: ReelDemo.denFiles,
                                      initiallyExpanded: true, initialViewMode: .list) }
                    .scaleEffect(0.4)
                    .transition(stageTransition)
            case 3:
                ZStack {
                    StageCard { ShelfView(initialURLs: ReelDemo.denFiles,
                                          initiallyExpanded: true, initialViewMode: .list) }
                        .scaleEffect(0.32).opacity(0.45)
                        .offset(x: -128)
                    ActionsMenu(revealed: director.actionsReveal).scaleEffect(0.72).offset(x: 78, y: 4)
                }
                .transition(stageTransition)
            case 4:
                StageCard(corner: 16) {
                    ShelfView(initialURLs: ReelDemo.denFiles,
                              initiallyEditingURL: ReelDemo.denFiles[3])
                }
                .scaleEffect(0.27)
                .transition(stageTransition)
            default:
                StageCard(corner: 14) { QAView(session: askSession) }
                    .frame(width: 600, height: 360)
                    .scaleEffect(0.46)
                    .transition(stageTransition)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: director.stage)
    }

    // A soft cross-dissolve + slight zoom (a morph, not a hard slide).
    private var stageTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96))
    }

    private var wideBumper: some View {
        VStack(spacing: 14) {
            ZStack { SparkleRing(); AppIconImage(size: 84) }
                .frame(height: 150)
            Text("FileMaster")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.78)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Reel.accentA.opacity(0.35), radius: 14)
            Text("drag · drop · stash · ask · share")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Reel.accentB.opacity(0.9)).tracking(1)
            Text("BY  ANTI.LTD")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.5)).tracking(5).padding(.top, 2)
        }
    }
}

/// A faithful, static replica of the den's actions menu — shows the breadth of
/// PDF tools / conversions / zip in one popover, revealed row by row.
private struct ActionsMenu: View {
    let revealed: Int
    private static let items: [(String, String)] = [
        ("sparkles",                     "Ask AI about these"),
        ("arrow.2.squarepath",           "Convert format"),
        ("doc.on.doc",                   "Split PDF pages"),
        ("doc.text.magnifyingglass",     "Extract text & images"),
        ("archivebox",                   "Zip & share"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
            ForEach(Array(Self.items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 11) {
                    Image(systemName: it.0)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(i == 0 ? Reel.accentA : .primary.opacity(0.85))
                        .frame(width: 18)
                    Text(it.1).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .opacity(revealed > i ? 1 : 0)
                .offset(y: revealed > i ? 0 : 6)
            }
        }
        .frame(width: 232)
        .padding(.bottom, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
    }
}

/// Classic macOS pointer, drawn as a path (an SF Symbol "cursorarrow.fill"
/// doesn't exist, so a custom shape is the reliable way to always render it).
/// Tip sits at (0,0) of the unit box.
private struct CursorArrow: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0,        y: h * 0.74))
        p.addLine(to: CGPoint(x: w * 0.21, y: h * 0.56))
        p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.93))
        p.addLine(to: CGPoint(x: w * 0.47, y: h * 0.86))
        p.addLine(to: CGPoint(x: w * 0.33, y: h * 0.50))
        p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.47))
        p.closeSubpath()
        return p
    }
}

/// Isolates all cursor state reads so the continuously-animating pointer only
/// invalidates itself — the expensive scene card never re-evaluates for it.
private struct CursorLayer: View {
    let director: WideDirector
    var body: some View {
        ZStack {
            if director.cursorVisible {
                if director.clickSeq > 0 {
                    ClickRipple(pos: director.clickAt).id(director.clickSeq)
                }
                WideCursor(pos: director.cursorPos, pressed: director.cursorPressed)
            }
        }
        .frame(width: 640, height: 360)
        .allowsHitTesting(false)
    }
}

/// The synthetic pointer that tours the UI. The arrow's tip is placed exactly
/// at `pos`.
private struct WideCursor: View {
    let pos: CGPoint
    let pressed: Bool
    var body: some View {
        CursorArrow()
            .fill(.white)
            .overlay(CursorArrow().stroke(Color.black.opacity(0.55), lineWidth: 1))
            .frame(width: 17, height: 25)
            .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 2)
            .scaleEffect(pressed ? 0.8 : 1.0, anchor: .topLeading)
            .position(pos)
            .offset(x: 8.5, y: 12.5)        // shift so the tip lands on `pos`
            .allowsHitTesting(false)
    }
}

/// A quick accent ripple where the cursor clicks. Re-mounted per click via `.id`.
private struct ClickRipple: View {
    let pos: CGPoint
    @State private var go = false
    var body: some View {
        Circle()
            .stroke(Reel.accentB, lineWidth: 2)
            .frame(width: 26, height: 26)
            .scaleEffect(go ? 1.7 : 0.3)
            .opacity(go ? 0 : 0.85)
            .position(pos)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { go = true } }
    }
}

struct WideSceneViewBound: View {
    let director: WideDirector
    var body: some View { WideSceneContent(director: director) }
}

#endif
