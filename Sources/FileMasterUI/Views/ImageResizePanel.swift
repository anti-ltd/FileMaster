import SwiftUI
import AppKit

/// Interactive resize controls shown in a popover off the actions menu.
///
/// Four ways to specify the target, all aspect-preserving: pin **Width**, pin
/// **Height**, scale by **%**, or fit the **Longest** side to a box. A numeric
/// field gives exact control; the slider is for quick drags. The output size
/// updates live (it's deterministic, so no re-encode needed). Hands the chosen
/// ``ImageResize/Mode`` back to the caller.
struct ImageResizePanel: View {
    let urls: [URL]
    let onResize: (ImageResize.Mode) -> Void
    let onCancel: () -> Void

    private enum Axis: Hashable { case width, height, percent, longest }

    @State private var axis: Axis = .width
    @State private var widthPx: Double = 800
    @State private var heightPx: Double = 800
    @State private var longestPx: Double = 800
    @State private var percent: Double = 100
    @State private var didInit = false

    private var first: URL { urls[0] }
    private var source: (pixels: CGSize, bytes: Int)? { ImageCompress.sourceInfo(first) }

    private var mode: ImageResize.Mode {
        switch axis {
        case .width:   return .width(Int(widthPx.rounded()))
        case .height:  return .height(Int(heightPx.rounded()))
        case .percent: return .percent(percent)
        case .longest: return .longest(Int(longestPx.rounded()))
        }
    }

    private var valueBinding: Binding<Double> {
        switch axis {
        case .width:   return $widthPx
        case .height:  return $heightPx
        case .percent: return $percent
        case .longest: return $longestPx
        }
    }

    private var unit: String { axis == .percent ? "%" : "px" }

    private var sliderRange: ClosedRange<Double> {
        if axis == .percent { return 1...400 }
        let maxDim = max(source?.pixels.width ?? 4000, source?.pixels.height ?? 4000)
        return 16...max(maxDim * 2, 4000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("", selection: $axis) {
                Text("Width").tag(Axis.width)
                Text("Height").tag(Axis.height)
                Text("%").tag(Axis.percent)
                Text("Longest").tag(Axis.longest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(axis == .percent ? "Scale" : "Target")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    TextField("", value: valueBinding, formatter: formatter)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)
                }
                Slider(value: valueBinding, in: sliderRange)
            }

            Divider().opacity(0.5)
            resultRow

            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Resize") { onResize(mode) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear(perform: seedDefaults)
    }

    // MARK: - Header

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
                if let s = source {
                    Text(dims(s.pixels)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Output readout

    @ViewBuilder
    private var resultRow: some View {
        HStack {
            Text("New size").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let p = source?.pixels {
                let t = ImageResize.target(for: p, mode: mode)
                Text(dims(t))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: t.width)
                    .animation(.easeInOut(duration: 0.15), value: t.height)
            }
        }
    }

    // MARK: - Helpers

    /// Seed the fields from the first image so the panel opens at sensible values
    /// (current width/height, 100%, current longest side) instead of guesses.
    private func seedDefaults() {
        guard !didInit, let p = source?.pixels else { return }
        widthPx = Double(Int(p.width))
        heightPx = Double(Int(p.height))
        longestPx = Double(Int(max(p.width, p.height)))
        percent = 100
        didInit = true
    }

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = axis == .percent ? 1 : 0
        f.minimum = 1
        return f
    }

    private func dims(_ s: CGSize) -> String { "\(Int(s.width))×\(Int(s.height))" }
}
