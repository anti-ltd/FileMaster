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
    // extension via NSWorkspace, so empty content is fine.
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

    static let denFiles = make([
        ("Q3 Report.pdf", 1_840_000), ("Brand Moodboard.png", 3_200_000),
        ("Contract.docx", 246_000), ("Release Notes.md", 8_200),
        ("assets.zip", 12_400_000), ("walkthrough.mov", 47_500_000),
    ])

    // A real Markdown file behind the cited answer, so the citation chip
    // resolves like any grounded source.
    static let shootoutDoc: URL = {
        let url = dir.appendingPathComponent("Tool Shootout.md")
        let body = """
        # FileMaster vs the field

        - Dropover: a shelf, and not much else.
        - FilePane: handy, but the UI hasn't changed since 2015.
        - NotebookLM: powerful, but you upload everything to the cloud and wait.

        FileMaster keeps the shelf, PDF tools, conversions, an image editor and
        on-device Ask in a single floating window.
        """
        try? body.data(using: .utf8)?.write(to: url)
        return url
    }()

    // Transcript split into stages so the reel can animate it: the user asks,
    // the model "thinks", then the cited answer (with its hidden jabs) lands.
    static let askUser = ChatMessage(role: .user, text: "honestly — why use this over the others?")
    static let askThinking = ChatMessage(role: .assistant, text: "", isStreaming: true)
    static var askAnswer: ChatMessage {
        let chunk = Chunk(
            sourceURL: shootoutDoc, ordinal: 0,
            text: "FileMaster keeps the shelf, PDF tools, conversions, an image editor and on-device Ask in a single floating window.",
            locator: .textRange(charRange: 0..<180, lineRange: 3...8)
        )
        let citation = Citation(id: 1, chunk: StoredChunk(id: 1, chunk: chunk), score: 0.95)
        return ChatMessage(
            role: .assistant,
            text: "It's all in one floating den: stash, zip, convert, edit, and ask your docs — on-device. No uploading to the cloud and waiting like NotebookLM, none of FilePane's 2015 UI, and unlike Dropover it does more than just hold your files.",
            citations: [citation],
            isStreaming: false
        )
    }

    /// Messages for a given Ask reveal phase (0 none · 1 question · 2 thinking · 3 answer).
    static func askMessages(_ phase: Int) -> [ChatMessage] {
        switch phase {
        case 1: return [askUser]
        case 2: return [askUser, askThinking]
        case 3: return [askUser, askAnswer]
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
final class ReelDirector: @unchecked Sendable {

    // 0 compact den · 1 expanded grid · 2 list · 3 Ask
    var stage = 0
    var askPhase = 0             // Ask reveal: 0 none · 1 question · 2 thinking · 3 answer
    var denReveal = 0.0          // den pops in (0→1)
    var denCount = 0             // how many files the REAL den currently holds (grows as they land)
    var dropActive = false       // files-flying-in overlay is in the tree
    var denScale = 1.0           // bounces when a file lands / on a cut
    var cutFlash = 0.0           // accent flash on each whip cut
    var brandScale = 0.8         // brand lockup bounces in
    var montageOpacity = 1.0
    var haloOpacity = 0.55

    var bumperOpacity = 0.0
    var bumperScale = 0.8

    let cycleLength = 12.5

    private var events: [(t: Double, run: () -> Void)] = []
    private var elapsed = 0.0
    private var cycleStart: CFTimeInterval = 0
    private var ticker: Timer?
    private let audio = ReelAudio()

    static let captions: [(String, String)] = [
        ("bolt.fill",            "stash anything, instantly"),
        ("square.grid.2x2.fill", "grid or list, your call"),
        ("list.bullet",          "names, sizes, actions"),
        ("sparkles",             "ask about your docs · on-device"),
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
        denReveal = 0.0; denCount = 0; dropActive = false
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
        // Four-on-the-floor kick pulse drives the montage; cuts land on the beat.
        for i in 0...19 {                  // 0.5 … 10.0 s
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
        at(0.9) { self.dropActive = true }  // launch the flying files

        // Each file flies into the den and the REAL den's count grows with it —
        // so the stack you see building is the genuine StackedFilesView, not a
        // mock. Three deliveries take it to all 6 files.
        for (i, spec) in [(1.45, 2), (1.95, 4), (2.45, 6)].enumerated() {
            at(spec.0) {
                self.audio.play("thunk", gain: i == 2 ? 1.0 : 0.85)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
                    self.denCount = spec.1
                }
                self.denPunch(1.12)
            }
        }

        at(2.9) {
            self.audio.play("pop")
            self.dropActive = false     // flyers cleared; the real filled den remains
            self.flash()
        }

        // ── Beat-synced feature whips. ──
        at(4.0) { self.cut(to: 1) }        // expanded grid
        at(5.5) { self.cut(to: 2) }        // list

        // ── Ask — the headline, given room to breathe and revealed turn-by-turn. ──
        at(7.0) {
            self.cut(to: 3)
            self.askPhase = 1              // the question slides in
        }
        at(7.7) { self.askPhase = 2; self.audio.play("pop") }                       // "Thinking…"
        at(8.5) { self.askPhase = 3; self.audio.play("ding"); self.denPunch(1.05) } // answer lands

        // ── Riser into the closing bumper. ──
        at(10.0) { self.audio.play("riser") }
        at(10.5) { withAnimation(.easeIn(duration: 0.25)) { self.montageOpacity = 0 } }
        at(10.65) {
            self.audio.play("kick", gain: 0.9)
            self.audio.play("ding", gain: 0.7)
            self.haloOpacity = 1.0
            withAnimation(.easeOut(duration: 0.9)) { self.haloOpacity = 0.6 }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
                self.bumperOpacity = 1; self.bumperScale = 1.0
            }
        }

        // Audio fade — ends ≥0.15 s before the 12.5 s reset for a clean tail.
        let fadeSteps = 8
        for i in 0..<fadeSteps {
            let t = 11.3 + Double(i) * (1.0 / Double(fadeSteps))
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
                        // The REAL den, its item count growing as files land —
                        // empty dashed drop-target → stack → "6 Files". Every
                        // frame is the genuine ShelfView, so it matches the rest.
                        StageCard {
                            ShelfView(initialURLs: Array(ReelDemo.denFiles.prefix(director.denCount)),
                                      initiallyExpanded: false,
                                      initiallyTargeted: director.denCount == 0)
                        }
                        .id(director.denCount)
                        .transition(.opacity)
                        .scaleEffect(0.6 + 0.4 * director.denReveal)
                        .opacity(director.denReveal)
                        .animation(.easeInOut(duration: 0.25), value: director.denCount)
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

            // Intro: files fly in and drop into the den (the den's real count
            // grows to meet each one).
            if director.dropActive {
                DropOverlay()
                    .opacity(director.montageOpacity)
                    .allowsHitTesting(false)
            }

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
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                askSession.demoSet(ReelDemo.askMessages(phase))
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

// MARK: - Flying-files drop intro
//
// Each file flies in from an edge and *settles onto a growing stack* using the
// real den's StackedFilesView geometry (same rotations/offsets, same
// ThumbnailView cards, same files) — so the suck-in literally builds the stack
// the app shows, then hands off seamlessly to the real filled den underneath.

private struct DropOverlay: View {
    // The den's stack centre in the 360×640 design space.
    private static let target = CGPoint(x: 180, y: 300)
    // One flyer per delivery; each carries a distinct, real file thumbnail.
    private static let urls: [URL] = (0..<3).map { ReelDemo.denFiles[$0] }
    private static let starts: [CGPoint] = [
        CGPoint(x: 300, y: -130),   // drops from the top-right
        CGPoint(x: -100, y: 430),   // swoops in from the bottom-left
        CGPoint(x: 470, y: 250),    // flies in from the right
    ]
    private static let spin: [Double] = [-26, 22, 16]
    private static let land: [Double] = [4, -3, 6]   // tiny settle angle
    // Lands at 1.45 / 1.95 / 2.45 s (dropActive fires at 0.9; flight ≈ 0.55 s).
    private static let delays: [Double] = [0.0, 0.5, 1.0]

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                FlyingFile(
                    url: Self.urls[i],
                    start: Self.starts[i],
                    end: Self.target,
                    startSpin: Self.spin[i],
                    landRotation: Self.land[i],
                    delay: Self.delays[i]
                )
                .zIndex(Double(i))
            }
        }
        .frame(width: 360, height: 640)
    }
}

private struct FlyingFile: View {
    let url: URL
    let start: CGPoint
    let end: CGPoint
    let startSpin: Double
    let landRotation: Double
    let delay: Double
    @State private var arrived = false
    @State private var gone = false

    var body: some View {
        // The same card the real StackedFilesView draws, so as it fades the den's
        // real stack (growing underneath) takes its place seamlessly.
        ThumbnailView(url: url, size: CGSize(width: 140, height: 172), contentMode: .fill)
            .frame(width: 72, height: 88)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .shadow(color: Reel.accentA.opacity(gone ? 0 : 0.55), radius: 16)
            .rotationEffect(.degrees(arrived ? landRotation : startSpin))
            .scaleEffect(arrived ? (gone ? 0.85 : 1.0) : 1.35)
            .opacity(gone ? 0 : 1)                       // stays opaque the whole flight…
            .position(arrived ? end : start)
            .onAppear {
                // …then fades only once it lands, as the real stack card appears.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(delay)) {
                    arrived = true
                } completion: {
                    withAnimation(.easeIn(duration: 0.2)) { gone = true }
                }
            }
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
            let rec = ReelRecorder(director: director)
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

#endif
