import SwiftUI

// ATOMIC LEVEL: Foundations.
// Locally owned semantic tokens for the black-glass appearance. Names and base values mirror
// design/system/tokens.json; the extra surface roles are taken from the original concept CSS
// (glass.css and cockpit.css). Tokens hold values only. They own no view, subscriber or action.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Palette {
    // tokens.json "color"
    static let window = Color(hex: 0x090A0D)
    static let panel = Color(hex: 0x14151A)
    static let well = Color(hex: 0x0B0C10)
    static let border = Color(hex: 0x383B44)
    static let foreground = Color(hex: 0xF5F5F9)
    static let secondary = Color(hex: 0xB7BAC6)
    static let focus = Color(hex: 0xB5D6FF)
    static let working = Color(hex: 0xA8E0C0)
    static let attention = Color(hex: 0xF1C587)
    static let failure = Color(hex: 0xEC9B92)
    static let live = Color(hex: 0xD67B6A)              // the agent is working on its turn
    static let selection = Color(hex: 0x283344)
    static let onAccent = Color(hex: 0x101825)
    static let opaqueChrome = Color(hex: 0x15161A)
    static let opaqueOverlay = Color(hex: 0x1A1D24)
    static let strongBorder = Color(hex: 0xA6A8B2)
    static let strongSecondary = Color(hex: 0xE3E5EC)

    // Surface roles from the concept CSS.
    static let chrome = Color(hex: 0x1C1D24)            // tile and console headers
    static let footer = Color(hex: 0x17181F)            // tile footer and ownership row
    static let groupFill = Color(hex: 0x101117, opacity: 0.73)
    static let field = Color(hex: 0x111218)
    static let fieldBorder = Color(hex: 0x464957)
    static let hairline = Color.white.opacity(0.11)
    static let edge = Color.white.opacity(0.16)         // card outline
    static let groupEdge = Color.white.opacity(0.22)
    static let controlFill = Color(hex: 0x2B2D36)
    static let controlEdge = Color.white.opacity(0.22)

    // Conversation roles (Pretty display). The developer's bubble is the `selection` hue deepened
    // toward `focus`, opaque so it reads the same with reduced transparency.
    static let userBubble = Color(hex: 0x1F3560)
    static let userBubbleInk = Color(hex: 0xEAF2FF)

    // Depth roles: black-violet layers over the window material, and the lit rim on glass edges.
    static let depthTop = Color(hex: 0x0C0C15, opacity: 0.80)
    static let depthMid = Color(hex: 0x040409, opacity: 0.86)
    static let depthBottom = Color(hex: 0x0D0C17, opacity: 0.74)
    static let canvasTop = Color(hex: 0x030408, opacity: 0.46)
    static let canvasMid = Color(hex: 0x040508, opacity: 0.66)
    static let canvasBottom = Color(hex: 0x0B0B12, opacity: 0.44)
    static let panelTop = Color(hex: 0x1A1B22)
    static let panelBottom = Color(hex: 0x0C0D12)
    static let rimBright = Color.white.opacity(0.46)
    static let rimDim = Color.white.opacity(0.10)
    static let windowRim = Color.white.opacity(0.62)
    static let glassTintTop = Color(hex: 0x4A4C5E, opacity: 0.42)
    static let glassTintMid = Color(hex: 0x15161F, opacity: 0.78)
    static let glassTintBottom = Color(hex: 0x242532, opacity: 0.70)
    static let stackBackTop = Color(hex: 0x3D3E4C)
    static let stackBackBottom = Color(hex: 0x1D1E27)

    // Terminal text roles.
    static let terminalText = Color(hex: 0xD3D7E1)
    static let terminalDim = Color(hex: 0xB5B9C5)
    static let assignmentFill = Color(hex: 0x1C202A)
    static let assignmentRule = Color(hex: 0x8AA6CE)

    // State surfaces.
    static let workingFill = Color(hex: 0x172B22)
    static let workingEdge = Color(hex: 0x43634E)
    static let attentionFill = Color(hex: 0x28251D)
    static let attentionFooter = Color(hex: 0x29251D)
    static let attentionEdge = Color(hex: 0xAA7C47)
    static let attentionSoftEdge = Color(hex: 0x665236)
    static let ownerFill = Color(hex: 0x29322D)
    static let ownerEdge = Color(hex: 0x4A564E)
    static let ownerText = Color(hex: 0xDAE4DD)
    static let heldFill = Color(hex: 0x263821)
    static let heldEdge = Color(hex: 0x536C47)
    static let heldText = Color(hex: 0xD0EDBB)
    static let handbackFill = Color(hex: 0x384346)
    static let handbackEdge = Color(hex: 0x788486)

    // Selected navigation row and primary action.
    static let navActiveTop = Color(hex: 0xCCD7ED, opacity: 0.22)
    static let navActiveBottom = Color(hex: 0x7389B6, opacity: 0.15)
    static let navActiveEdge = Color(hex: 0xB9C5E4, opacity: 0.25)
    static let accentTop = Color(hex: 0xE4EFFF)
    static let accentMid = Color(hex: 0xB5D5FB)
    static let accentBottom = Color(hex: 0x96B8EA)
}

