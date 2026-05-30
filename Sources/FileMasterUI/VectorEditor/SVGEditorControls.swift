import SwiftUI
import AppKit

/// The vector editor's **controls pane** (third pane), mirroring
/// `ImageEditorControlsPane`: tool tabs on top, the active section's controls below.
/// Shapes = the selection panel (fill / scale / rotation / move / delete / reset),
/// Nodes = path-node editing toggle, Export = Save SVG / Overwrite Original.
struct SVGEditorControlsPane: View {
    @ObservedObject var model: SVGEditModel

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider().opacity(0.4)
            Group {
                switch model.mode {
                case .shapes: SVGShapesControls(model: model)
                case .nodes:  SVGNodesControls(model: model)
                case .export: SVGExportControls(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SVGEditModel.Mode.allCases) { tab($0) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private func tab(_ mode: SVGEditModel.Mode) -> some View {
        let active = model.mode == mode
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { model.mode = mode } }) {
            VStack(spacing: 3) {
                Image(systemName: mode.icon).font(.system(size: 13, weight: .semibold))
                Text(mode.label).font(.system(size: 8, weight: .semibold))
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

// MARK: - Shapes

private struct SVGShapesControls: View {
    @ObservedObject var model: SVGEditModel

    private let palette: [RGBAColor] = [.red, .yellow, .green, .blue, .white, .black]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                shapeList
                Divider().opacity(0.4)
                if let el = model.selectedElement {
                    selection(el)
                } else {
                    Text("Select a shape on the canvas to edit it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    // Compact list so tiny shapes are still selectable.
    private var shapeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Shapes")
            ForEach(Array(model.doc.elements.enumerated()), id: \.element.id) { idx, el in
                let active = model.selection == el.id
                Button { model.select(el.id) } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color((el.style.fill ?? .white).nsColor))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                        Text("\(el.geometry.typeName) \(idx)")
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.accentColor.opacity(0.18) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func selection(_ el: SVGElement) -> some View {
        let b = SVGGeometry.bounds(of: el)
        sectionTitle("Selection")
        VStack(alignment: .leading, spacing: 2) {
            Text("\(el.geometry.typeName) \(model.selectedIndex ?? 0)")
                .font(.system(size: 13, weight: .semibold))
            Text("\(Int(b.width.rounded()))×\(Int(b.height.rounded())) px")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        fillControls(el)

        labeledSlider("Scale", value: $model.editScale, range: 0.1...4,
                      display: "\(Int((model.editScale * 100).rounded()))%")
        labeledSlider("Rotation", value: $model.editRotation, range: -180...180,
                      display: "\(Int(model.editRotation.rounded()))°")

        HStack(spacing: 10) {
            moveStepper("Move X", \.editMoveX)
            moveStepper("Move Y", \.editMoveY)
        }

        HStack(spacing: 8) {
            Button(role: .destructive) { model.deleteSelection() } label: {
                Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { model.resetShape() } label: {
                Label("Reset Shape", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 2)
    }

    @ViewBuilder
    private func fillControls(_ el: SVGElement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FILL COLOR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ColorPicker("", selection: fillBinding(el), supportsOpacity: true)
                    .labelsHidden().frame(width: 36)
                HexField(hex: el.style.fill.map { SVGColor.hexString($0) } ?? "none") { text in
                    if let parsed = SVGColor.parse(text) { model.setFill(parsed) }
                }
                .id(el.id)
            }
            HStack(spacing: 6) {
                ForEach(palette, id: \.self) { c in
                    Button { model.setFill(c) } label: {
                        Circle().fill(Color(c.nsColor)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Button { model.setFill(nil) } label: {
                    Image(systemName: "slash.circle").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("No fill")
                Spacer()
            }
        }
    }

    // MARK: bindings & rows

    private func fillBinding(_ el: SVGElement) -> Binding<Color> {
        Binding(get: { Color((el.style.fill ?? .white).nsColor) },
                set: { model.setFill(RGBAColor(nsColor: NSColor($0))) })
    }

    private func moveStepper(_ title: String, _ kp: ReferenceWritableKeyPath<SVGEditModel, Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Stepper(value: stepBinding(kp), in: -10_000...10_000, step: 1) {
                Text("\(Int(model[keyPath: kp].rounded()))")
                    .font(.system(size: 12, design: .rounded)).monospacedDigit()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stepper edits each count as one undo step.
    private func stepBinding(_ kp: ReferenceWritableKeyPath<SVGEditModel, Double>) -> Binding<Double> {
        Binding(get: { model[keyPath: kp] },
                set: { v in
                    model.beginInteraction(); model[keyPath: kp] = v
                    model.endInteraction(); model.commitTransformEdit()
                })
    }

    private func labeledSlider(_ title: String, value: Binding<Double>,
                               range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(display).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Slider(value: value, in: range) { editing in
                if editing { model.beginInteraction() }
                else { model.endInteraction(); model.commitTransformEdit() }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
    }
}

/// A `#rrggbb` text field with its own edit buffer (so typing isn't clobbered by
/// re-renders) that commits on Return. `.id(element)` reseeds it per selection.
private struct HexField: View {
    @State private var text: String
    let commit: (String) -> Void

    init(hex: String, commit: @escaping (String) -> Void) {
        _text = State(initialValue: hex)
        self.commit = commit
    }

    var body: some View {
        TextField("none", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit { commit(text) }
    }
}

// MARK: - Nodes

private struct SVGNodesControls: View {
    @ObservedObject var model: SVGEditModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PATH NODES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                if let el = model.selectedElement, case .path = el.geometry {
                    Text("Drag the square anchors to reshape the path, or the round handles to bend the curve into and out of each anchor.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if model.selectedElement != nil {
                    Text("This shape isn’t a path. Only `<path>` elements have editable nodes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Select a path on the canvas, then drag its nodes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
    }
}

// MARK: - Export

private struct SVGExportControls: View {
    @ObservedObject var model: SVGEditModel
    @State private var showOverwriteConfirm = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Vector output is resolution-independent — no size or quality to set.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await model.export() } } label: {
                HStack(spacing: 6) {
                    if model.isExporting { ProgressView().controlSize(.small) }
                    Image(systemName: "square.and.arrow.up")
                    Text("Save SVG to New Den")
                }
                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).disabled(model.isExporting)

            Button { showOverwriteConfirm = true } label: {
                Label("Overwrite Original", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.bordered).disabled(model.isExporting)
            .help("Replace the original .svg with your edited version")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .confirmationDialog("Overwrite the original file?",
                            isPresented: $showOverwriteConfirm, titleVisibility: .visible) {
            Button("Overwrite Original", role: .destructive) {
                Task { await model.overwriteOriginal() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently replaces “\(model.url.lastPathComponent)” with your edited version. This can’t be undone.")
        }
    }
}
