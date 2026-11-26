import SwiftUI

// ATOMIC LEVEL: Foundations (theme layer).
// A `Theme` is one complete set of the roles that components read: colour, surface, material,
// type, radius, line, spacing and motion. The two themes mirror design/system/tokens.json
// "themes": `blackGlass` holds today's main-window values and `console` holds DESIGN.md section 2.
// ThemeTests compares every value here with that file.
//
// The console, the terminal and the pretty view never read a Theme. They keep `Palette`, `Term`
// and `TypeRole` from DesignTokens.swift, so a theme switch leaves them as they are.

// MARK: - Token values

/// One sRGB colour with its opacity.
struct ThemeColor: Equatable, Sendable {
    let hex: UInt32
    var opacity: Double = 1

    var color: Color { Color(hex: hex, opacity: opacity) }

    func opacity(_ value: Double) -> ThemeColor { ThemeColor(hex: hex, opacity: value) }
}

/// A flat colour, or a gradient along one axis.
struct ThemeFill: Equatable, Sendable {
    enum Axis: String, Sendable { case flat, vertical, diagonal }

    let axis: Axis
    let stops: [ThemeColor]

    static func flat(_ color: ThemeColor) -> ThemeFill { ThemeFill(axis: .flat, stops: [color]) }

    var style: AnyShapeStyle {
        let colors = stops.map(\.color)
        switch axis {
        case .flat: return AnyShapeStyle(colors.first ?? .clear)
        case .vertical: return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
        case .diagonal: return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

/// A type role: face, size, weight, tracking and case.
struct ThemeFont: Equatable, Sendable {
    enum Face: String, Sendable { case system, mono }
    enum Weight: String, Sendable {
        case regular, medium, semibold

        var value: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            }
        }
    }

    let face: Face
    let size: CGFloat
    var weight: Weight = .regular
    var tracking: CGFloat = 0
    var uppercase = false

    var font: Font { .system(size: size, weight: weight.value, design: face == .mono ? .monospaced : .default) }
}

struct ThemeShadow: Equatable, Sendable {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat
}

enum ThemeID: String, CaseIterable, Identifiable, Sendable {
    case blackGlass, console

    var id: String { rawValue }
}

// MARK: - Theme

struct Theme: Equatable, Sendable {
    /// DESIGN.md section 2 "Colour". The same thirteen roles in every theme.
    struct Colors: Equatable, Sendable {
        let window, panel, well, hair, border: ThemeColor
        let foreground, secondary, focus, working, attention, failure: ThemeColor
        let selection, onAccent: ThemeColor
    }

    /// The stronger roles that Increase Contrast swaps in.
    struct Contrast: Equatable, Sendable {
        let strongSecondary, strongBorder: ThemeColor
    }

    /// The window material. Reduce Transparency always uses the opaque fills.
    struct Material: Equatable, Sendable {
        enum Window: String, Sendable { case glass, opaque }

        let window: Window
        let windowFill: ThemeColor
        let canvasFill: ThemeFill
        let opaqueCanvasFill: ThemeColor
    }

    /// What each component surface is made of.
    struct Surface: Equatable, Sendable {
        let panelFill: ThemeFill
        let panelEdge: ThemeColor
        let panelShadow: ThemeShadow
        let markFill, markEdge: ThemeColor
        let fieldFill, fieldEdge: ThemeColor
        let controlFill: ThemeFill
        let controlEdge, controlInk: ThemeColor
        let primaryFill: ThemeFill
        let primaryEdge: ThemeColor
        let chipFill, tagFill, tagEdge: ThemeColor
        let selectedFill: ThemeFill
        let selectedEdge: ThemeColor
        let unselectedFill, unselectedEdge: ThemeColor
        let footerFill, headerFill: ThemeColor
        let softInk, quietInk: ThemeColor
        let attentionFill, attentionEdge: ThemeColor
        let highlightFill, highlightInk: ThemeColor
        let hitFill, hitMarker: ThemeColor
        let switchTint: ThemeColor
    }

    /// Choices between two forms of the same control.
    struct Style: Equatable, Sendable {
        enum ButtonShape: String, Sendable { case capsule, rectangle }
        enum StatusMark: String, Sendable { case dot, lamp }
        enum SwitchShape: String, Sendable { case native, square }

        let buttonShape: ButtonShape
        let statusMark: StatusMark
        let switchShape: SwitchShape
    }

    struct Radius: Equatable, Sendable {
        let tile, control, chip: CGFloat
    }

    struct Line: Equatable, Sendable {
        let hairline, selectedMarker, focusedField: CGFloat
    }

    /// DESIGN.md section 2 "Type".
    struct TypeScale: Equatable, Sendable {
        let title, name, body, sub, heading, state, data, mono, label, fingerprint, figure: ThemeFont
    }

