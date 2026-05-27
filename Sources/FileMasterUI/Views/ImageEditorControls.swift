import SwiftUI
import AppKit

/// The editor's **third pane**: a titled column (mirroring `CitationPane`) that
/// holds the active tool's controls. The spatial overlays (crop frame, markup
/// drawing) stay on the canvas in the viewer pane; everything you *set* — sliders,
/// filter swatches, geometry, the markup palette, export options — lives here.
struct ImageEditorControlsPane: View {
    @ObservedObject var model: ImageEditModel

    var body: some View {
        VStack(spacing: 0) {
            toolTabs
            Divider().opacity(0.4)
            ImageEditorControls(model: model)
        }
        .background(.regularMaterial)
    }

    /// The tool switcher, living at the top of this pane: picking a tab swaps both
    /// the controls below *and* the spatial overlay shown on the viewer's canvas.
    private var toolTabs: some View {
        HStack(spacing: 4) {
            ForEach(ImageEditModel.Tool.allCases) { tool in tab(tool) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private func tab(_ tool: ImageEditModel.Tool) -> some View {
        let active = model.activeTool == tool
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { model.activeTool = tool } }) {
            VStack(spacing: 3) {
                Image(systemName: tool.icon).font(.system(size: 13, weight: .semibold))
                Text(tool.label).font(.system(size: 8, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? Color.accentColor : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// Swaps its body to match the active tool. Each section fills the pane and
/// manages its own scrolling for the tall, narrow column.
struct ImageEditorControls: View {
    @ObservedObject var model: ImageEditModel

    var body: some View {
        Group {
            switch model.activeTool {
            case .adjust:  AdjustControls(model: model)
            case .filters: FilterControls(model: model)
            case .crop:    CropControls(model: model)
            case .markup:  MarkupControls(model: model)
            case .export:  ExportControls(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Adjust

private struct AdjustControls: View {
    @ObservedObject var model: ImageEditModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.state.removeBackground },
                    set: { _ in model.toggleBackgroundRemoval() })) {
                    Label("Remove background", systemImage: "person.crop.rectangle.badge.xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.backgroundRemovalUnavailable)
                .help(model.backgroundRemovalUnavailable
                      ? "No subject detected on this image, or unsupported on this Mac"
                      : "Isolate the subject on a transparent background, on-device")

                Divider().opacity(0.4)

                SliderRow(model: model, title: "Exposure", value: model.bind(\.exposure), range: -2...2, def: 0)
                SliderRow(model: model, title: "Brightness", value: model.bind(\.brightness), range: -0.5...0.5, def: 0)
                SliderRow(model: model, title: "Contrast", value: model.bind(\.contrast), range: 0.5...1.5, def: 1)
                SliderRow(model: model, title: "Saturation", value: model.bind(\.saturation), range: 0...2, def: 1)
                SliderRow(model: model, title: "Vibrance", value: model.bind(\.vibrance), range: -1...1, def: 0)
                SliderRow(model: model, title: "Warmth", value: model.bind(\.warmth), range: -1...1, def: 0)
                SliderRow(model: model, title: "Highlights", value: model.bind(\.highlights), range: 0...1, def: 1)
                SliderRow(model: model, title: "Shadows", value: model.bind(\.shadows), range: -1...1, def: 0)
                SliderRow(model: model, title: "Sharpness", value: model.bind(\.sharpness), range: 0...2, def: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// A labelled tone slider. The value reads back live; clicking the number resets
/// the field to its default. Editing brackets one undo step.
private struct SliderRow: View {
    @ObservedObject var model: ImageEditModel
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let def: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing { model.beginInteraction() } else { model.endInteraction() }
            }
            Button {
                model.apply { _ in value.wrappedValue = def }
            } label: {
                Text(displayValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == def ? .tertiary : .primary)
                    .frame(width: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Reset \(title)")
        }
    }

    private var displayValue: String {
        let v = value.wrappedValue
        return abs(v) < 0.005 || abs(v - 1) < 0.005 && def == 1
            ? String(format: "%.2f", v)
            : String(format: "%+.2f", v - (def == 1 ? 1 : 0))
    }
}

// MARK: - Filters

private struct FilterControls: View {
    @ObservedObject var model: ImageEditModel

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                if model.filterThumbs.isEmpty {
                    ForEach(FilterPreset.allCases) { preset in chip(preset, image: nil) }
                } else {
                    ForEach(model.filterThumbs, id: \.preset) { item in
                        chip(item.preset, image: item.image)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func chip(_ preset: FilterPreset, image: CGImage?) -> some View {
        let active = model.state.preset == preset
        Button { model.apply { $0.preset = preset } } label: {
            VStack(spacing: 5) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: active ? 2.5 : 0.5))
                Text(preset.label)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Crop & geometry

private struct CropControls: View {
    @ObservedObject var model: ImageEditModel

    private let aspects: [(String, CGFloat?)] = [
        ("Free", nil), ("1:1", 1), ("4:3", 4.0/3.0), ("3:2", 3.0/2.0),
        ("16:9", 16.0/9.0), ("9:16", 9.0/16.0),
    ]

    private let aspectColumns = [GridItem(.adaptive(minimum: 56), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Orient") {
                    HStack(spacing: 8) {
                        geoButton("rotate.left", "Rotate left") {
                            model.apply { $0.rotationQuarters = (($0.rotationQuarters - 1) % 4 + 4) % 4 }
                        }
                        geoButton("rotate.right", "Rotate right") {
                            model.apply { $0.rotationQuarters = ($0.rotationQuarters + 1) % 4 }
                        }
                        geoButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal") {
                            model.apply { $0.flipH.toggle() }
                        }
                        geoButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertical") {
                            model.apply { $0.flipV.toggle() }
                        }
                    }
                }

                section("Aspect ratio") {
                    LazyVGrid(columns: aspectColumns, spacing: 6) {
                        ForEach(aspects, id: \.0) { item in
                            Button(item.0) { model.setCropAspect(item.1) }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }

                section("Straighten") {
                    HStack(spacing: 10) {
                        Slider(value: model.bind(\.straighten), in: -45...45) { editing in
                            if editing { model.beginInteraction() } else { model.endInteraction() }
                        }
                        Text("\(Int(model.state.straighten))°")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func geoButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 30)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Markup

private struct MarkupControls: View {
    @ObservedObject var model: ImageEditModel

    private let palette: [RGBAColor] = [.red, .yellow, .green, .blue, .white, .black]
    private let toolColumns = [GridItem(.adaptive(minimum: 60), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Tool") {
                    LazyVGrid(columns: toolColumns, spacing: 6) {
                        ForEach(ImageEditModel.MarkupTool.allCases) { tool in
                            toolButton(tool)
                        }
                    }
                }

                section("Color") {
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.self) { color in swatch(color) }
                        Spacer(minLength: 0)
                    }
                }

                section("Thickness") {
                    HStack(spacing: 8) {
                        Image(systemName: "lineweight").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $model.markupWidth, in: 0.002...0.02)
                    }
                }

                Button {
                    model.removeLastAnnotation()
                } label: {
                    Label("Remove last", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .buttonStyle(.bordered)
                .disabled(model.state.annotations.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func toolButton(_ tool: ImageEditModel.MarkupTool) -> some View {
        let active = model.markupTool == tool
        return Button { model.markupTool = tool } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.icon).font(.system(size: 14, weight: .semibold))
                Text(tool.label).font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? Color.accentColor : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ color: RGBAColor) -> some View {
        let active = model.markupColor == color
        return Button { model.markupColor = color } label: {
            Circle()
                .fill(Color(color.nsColor))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: active ? 2.5 : 0)
                    .padding(-3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export

private struct ExportControls: View {
    @ObservedObject var model: ImageEditModel

    @State private var format: ImageConvert.Format = .png
    @State private var quality: Double = 0.9
    @State private var scale: Double = 1.0
    @State private var showOverwriteConfirm = false

    private static let formats: [ImageConvert.Format] =
        [.png, .jpeg, .heic, .tiff, .webp, .avif].filter { ImageConvert.canEncode($0) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Format").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: $format) {
                    ForEach(Self.formats, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Text(outputSize).font(.system(size: 11, design: .rounded))
                    .monospacedDigit().foregroundStyle(.tertiary)
            }

            if format.isLossy {
                row("Quality", "\(Int(quality * 100))%") {
                    Slider(value: $quality, in: 0.1...1)
                }
            }
            row("Scale", scaleLabel) {
                Slider(value: $scale, in: 0.1...1)
            }

            Button(action: doExport) {
                HStack(spacing: 6) {
                    if model.isExporting { ProgressView().controlSize(.small) }
                    Image(systemName: "square.and.arrow.up")
                    Text(model.isExporting ? "Exporting…" : "Export to New Den")
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.isExporting)

            Button { showOverwriteConfirm = true } label: {
                Label("Overwrite Original", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(model.isExporting)
            .help("Replace the original file with your edited version")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .confirmationDialog("Overwrite the original file?",
                            isPresented: $showOverwriteConfirm, titleVisibility: .visible) {
            Button("Overwrite Original", role: .destructive) {
                Task { await model.overwriteOriginal(quality: quality, scale: scale) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently replaces “\(model.url.lastPathComponent)” with your edited version, keeping its original format. This can’t be undone.")
        }
    }

    @ViewBuilder
    private func row<S: View>(_ title: String, _ value: String, @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            slider()
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit().frame(width: 38, alignment: .trailing)
        }
    }

    private var outputSize: String {
        let p = model.sourcePixelSize
        let w = Int((p.width * scale).rounded()), h = Int((p.height * scale).rounded())
        return "\(w)×\(h)"
    }

    private var scaleLabel: String { "\(Int(scale * 100))%" }

    private func doExport() {
        Task { await model.export(format: format, quality: quality, scale: scale) }
    }
}