/// Terminal inks: the restrained ANSI-like set used inside every terminal surface (coordinator,
/// worker tiles, focused worker, PiP). Black glass stays outside the terminals. Each ink has one
/// meaning and is always paired with a glyph or a word, so color never carries state alone.
enum Term {
    /// sRGB values, shared by the SwiftUI colors below and the AppKit text renderer.
    enum Hex {
        static let background: UInt32 = 0x090A0D
        static let bar: UInt32 = 0x0E1014
        static let rule: UInt32 = 0x23262D
        static let text: UInt32 = 0xD9DCE3
        static let bright: UInt32 = 0xF5F5F9
        static let dim: UInt32 = 0x808794       // metadata
        static let cyan: UInt32 = 0x7FD4E6      // commands, paths, agent labels
        static let violet: UInt32 = 0xB9A2F2    // tool names
        static let amber: UInt32 = 0xF1C587     // pending input
        static let green: UInt32 = 0xA8E0C0     // success, answered
        static let red: UInt32 = 0xEC9B92       // failure
    }

    static let background = Color(hex: Hex.background)
    static let bar = Color(hex: Hex.bar)
    static let rule = Color(hex: Hex.rule)
    static let text = Color(hex: Hex.text)
    static let bright = Color(hex: Hex.bright)
    static let dim = Color(hex: Hex.dim)
    static let cyan = Color(hex: Hex.cyan)
    static let violet = Color(hex: Hex.violet)
    static let amber = Color(hex: Hex.amber)
    static let green = Color(hex: Hex.green)
    static let red = Color(hex: Hex.red)
    static let amberWash = Color(hex: Hex.amber, opacity: 0.08)
    static let promptEdge = Color(hex: 0x4A4E5A)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Terminal metadata ink. Increase Contrast swaps in `strongSecondary`.
struct TermDimInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.usesStrongContrast ? Palette.strongSecondary : Term.dim
    }
}

extension ShapeStyle where Self == TermDimInk {
    static var inkTermDim: TermDimInk { TermDimInk() }
}

// Appearance resolution. The system settings are read-only in SwiftUI, so a page that must show the
// reduced-transparency or increased-contrast roles regardless of the system (the accessibility
// design previews) sets these overrides. Styles read the combined `uses…` values only.

private struct ReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IncreaseContrastOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reduceTransparencyOverride: Bool {
        get { self[ReduceTransparencyOverrideKey.self] }
        set { self[ReduceTransparencyOverrideKey.self] = newValue }
    }

    var increaseContrastOverride: Bool {
        get { self[IncreaseContrastOverrideKey.self] }
        set { self[IncreaseContrastOverrideKey.self] = newValue }
    }

    /// True when glass must be replaced by the opaque surface roles.
    var usesOpaqueSurfaces: Bool { accessibilityReduceTransparency || reduceTransparencyOverride }

    /// True when the stronger border and secondary-text roles apply.
    var usesStrongContrast: Bool { colorSchemeContrast == .increased || increaseContrastOverride }
}

/// Secondary text. Increase Contrast swaps in `strongSecondary` (tokens.json appearanceOverrides).
struct SecondaryInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.usesStrongContrast ? Palette.strongSecondary : Palette.secondary
    }
}

