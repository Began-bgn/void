import SwiftUI

/// Liquid Glass design tokens: the only place radii, spacing, elevation, type, colour and motion
/// are defined. See DESIGN.md.
enum LG {
    enum Radius {
        static let card: CGFloat = 28
        static let control: CGFloat = 18
        static let cover: CGFloat = 14
        static let small: CGFloat = 10
    }

    enum Space {
        static let xxs: CGFloat = 4, xs: CGFloat = 8, s: CGFloat = 12, m: CGFloat = 16
        static let l: CGFloat = 20, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    enum Elevation {
        case rest, raised, floating
        var y: CGFloat { switch self { case .rest: 2; case .raised: 6; case .floating: 12 } }
        var blur: CGFloat { switch self { case .rest: 8; case .raised: 20; case .floating: 32 } }
        var opacity: Double { switch self { case .rest: 0.12; case .raised: 0.18; case .floating: 0.24 } }
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let numeric = SwiftUI.Font.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()
    }

    /// Label colours: white on dark glass, black on light glass (follows the colour scheme).
    enum Tone {
        static let primary = Color.primary
        static let secondary = Color.primary.opacity(0.6)
        static let tertiary = Color.primary.opacity(0.35)
    }

    enum Motion {
        static let ui = Animation.spring(response: 0.35, dampingFraction: 0.8)
        static let morph = Animation.spring(response: 0.5, dampingFraction: 0.75)
        static let fade = Animation.easeOut(duration: 0.2)
        static let pressScale: CGFloat = 0.96
        static let hoverScale: CGFloat = 1.02
        static let stagger = 0.03

        /// Reduce Motion: cross-fades instead of springs.
        static func ui(reduceMotion: Bool) -> Animation { reduceMotion ? fade : ui }
        static func morph(reduceMotion: Bool) -> Animation { reduceMotion ? fade : morph }
    }

    /// System accent. Not `Color.accentColor`: that greys out in inactive windows, and NotchDeck's
    /// panels are never the active window.
    static var accent: Color { Color(nsColor: .controlAccentColor) }

    /// Artwork-derived accent, clamped so it never turns neon or muddy.
    static func accent(from color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s, 0.7), brightness: min(max(b, 0.55), 0.9))
    }
}
