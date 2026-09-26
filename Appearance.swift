import AppKit
import SwiftUI

struct UsagePalette {
    let scheme: ColorScheme

    var codex: Color {
        scheme == .dark ? Color(red: 0.68, green: 0.70, blue: 1.0)
                        : Color(red: 0.30, green: 0.28, blue: 0.71)
    }

    var secondary: Color {
        scheme == .dark ? Color(red: 0.65, green: 0.67, blue: 0.70)
                        : Color(red: 0.39, green: 0.41, blue: 0.44)
    }

    var deepSeek: Color {
        scheme == .dark ? Color(red: 0.56, green: 0.68, blue: 1.0)
                        : Color(red: 0.21, green: 0.38, blue: 0.80)
    }

    var track: Color { Color(nsColor: .separatorColor).opacity(scheme == .dark ? 0.72 : 0.52) }
    var border: Color { Color(nsColor: .separatorColor).opacity(scheme == .dark ? 0.90 : 0.65) }
    var controlFill: Color { Color(nsColor: .controlBackgroundColor) }
}

struct CardSurface: View {
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)
        shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay {
                shape.fill(LinearGradient(
                    colors: [accent.opacity(scheme == .dark ? 0.12 : 0.07), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(UsagePalette(scheme: scheme).border, lineWidth: 1) }
    }
}

struct HeaderActionBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(UsagePalette(scheme: scheme).controlFill)
        }
    }
}