/// Card outline. Increase Contrast swaps in `strongBorder`.
struct EdgeInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.usesStrongContrast ? Palette.strongBorder : Palette.edge
    }
}

/// Interior separator. Increase Contrast swaps in `strongBorder`.
struct HairlineInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.usesStrongContrast ? Palette.strongBorder : Palette.hairline
    }
}

extension ShapeStyle where Self == SecondaryInk {
    static var inkSecondary: SecondaryInk { SecondaryInk() }
}

extension ShapeStyle where Self == EdgeInk {
    static var inkEdge: EdgeInk { EdgeInk() }
}

extension ShapeStyle where Self == HairlineInk {
    static var inkHairline: HairlineInk { HairlineInk() }
}

/// tokens.json "space".
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// tokens.json "radius", plus control radii used by the concepts.
enum Radius {
    static let tile: CGFloat = 13
    static let group: CGFloat = 15
    static let overlay: CGFloat = 17
    static let canvas: CGFloat = 17
    static let sidebar: CGFloat = 19
    static let field: CGFloat = 9
    static let avatar: CGFloat = 8
    static let chip: CGFloat = 4
}

/// tokens.json "layout", plus the measured positions of the 1600 x 1000 concept window.
enum Metric {
    static let toolbarHeight: CGFloat = 52
    static let railWidth: CGFloat = 54
    static let sidebarWidth: CGFloat = 204
    static let navigationLeading: CGFloat = 9
    static let navigationTrailing: CGFloat = 3
    static let navigationBottom: CGFloat = 11

    static let runHeaderHeight: CGFloat = 106
    static let runHeaderInset: CGFloat = 27
    static let sectionBarHeight: CGFloat = 59
    static let paneInset: CGFloat = 20
    static let paneBottom: CGFloat = 21

    static let coordinatorFraction: Double = 0.32          // concept grid: minmax(0, 32%)
    static let minimumCoordinatorWidth: CGFloat = 320
    static let minimumWorkerRegionWidth: CGFloat = 340
    static let dividerHitWidth: CGFloat = 8

    static let tileGap: CGFloat = 10
    static let wallRowGap: CGFloat = 17
    static let minimumTileWidth: CGFloat = 300
    static let minimumWallRowHeight: CGFloat = 250
    static let tileInset: CGFloat = 11
    static let groupHeaderHeight: CGFloat = 38
    static let ownershipRowHeight: CGFloat = 34
    static let handbackHeight: CGFloat = 29

    static let pipWidth: CGFloat = 350
    static let pipTrailing: CGFloat = 20
    static let pipBottom: CGFloat = 42
    static let pipReservedWidth: CGFloat = 367             // concept: nested row is 100% - 367
    static let attentionDrawerWidth: CGFloat = 304

    static let sheetInset: CGFloat = 36
    static let sheetAsideWidth: CGFloat = 460
    static let sheetFooterHeight: CGFloat = 68
    static let fieldHeight: CGFloat = 40
}

/// tokens.json "type". The page title follows the concept render (33 pt) rather than the 32 pt starting size.
enum TypeRole {
    static let pageTitle = Font.system(size: 33, weight: .semibold)
    static let focusTitle = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 19, weight: .semibold)
    static let consoleName = Font.system(size: 16, weight: .semibold)
    static let tileName = Font.system(size: 14, weight: .semibold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 14)
    static let control = Font.system(size: 13, weight: .medium)
    static let ownership = Font.system(size: 12, weight: .semibold)
    static let label = Font.system(size: 12.5, weight: .semibold)
    static let meta = Font.system(size: 11.5)
    static let caption = Font.system(size: 11)
    static let provider = Font.system(size: 10)
    static let kicker = Font.system(size: 10, weight: .semibold)
    static let terminal = Font.system(size: 13, design: .monospaced)
    static let terminalSmall = Font.system(size: 12, design: .monospaced)
    static let monoMeta = Font.system(size: 10, design: .monospaced)
    static let monoID = Font.system(size: 11, design: .monospaced)
    static let timestamp = Font.system(size: 10.75, design: .monospaced)

    static let wallTerminalSize: CGFloat = 12.7
    static let focusTerminalSize: CGFloat = 13
}
