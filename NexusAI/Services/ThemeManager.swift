import SwiftUI
import AppKit

/// How the app follows the system's light/dark appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Accent color presets for the app.
enum ThemeAccent: String, CaseIterable, Identifiable {
    case mint = "Mint"
    case ocean = "Ocean"
    case purple = "Purple"
    case blue = "Blue"
    case rose = "Rose"
    case emerald = "Emerald"
    case orange = "Orange"
    case mono = "Mono"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .mint: return Color(red: 0.32, green: 0.72, blue: 0.55)
        case .ocean: return Color(red: 0.24, green: 0.55, blue: 0.90)
        case .purple: return Color(red: 0.62, green: 0.40, blue: 0.95)
        case .blue: return Color(red: 0.28, green: 0.52, blue: 0.95)
        case .rose: return Color(red: 0.90, green: 0.38, blue: 0.54)
        case .emerald: return Color(red: 0.22, green: 0.70, blue: 0.46)
        case .orange: return Color(red: 0.93, green: 0.56, blue: 0.25)
        case .mono: return Color(red: 0.45, green: 0.47, blue: 0.50)
        }
    }
}

extension Color {
    /// Blends this (semantic) color toward `other` by `fraction`, resolving both
    /// through the current system appearance so the result follows light/dark.
    func blended(withFraction fraction: Double, of other: Color) -> Color {
        let a = NSColor(self)
        let b = NSColor(other)
        let c1 = a.usingColorSpace(.deviceRGB) ?? .clear
        let c2 = b.usingColorSpace(.deviceRGB) ?? .clear
        let f = min(max(fraction, 0), 1)
        return Color(
            red: c1.redComponent + (c2.redComponent - c1.redComponent) * f,
            green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * f,
            blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * f,
            opacity: 1.0
        )
    }
}

/// Manages appearance (System/Light/Dark) and accent color, both persisted.
@MainActor
final class ThemeManager: ObservableObject {
    /// Shared theme instance so every view (including stateless `View` extensions
    /// like `cardStyle()` / glass helpers) reads the same live opacity & accent.
    @MainActor static let shared = ThemeManager()

    @Published var appearance: AppearanceMode = .system {
        didSet { persist() }
    }
    @Published var accent: ThemeAccent = .mint {
        didSet { persist() }
    }
    /// How transparent the liquid-glass panels are. 1.0 = fully frosted,
    /// 0.4 = nearly see-through. Persisted.
    @Published var glassOpacity: Double = 1.0 {
        didSet { persist() }
    }

    var accentColor: Color { accent.color }

    /// A subtle, appearance-aware background for the main content area.
    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor).blended(withFraction: 0.06, of: accent.color),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "themeAppearance"),
           let a = AppearanceMode(rawValue: raw) {
            appearance = a
        }
        if let raw = UserDefaults.standard.string(forKey: "themeAccent"),
           let a = ThemeAccent(rawValue: raw) {
            accent = a
        }
        let g = UserDefaults.standard.double(forKey: "themeGlassOpacity")
        if g > 0 { glassOpacity = min(max(g, 0.4), 1.0) }
    }

    private func persist() {
        UserDefaults.standard.set(appearance.rawValue, forKey: "themeAppearance")
        UserDefaults.standard.set(accent.rawValue, forKey: "themeAccent")
        UserDefaults.standard.set(glassOpacity, forKey: "themeGlassOpacity")
    }
}

// MARK: - Liquid glass design system

/// A soft "aurora" gradient used as the glass backdrop.
///
/// Deliberately lightweight: the blobs are **radial gradients, not blurred
/// shapes**. `blur(radius:)` makes Core Animation keep large offscreen backing
/// buffers (100s of KB each on retina) alive for the app's entire lifetime and
/// was a big chunk of idle RAM/GPU. Radial gradients composite in a single pass
/// with no extra backing store.
struct LiquidGlassBackground: View {
    var accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    accent.opacity(0.6),
                    Color(nsColor: .windowBackgroundColor),
                    accent.blended(withFraction: 0.25, of: .purple).opacity(0.45),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Luminous blobs — static radial gradients, composited once.
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.5), accent.opacity(0)],
                                     center: .center, startRadius: 10, endRadius: 250))
                .frame(width: 500, height: 500)
                .offset(x: 320, y: -240)
            Circle()
                .fill(RadialGradient(colors: [Color.purple.opacity(0.36), Color.purple.opacity(0)],
                                     center: .center, startRadius: 10, endRadius: 230))
                .frame(width: 460, height: 460)
                .offset(x: -300, y: 260)
            Circle()
                .fill(RadialGradient(colors: [Color.teal.opacity(0.28), Color.teal.opacity(0)],
                                     center: .center, startRadius: 10, endRadius: 210))
                .frame(width: 420, height: 420)
                .offset(x: 120, y: 340)
        }
        .ignoresSafeArea()
    }
}

/// A frosted translucent panel with a hairline glass border — the building
/// block of the liquid glass UI.
struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var opacity: Double = 1.0

    func body(content: Content) -> some View {
        let effective = opacity * ThemeManager.shared.glassOpacity
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(effective)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .blendMode(.plusLighter)
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.08))
            )
    }
}

extension View {
    /// Applies the glass panel treatment.
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }

    /// Rounded, translucent clip used by cards and buttons.
    func glassClip(_ radius: CGFloat = 16) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
