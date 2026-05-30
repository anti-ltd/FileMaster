import SwiftUI
import AppKit

/// Controls for the on-device **Vectorize** action, shown in a popover off the
/// actions menu (mirrors `ImageUpscalePanel`). Pick how many colours to trace and
/// how much contour detail to keep, then hand the chosen ``RasterVectorizer/Options``
/// back to the caller, which stages the resulting `.svg` into a new den. Best for
/// flat artwork — the hint says so, since photos vectorize poorly.
struct ImageVectorizePanel: View {
    let urls: [URL]
    let onVectorize: (RasterVectorizer.Options) -> Void
    let onCancel: () -> Void

    @State private var colorCount: Double = 6
    @State private var detail: Double = 0.5

    private var first: URL { urls[0] }

    private var options: RasterVectorizer.Options {
        var o = RasterVectorizer.Options()
        o.colorCount = Int(colorCount.rounded())
        o.detail = detail
        return o
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Colors").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(colorCount.rounded()))")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Slider(value: $colorCount, in: 2...12, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Detail").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((detail * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Slider(value: $detail, in: 0...1)
            }

            Label("Best for logos, icons and flat illustrations. Photos trace poorly.",
                  systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Vectorize") { onVectorize(options) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            if let img = NSImage(contentsOf: first) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(urls.count == 1 ? first.lastPathComponent : "\(urls.count) images")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("Raster → SVG · on-device").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
