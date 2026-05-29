// Reel showcase — compiled only in `--showcase` builds (FILEMASTER_SHOWCASE).
// See Makefile: `make showcase`. Never included in production builds.
//
// FileMaster has no sound engine of its own (it's a file shelf, not a synth),
// so the reel ships its own tiny procedural SFX kit. Every sound is generated
// from a handful of numbers at init — no audio files in the bundle — then
// played through a round-robin pool of AVAudioPlayerNodes under a lock.
//
// NOT @MainActor: the director's Timer callback plays these directly without an
// actor hop (see ReelScene.swift header for the macOS 26.5 concurrency note).

#if FILEMASTER_SHOWCASE

import AVFoundation
import Foundation

final class ReelAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private let lock = NSLock()
    private let voiceCount = 10
    private let sampleRate = 44_100.0
    private let format: AVAudioFormat

    // Pre-rendered, named one-shots. Keyed by the same string the timeline uses.
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            players.append(node)
        }
        renderKit()
        engine.prepare()
        try? engine.start()
    }

    // MARK: - Playback

    func play(_ name: String, gain: Float = 1.0) {
        guard let buffer = buffers[name] else { return }
        lock.lock()
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % voiceCount
        lock.unlock()
        player.volume = gain
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func setVolume(_ v: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, v))
    }

    // MARK: - Synthesis
    //
    // Each sound is a closure (frameIndex, t-seconds) -> sample in [-1, 1].
    // Kept deliberately simple: a body oscillator, an envelope, a touch of
    // noise where a real object would have transient grit.

    // A band-limited-ish white noise sample. Kept as a tiny helper so the
    // synthesis closures stay simple (the Swift type-checker times out on long
    // mixed Double/Float expressions, so each step below is explicit Double).
    private func noise() -> Double { Double.random(in: -1...1) }

    private func renderKit() {
        let twoPi = 2.0 * Double.pi

        // A soft "dock" — a file card landing in the den. Low body + click.
        buffers["thunk"] = render(seconds: 0.28) { _, t in
            let body: Double = sin(twoPi * 138.0 * t) * exp(-t * 26.0)
            let click: Double = self.noise() * exp(-t * 150.0) * 0.5
            return Float((body + click) * 0.9)
        }

        // A quick UI "pop" for badge swaps and chip reveals.
        buffers["pop"] = render(seconds: 0.12) { _, t in
            let f: Double = 520.0 + 900.0 * exp(-t * 40.0)   // tiny upward chirp
            let s: Double = sin(twoPi * f * t) * exp(-t * 38.0)
            return Float(s * 0.55)
        }

        // A swoosh for the den entrance / transitions — filtered noise swell.
        buffers["whoosh"] = render(seconds: 0.42) { _, t in
            let env: Double = sin(Double.pi * min(t / 0.42, 1.0))
            return Float(self.noise() * env * 0.28)
        }

        // The sparkle "ding" for the AI answer landing — a small two-tone bell.
        buffers["ding"] = render(seconds: 0.6) { _, t in
            let a: Double = sin(twoPi * 988.0 * t)           // B5
            let b: Double = sin(twoPi * 1480.0 * t)          // ~F#6
            let env: Double = exp(-t * 7.0)
            return Float((a * 0.6 + b * 0.4) * env * 0.5)
        }

        // A short typing tick for the hook typewriter.
        buffers["type"] = render(seconds: 0.05) { _, t in
            return Float(self.noise() * exp(-t * 220.0) * 0.4)
        }

        // The stamp slam — a meaty low impact for the competitor jab.
        buffers["slam"] = render(seconds: 0.5) { _, t in
            let body: Double = sin(twoPi * 92.0 * t) * exp(-t * 12.0)
            let crack: Double = self.noise() * exp(-t * 60.0) * 0.8
            return Float((body * 1.1 + crack) * 0.95)
        }

        // A bass pulse to give the montage a heartbeat.
        buffers["bass"] = render(seconds: 0.4) { _, t in
            let s: Double = sin(twoPi * 74.0 * t) * exp(-t * 7.0)
            return Float(s * 0.5)
        }

        // A punchy kick — pitch-drops 160→50 Hz. The four-on-the-floor pulse
        // the cuts land on, so the reel reads as beat-synced.
        buffers["kick"] = render(seconds: 0.2) { _, t in
            let f: Double = 50.0 + 110.0 * exp(-t * 45.0)
            let s: Double = sin(twoPi * f * t) * exp(-t * 15.0)
            return Float(s * 0.85)
        }

        // A noise riser that swells into the closing bumper for impact.
        buffers["riser"] = render(seconds: 0.6) { _, t in
            let env: Double = pow(t / 0.6, 2.2)          // accelerating swell
            let tone: Double = sin(twoPi * (300.0 + 1400.0 * (t / 0.6)) * t) * 0.3
            return Float((self.noise() * 0.7 + tone) * env * 0.4)
        }
    }

    private func render(seconds: Double, _ sample: (Int, Double) -> Float) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            ptr[i] = sample(i, t)
        }
        return buffer
    }
}

#endif
