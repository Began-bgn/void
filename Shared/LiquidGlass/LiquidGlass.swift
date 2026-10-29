import SwiftUI

enum GlassVariant {
    /// Default: cards, settings, controls.
    case regular
    /// Over media (artwork, wallpaper). Pair with `GlassScrim` under text.
    case clear
    /// Primary action, tinted.
    case prominent
}

extension View {
    /// The one way to put glass on a view. Native Liquid Glass on macOS 26, material fallback
    /// before; Reduce Transparency and Increase Contrast handled here so call sites never branch.
    func liquidGlass<S: Shape>(_ variant: GlassVariant = .regular, in shape: S, tint: Color? = nil,
                               interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(variant: variant, shape: shape, tint: tint, interactive: interactive))
    }

    func liquidGlass(_ variant: GlassVariant = .regular, tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(variant, in: RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous),
                    tint: tint, interactive: interactive)
    }

    func elevation(_ e: LG.Elevation) -> some View {
        shadow(color: .black.opacity(e.opacity), radius: e.blur / 2, y: e.y)
    }
}

/// Forces accessibility looks for previews and the gallery (the system values are read-only).
struct LGAccessibility: Equatable {
    var reduceTransparency = false
    var increaseContrast = false
}

extension EnvironmentValues {
    @Entry var lgForced = LGAccessibility()
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let variant: GlassVariant
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lgForced) private var forced

    private var reduced: Bool { reduceTransparency || forced.reduceTransparency }
    private var highContrast: Bool { contrast == .increased || forced.increaseContrast }
    private var prominentTint: Color { tint ?? LG.accent }

    func body(content: Content) -> some View {
        Group {
            if reduced {
                let solid = scheme == .dark ? Color(white: 0.17) : Color(white: 0.93)
                content
                    .background(variant == .prominent ? AnyShapeStyle(prominentTint) : AnyShapeStyle(solid), in: shape)
                    .overlay { shape.stroke(Color.primary.opacity(0.15), lineWidth: 1) }
            } else if variant == .clear {
                // Crystal: no blur, near-zero fill, bright rim. Native .clear still frosts the backdrop.
                content
                    .background { shape.fill((tint ?? .white).opacity(tint == nil ? 0.04 : 0.12)) }
                    .overlay { crystalRim }
            } else if #available(macOS 26, *) {
                content
                    // Native tint is faint; a primary action needs a solid colour to read (and to
                    // keep white text above 4.5:1). The glass still gives the edge light.
                    .background { if variant == .prominent { shape.fill(prominentTint.opacity(0.85)) } }
                    .glassEffect(glass, in: shape)
            } else {
                content
                    .background { fallback }
                    .overlay { highlight }
            }
        }
        .overlay {
            if highContrast { shape.stroke(Color.primary.opacity(0.7), lineWidth: 1.5) }
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        // Clear everywhere but the prominent action: regular glass frosts too much. Scrims carry legibility.
        var g: Glass = variant == .prominent ? .regular : .clear
        if variant == .prominent { g = g.tint(prominentTint) } else if let tint { g = g.tint(tint.opacity(0.2)) }
        return interactive ? g.interactive() : g
    }

    /// macOS 14–15: material, low tint, inner shadow.
    private var fallback: some View {
        ZStack {
            shape.fill(variant == .prominent ? Material.thinMaterial : .ultraThinMaterial)
            if variant == .prominent { shape.fill(prominentTint.opacity(0.75)) }
            else if let tint { shape.fill(tint.opacity(0.12)) }
            shape.stroke(Color.black.opacity(0.08), lineWidth: 3).blur(radius: 2).clipShape(shape)
        }
    }

    /// Specular edge: bright top-leading, fading out. Light, not a border.
    private var highlight: some View {
        shape.stroke(
            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
    }

    /// Glass edge catching light at opposite corners, plus a soft inner glow so the pane reads as thick.
    private var crystalRim: some View {
        ZStack {
            shape.stroke(
                LinearGradient(stops: [.init(color: .white.opacity(0.7), location: 0),
                                       .init(color: .white.opacity(0.08), location: 0.45),
                                       .init(color: .white.opacity(0.35), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2)
            shape.stroke(Color.white.opacity(0.12), lineWidth: 6).blur(radius: 5).clipShape(shape)
        }
        .allowsHitTesting(false)
    }
}

/// Keeps white text legible on glass over busy or bright content: darkens where text sits
/// (dark mode only). Never raise glass opacity instead.
struct GlassScrim: View {
    var top = 0.08, bottom = 0.2
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.lgForced) private var forced

    var body: some View {
        // Light mode: no scrim. A white wash fogs clear glass; dark text (Tone.primary) reads without it.
        LinearGradient(colors: [.black.opacity(top), .black.opacity(bottom)], startPoint: .top, endPoint: .bottom)
            .opacity(scheme == .dark && !(reduceTransparency || forced.reduceTransparency) ? 1 : 0) // solid fill needs none
            .allowsHitTesting(false)
    }
}