    /// Type roles for a full-size page. Proposed additions to DESIGN.md.
    struct PageType: Equatable, Sendable {
        let pageTitle, detailTitle, sectionTitle, groupTitle, control, meta: ThemeFont
    }

    /// DESIGN.md section 2 "Spacing and size", plus the proposed page inset and table row height.
    struct Space: Equatable, Sendable {
        let sectionInset, bandTop, bandBottom, sectionGap: CGFloat
        let controlHeight, controlHeightLarge, fieldHeight, rowIcon: CGFloat
        let tabHeight, chipHeightMin, chipHeightMax: CGFloat
        let pageInset, rowHeight: CGFloat
    }

    struct Motion: Equatable, Sendable {
        enum Curve: String, Sendable { case easeOut, easeInOut }

        let fast, standard, slow, pulse: Double
        let travel: CGFloat
        let curve: Curve

        func animation(_ duration: Double) -> Animation {
            curve == .easeOut ? .easeOut(duration: duration) : .easeInOut(duration: duration)
        }
    }

    let id: ThemeID
    let name: String
    let color: Colors
    let contrast: Contrast
    let material: Material
    let surface: Surface
    let style: Style
    let radius: Radius
    let line: Line
    let type: TypeScale
    let pageType: PageType
    let space: Space
    let motion: Motion

    static func named(_ id: ThemeID) -> Theme {
        switch id {
        case .blackGlass: .blackGlass
        case .console: .console
        }
    }
}

// MARK: - The two themes

private func ink(_ hex: UInt32, _ opacity: Double = 1) -> ThemeColor { ThemeColor(hex: hex, opacity: opacity) }
private func system(_ size: CGFloat, _ weight: ThemeFont.Weight = .regular, tracking: CGFloat = 0, uppercase: Bool = false) -> ThemeFont {
    ThemeFont(face: .system, size: size, weight: weight, tracking: tracking, uppercase: uppercase)
}
private func mono(_ size: CGFloat, _ weight: ThemeFont.Weight = .regular) -> ThemeFont {
    ThemeFont(face: .mono, size: size, weight: weight)
}

extension Theme.Contrast {
    static let shared = Theme.Contrast(strongSecondary: ink(0xE3E5EC), strongBorder: ink(0xA6A8B2))
}

extension Theme {
    /// Today's main-window look.
    static let blackGlass: Theme = {
        let color = Colors(window: ink(0x090A0D), panel: ink(0x14151A), well: ink(0x0B0C10), hair: ink(0xFFFFFF, 0.11),
                           border: ink(0x383B44), foreground: ink(0xF5F5F9), secondary: ink(0xB7BAC6), focus: ink(0xB5D6FF),
                           working: ink(0xA8E0C0), attention: ink(0xF1C587), failure: ink(0xEC9B92),
                           selection: ink(0x283344), onAccent: ink(0x101825))
        return Theme(
            id: .blackGlass, name: "Black glass", color: color, contrast: .shared,
            material: Material(window: .glass, windowFill: ink(0x15161A),
                               canvasFill: ThemeFill(axis: .diagonal, stops: [ink(0x030408, 0.46), ink(0x040508, 0.66), ink(0x0B0B12, 0.44)]),
                               opaqueCanvasFill: color.window),
            surface: Surface(
                panelFill: ThemeFill(axis: .diagonal, stops: [ink(0x1A1B22), ink(0x0C0D12)]),
                panelEdge: ink(0xFFFFFF, 0.16),
                panelShadow: ThemeShadow(opacity: 0.22, radius: 6, y: 3),
                markFill: ink(0x1C1D24), markEdge: ink(0xFFFFFF, 0.11),
                fieldFill: ink(0x111218), fieldEdge: ink(0x464957),
                controlFill: ThemeFill(axis: .vertical, stops: [ink(0x464750, 0.66), ink(0x24262E, 0.55)]),
                controlEdge: ink(0xFFFFFF, 0.22), controlInk: ink(0xEBECF4),
                primaryFill: ThemeFill(axis: .vertical, stops: [ink(0xE4EFFF), ink(0xB5D5FB), ink(0x96B8EA)]),
                primaryEdge: ink(0xD9EAFF),
                chipFill: ink(0x1A1B22), tagFill: ink(0x16171E), tagEdge: ink(0x3C404E),
                selectedFill: ThemeFill(axis: .diagonal, stops: [ink(0x293344), ink(0x19212C)]),
                selectedEdge: ink(0x8BA3C4),
                unselectedFill: ink(0x111218, 0.55), unselectedEdge: ink(0xFFFFFF, 0.11),
                footerFill: ink(0x17181F, 0.6), headerFill: ink(0xFFFFFF, 0.03),
                softInk: ink(0xD3D6E0), quietInk: ink(0x6F7483),
                attentionFill: ink(0x28251D), attentionEdge: ink(0x665236),
                highlightFill: ink(0x4A4630), highlightInk: ink(0xF4E7B2),
                hitFill: ink(0xFFFFFF, 0.06), hitMarker: ink(0x8E93A6),
                switchTint: ink(0x96B8EA)),
            style: Style(buttonShape: .capsule, statusMark: .dot, switchShape: .native),
            radius: Radius(tile: 13, control: 9, chip: 5),
            line: Line(hairline: 1, selectedMarker: 0, focusedField: 1.5),
            type: TypeScale(title: system(14, .semibold), name: system(15, .semibold), body: system(14), sub: system(12.5),
                            heading: system(10, .semibold, tracking: 1.1, uppercase: true), state: system(12, .semibold),
                            data: system(14, .semibold), mono: mono(12), label: system(12, .semibold),
                            fingerprint: mono(10), figure: system(22, .semibold)),
            pageType: PageType(pageTitle: system(33, .semibold, tracking: -1.1), detailTitle: system(30, .semibold, tracking: -0.9),
                               sectionTitle: system(22, .semibold, tracking: -0.7), groupTitle: system(19, .semibold, tracking: -0.4),
                               control: system(13, .semibold), meta: system(12)),
            space: Space(sectionInset: 25, bandTop: 22, bandBottom: 22, sectionGap: 24,
                         controlHeight: 31, controlHeightLarge: 35, fieldHeight: 40, rowIcon: 37,
                         tabHeight: 44, chipHeightMin: 24, chipHeightMax: 24, pageInset: 36, rowHeight: 54),
            motion: Motion(fast: 0.15, standard: 0.25, slow: 0.35, pulse: 1.7, travel: 0, curve: .easeInOut))
    }()

