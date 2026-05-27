import SwiftUI
import AppKit

struct ColorView: View {
    let color: NSColor

    @State private var copied: Field? = nil

    enum Field { case hex, rgb, hsl }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: color))
                .aspectRatio(3 / 2, contentMode: .fit)
                .padding(16)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                row(hash: true,  value: hexString, field: .hex)
                row(symbol: "paintpalette", value: rgbString, field: .rgb)
                row(symbol: "circle.grid.3x3.fill", value: hslString, field: .hsl)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(hash: Bool = false, symbol: String? = nil, value: String, field: Field) -> some View {
        let isCopied = copied == field
        Button {
            copy(value, field: field)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if hash {
                        Text("#")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)

                Text(isCopied ? "Copied!" : value)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(isCopied ? .secondary : .primary)
                    .animation(.easeInOut(duration: 0.15), value: copied)
                    .contentTransition(.numericText())
            }
        }
        .buttonStyle(.plain)
    }

    private func copy(_ string: String, field: Field) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = field }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if copied == field { copied = nil }
            }
        }
    }

    // MARK: - Color values

    private var srgb: NSColor { color.usingColorSpace(.sRGB) ?? color }
    private var r: CGFloat { srgb.redComponent }
    private var g: CGFloat { srgb.greenComponent }
    private var b: CGFloat { srgb.blueComponent }
    private var a: CGFloat { srgb.alphaComponent }

    private var hexString: String {
        String(format: "#%02X%02X%02X%02X",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()),
               Int((a * 255).rounded()))
    }

    private var rgbString: String {
        "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))"
    }

    private var hslString: String {
        let (h, s, l) = hsl
        return "hsl(\(h), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    private var hsl: (h: Int, s: CGFloat, l: CGFloat) {
        let max = Swift.max(r, g, b)
        let min = Swift.min(r, g, b)
        let delta = max - min
        let l = (max + min) / 2

        let s: CGFloat = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))

        let hRaw: CGFloat
        if delta == 0 {
            hRaw = 0
        } else if max == r {
            hRaw = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if max == g {
            hRaw = (b - r) / delta + 2
        } else {
            hRaw = (r - g) / delta + 4
        }
        let h = Int(((hRaw * 60) + 360).truncatingRemainder(dividingBy: 360).rounded())
        return (h, s, l)
    }
}
