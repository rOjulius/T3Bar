import AppKit
import SwiftUI

enum T3Theme: String, CaseIterable, Identifiable, Sendable {
    case t3Code = "t3-code"
    case t3Chat = "t3-chat"
    case grove = "grove"
    case ocean = "ocean"
    case ember = "ember"
    case iris = "iris"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .t3Code: return "T3 Code"
        case .t3Chat: return "T3 Chat"
        case .grove: return "Grove"
        case .ocean: return "Ocean"
        case .ember: return "Ember"
        case .iris: return "Iris"
        }
    }

    var accent: Color {
        switch self {
        case .t3Code: return Color(red: 0.45, green: 0.56, blue: 0.72)
        case .t3Chat: return Color(red: 0.85, green: 0.28, blue: 0.56)
        case .grove:  return Color(red: 0.55, green: 0.44, blue: 0.19)
        case .ocean:  return Color(red: 0.14, green: 0.62, blue: 0.86)
        case .ember:  return Color(red: 0.92, green: 0.44, blue: 0.20)
        case .iris:   return Color(red: 0.55, green: 0.42, blue: 0.92)
        }
    }

    /// Subtle tint applied to the Liquid Glass surface
    var glassBaseTint: Color {
        switch self {
        case .t3Code: return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .t3Chat: return Color(red: 0.78, green: 0.28, blue: 0.54)
        case .grove:  return Color(red: 0.36, green: 0.56, blue: 0.43)
        case .ocean:  return Color(red: 0.12, green: 0.48, blue: 0.68)
        case .ember:  return Color(red: 0.78, green: 0.38, blue: 0.18)
        case .iris:   return Color(red: 0.46, green: 0.36, blue: 0.78)
        }
    }

    /// Preview swatch background for the theme picker
    var swatchSurface: Color {
        switch self {
        case .t3Code: return Color(red: 0.16, green: 0.17, blue: 0.20)
        case .t3Chat: return Color(red: 0.24, green: 0.13, blue: 0.20)
        case .grove:  return Color(red: 0.15, green: 0.22, blue: 0.18)
        case .ocean:  return Color(red: 0.11, green: 0.20, blue: 0.27)
        case .ember:  return Color(red: 0.25, green: 0.16, blue: 0.12)
        case .iris:   return Color(red: 0.19, green: 0.16, blue: 0.28)
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum GlassIntensity: String, CaseIterable, Identifiable, Sendable {
    case subtle
    case balanced
    case vivid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subtle: return "Subtle"
        case .balanced: return "Balanced"
        case .vivid: return "Vivid"
        }
    }

    var tintOpacity: Double {
        switch self {
        case .subtle: return 0.06
        case .balanced: return 0.13
        case .vivid: return 0.22
        }
    }
}

// MARK: - Apple Liquid Glass Background (Native macOS 26 + Graceful macOS 14/15 Fallback)

struct LiquidGlassContainer<Content: View>: View {
    let theme: T3Theme
    let intensity: GlassIntensity
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content()
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.glassBaseTint.opacity(intensity.tintOpacity * 0.9),
                                theme.glassBaseTint.opacity(intensity.tintOpacity * 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .glassEffect(.regular.tint(theme.glassBaseTint.opacity(intensity.tintOpacity)), in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.28 : 0.65),
                                theme.accent.opacity(0.18),
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .clipShape(shape)
        } else {
            content()
                .background(
                    ZStack {
                        VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                        LinearGradient(
                            colors: [
                                theme.glassBaseTint.opacity(intensity.tintOpacity * 1.15),
                                theme.glassBaseTint.opacity(intensity.tintOpacity * 0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.25 : 0.6),
                                theme.accent.opacity(0.20),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .clipShape(shape)
        }
    }
}

struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