    /// The operations-console look of DESIGN.md.
    static let console: Theme = {
        let color = Colors(window: ink(0x090A0D), panel: ink(0x14151A), well: ink(0x0B0C10), hair: ink(0x26282F),
                           border: ink(0x383B44), foreground: ink(0xF5F5F9), secondary: ink(0xB7BAC6), focus: ink(0xB5D6FF),
                           working: ink(0xA8E0C0), attention: ink(0xF1C587), failure: ink(0xEC9B92),
                           selection: ink(0x283344), onAccent: ink(0x101825))
        let type = TypeScale(title: system(14, .semibold), name: system(13, .medium), body: system(13), sub: system(11),
                             heading: mono(11.5, .semibold), state: mono(10.5, .semibold), data: mono(11, .medium),
                             mono: mono(11), label: mono(9.5, .semibold), fingerprint: mono(10.5), figure: mono(14, .semibold))
        return Theme(
            id: .console, name: "Console", color: color, contrast: .shared,
            material: Material(window: .opaque, windowFill: color.window, canvasFill: .flat(color.window),
                               opaqueCanvasFill: color.window),
            surface: Surface(
                panelFill: .flat(color.panel), panelEdge: color.hair,
                panelShadow: ThemeShadow(opacity: 0, radius: 0, y: 0),
                markFill: color.well, markEdge: color.border,
                fieldFill: color.well, fieldEdge: color.border,
                controlFill: .flat(color.window.opacity(0)), controlEdge: color.border, controlInk: color.foreground,
                primaryFill: .flat(color.focus), primaryEdge: color.focus,
                chipFill: color.well, tagFill: color.well, tagEdge: color.border,
                selectedFill: .flat(color.selection), selectedEdge: color.border,
                unselectedFill: color.well, unselectedEdge: color.hair,
                footerFill: color.well, headerFill: color.well,
                softInk: color.foreground, quietInk: color.secondary,
                attentionFill: color.attention.opacity(0.12), attentionEdge: color.attention.opacity(0.45),
                highlightFill: color.attention, highlightInk: color.onAccent,
                hitFill: color.foreground.opacity(0.06), hitMarker: color.focus,
                switchTint: color.working),
            style: Style(buttonShape: .rectangle, statusMark: .lamp, switchShape: .square),
            radius: Radius(tile: 2, control: 2, chip: 1),
            line: Line(hairline: 1, selectedMarker: 2, focusedField: 1.5),
            type: type,
            pageType: PageType(pageTitle: system(20, .semibold), detailTitle: type.title, sectionTitle: type.title,
                               groupTitle: type.title, control: mono(12, .medium), meta: type.sub),
            space: Space(sectionInset: 14, bandTop: 10, bandBottom: 12, sectionGap: 18,
                         controlHeight: 24, controlHeightLarge: 28, fieldHeight: 30, rowIcon: 28,
                         tabHeight: 34, chipHeightMin: 16, chipHeightMax: 18, pageInset: 24, rowHeight: 34),
            motion: Motion(fast: 0.10, standard: 0.18, slow: 0.25, pulse: 1.4, travel: 6, curve: .easeOut))
    }()
}
