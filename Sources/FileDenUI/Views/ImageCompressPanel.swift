import SwiftUI
import AppKit

/// Interactive compression controls shown in a popover off the actions menu.
///
/// Two ways to drive the squeeze: dial **Quality** directly, or pin a **Max
/// size** and let the encoder binary-search quality to fit. Either way you can
/// resize the pixels and choose the output format. A live readout re-encodes the
/// first image in the background as you drag, so the result size is real, not a
/// guess. Hands the chosen ``ImageCompress/Options`` back to the caller.
struct ImageCompressPanel: View {
    let urls: [URL]
    let onCompress: (ImageCompress.Options) -> Void
    let onCancel: () -> Void

    private enum Method: Hashable { case quality, size }

    @State private var method: Method = .quality
    @State private var quality: Double = 0.8
    @State private var sizePos: Double = 0.5          // log-mapped slider position
    @State private var scale: Double = 1.0
    @State private var format: ImageConvert.Format = .jpeg

    @State private var estimate: (bytes: Int, pixels: CGSize)?
    @State private var estimating = false

    /// Lossy targets the encoder can actually write on this machine.
    private static let formats: [ImageConvert.Format] =
        [.jpeg, .heic, .webp, .avif].filter { ImageConvert.canEncode($0) }

    private var first: URL { urls[0] }
    private var source: (pixels: CGSize, bytes: Int)? { ImageCompress.sourceInfo(first) }

    /// 20 KB … 25 MB, spaced logarithmically so the low end has real resolution.
    private var targetBytes: Int { Int(20_000 * pow(1250, sizePos)) }

    private var options: ImageCompress.Options {
        var o = ImageCompress.Options()
        o.format = format
        o.scale = scale
        o.quality = quality
        o.targetBytes = method == .size ? targetBytes : nil
        return o
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("", selection: $method) {
                Text("Quality").tag(Method.quality)
                Text("Max size").tag(Method.size)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if method == .quality {
                sliderRow(title: "Quality", value: percent(quality)) {
                    Slider(value: $quality, in: 0.05...1.0)
                }
            } else {
                sliderRow(title: "Max size", value: fmtBytes(targetBytes)) {
                    Slider(value: $sizePos, in: 0...1)
                }
            }

            sliderRow(title: "Resize", value: scaledDims) {
                Slider(value: $scale, in: 0.1...1.0)
            }

            HStack {
                Text("Format").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $format) {
                    ForEach(Self.formats, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Divider().opacity(0.5)
            resultRow

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Compress") { onCompress(options) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task(id: options) { await refreshEstimate() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            if let img = NSImage(contentsOf: first) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(urls.count == 1 ? first.lastPathComponent : "\(urls.count) images")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let s = source {
                    Text("\(dims(s.pixels)) · \(fmtBytes(s.bytes))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Result readout

    @ViewBuilder
    private var resultRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Result").font(.system(size: 11)).foregroundStyle(.secondary)
                if let e = estimate {
                    Text(dims(e.pixels)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if estimating && estimate == nil {
                ProgressView().controlSize(.small)
            } else if let e = estimate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("≈ \(fmtBytes(e.bytes))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .opacity(estimating ? 0.5 : 1)
                    savings(e.bytes)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: estimate?.bytes)
    }

    /// Percentage smaller (green) or larger (orange) than the source.
    @ViewBuilder
    private func savings(_ bytes: Int) -> some View {
        if let orig = source?.bytes, orig > 0 {
            let delta = Double(orig - bytes) / Double(orig)
            let pct = Int((abs(delta) * 100).rounded())
            Text(delta >= 0 ? "−\(pct)%" : "+\(pct)%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(delta >= 0 ? Color.green : Color.orange)
        }
    }

    // MARK: - Slider row

    @ViewBuilder
    private func sliderRow<S: View>(title: String, value: String,
                                    @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            slider()
        }
    }

    // MARK: - Live estimate

    private func refreshEstimate() async {
        estimating = true
        try? await Task.sleep(for: .milliseconds(220))   // debounce drags
        if Task.isCancelled { return }
        let opts = options
        let url = first
        let result = await Task.detached(priority: .userInitiated) {
            ImageCompress.estimate(url, options: opts)
        }.value
        if Task.isCancelled { return }
        estimate = result
        estimating = false
    }

    // MARK: - Formatting

    private var scaledDims: String {
        guard let p = source?.pixels else { return "\(Int(scale * 100))%" }
        let w = Int((p.width * scale).rounded()), h = Int((p.height * scale).rounded())
        return "\(w)×\(h)"
    }

    private func dims(_ s: CGSize) -> String { "\(Int(s.width))×\(Int(s.height))" }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func fmtBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Owns the lone action popover (compress, resize, …) so the SwiftUI panel it
/// hosts survives the menu that spawned it — the menu and its `ActionBridge`
/// deallocate the instant an item is clicked.
@MainActor
final class ActionPopover {
    static let shared = ActionPopover()
    private var popover: NSPopover?

    func dismiss() { popover?.performClose(nil); popover = nil }

    func present<Content: View>(from host: NSView, @ViewBuilder _ content: () -> Content) {
        dismiss()
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSHostingController(rootView: content())
        vc.sizingOptions = [.preferredContentSize]
        pop.contentViewController = vc
        popover = pop

        pop.show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
        // Accessory apps open popovers unfocused; activate so the controls take input.
        NSApp.activate(ignoringOtherApps: true)
        vc.view.window?.makeKey()
    }
}
