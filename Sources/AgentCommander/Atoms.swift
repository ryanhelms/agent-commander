import AppKit
import SwiftUI

// ATOMIC LEVEL: Atoms.
// The smallest usable elements. Native controls (Button, TextField, Menu, Divider) are used directly
// as atoms wherever they already supply the behavior; the types here add Commander's token styling
// or a required accessibility contract. `TerminalWell` (Components.swift) is the AppKit atom.

// MARK: - Surfaces

/// Opaque card surface for content and terminal containers.
struct PanelSurface: ViewModifier {
    var radius: CGFloat = Radius.tile
    var edge: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(LinearGradient(colors: [Palette.panelTop, Palette.panelBottom],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(shape)
            .overlay {
                if let edge { shape.strokeBorder(edge, lineWidth: 1) } else { shape.strokeBorder(.inkEdge, lineWidth: 1) }
            }
            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
    }
}

/// System glass for navigation and floating controls. One glass surface per visual group.
/// Reduce Transparency swaps in the opaque fallback from tokens.json.
struct GlassSurface: ViewModifier {
    enum Role { case navigation, floating }

    @Environment(\.usesOpaqueSurfaces) private var reduceTransparency
    let role: Role
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content
                .background(role == .navigation ? Palette.opaqueChrome : Palette.opaqueOverlay, in: shape)
                .overlay { shape.strokeBorder(Palette.strongBorder, lineWidth: 1) }
        } else {
            // A dark violet tint inside the glass gives it depth; the lit rim marks its edge.
            content
                .background(LinearGradient(colors: [Palette.glassTintTop, Palette.glassTintMid, Palette.glassTintBottom],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [Palette.rimBright, Palette.rimDim, Palette.rimDim],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// Exterior keyboard-focus ring. Separate from selection fill and from input ownership.
struct FocusRing: ViewModifier {
    @Environment(\.usesStrongContrast) private var strongContrast
    let active: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(Palette.focus, lineWidth: strongContrast ? 3 : 2)
                    .padding(-5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The surface of an embedded terminal console: the coordinator, a wall tile, the focused worker
/// and the terminal inside the PiP. It is square: the clip and the border are drawn from the same
/// rectangle. It draws no keyboard-focus outline; a console with key focus says so in its status
/// line. `raised` adds the panel fill and shadow for a console that stands alone in a pane; the
/// PiP's inner terminal sits flat inside its glass container.
struct ConsoleSurface: ViewModifier {
    var edge: Color? = nil
    var raised = true
    /// Width of a supplied `edge`. Harness consoles pass a heavier line; other surfaces keep 1.
    var edgeWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background {
                if raised {
                    LinearGradient(colors: [Palette.panelTop, Palette.panelBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else {
                    Term.background
                }
            }
            .clipShape(Rectangle())
            .overlay {
                if let edge {
                    Rectangle().strokeBorder(edge, lineWidth: edgeWidth)
                } else if raised {
                    Rectangle().strokeBorder(.inkEdge, lineWidth: 1)
                } else {
                    Rectangle().strokeBorder(.inkHairline, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(raised ? 0.22 : 0), radius: 6, y: 3)
    }
}

/// The mark of a surface that is waiting for the developer: an amber border with a soft glow
/// whose opacity rises and falls slowly. With Reduce Motion on, the glow is steady. It sits over
/// the surface's own edge and takes the same shape, square for a console (`radius` 0). It is
/// decoration only: the waiting state is always also stated in text. The pulse is a Core Animation
/// opacity animation, so it runs in the render server and SwiftUI never re-evaluates the content.
struct AttentionGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    var radius: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                AttentionGlowLayer(radius: radius, reduceMotion: reduceMotion)
                    .padding(-AttentionGlowView.bleed)   // room for the shadow outside the surface
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct AttentionGlowLayer: NSViewRepresentable {
    let radius: CGFloat
    let reduceMotion: Bool

    func makeNSView(context: Context) -> AttentionGlowView { AttentionGlowView() }
    func updateNSView(_ view: AttentionGlowView, context: Context) {
        guard view.radius != radius || view.reduceMotion != reduceMotion else { return }
        view.radius = radius
        view.reduceMotion = reduceMotion
        view.needsLayout = true
    }
}

/// Draws the edge and its two shadows as static layers and pulses their shared parent's opacity.
private final class AttentionGlowView: NSView {
    static let bleed: CGFloat = 24
    var radius: CGFloat = 0
    var reduceMotion = false
    private let glow = CALayer(), edge = CALayer(), wide = CALayer(), tight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let tint = NSColor(Palette.attention).cgColor
        edge.borderColor = tint.copy(alpha: 0.9)
        edge.borderWidth = 1
        edge.cornerCurve = .continuous
        // SwiftUI shadowed a 0.9-alpha stroke at 0.5 and 0.35: the same products are used here.
        for (layer, blur, alpha) in [(wide, CGFloat(7), Float(0.45)), (tight, CGFloat(2), Float(0.315))] {
            layer.shadowColor = tint
            layer.shadowRadius = blur
            layer.shadowOpacity = alpha
            layer.shadowOffset = .zero
            glow.addSublayer(layer)
        }
        glow.addSublayer(edge)
        layer?.addSublayer(glow)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncPulse() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); syncPulse() }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: Self.bleed, dy: Self.bleed)
        guard rect.width > 1, rect.height > 1 else { return }
        let corner = min(radius, min(rect.width, rect.height) / 2)
        let ring = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(corner - 0.5, 0),
                          cornerHeight: max(corner - 0.5, 0), transform: nil)
            .copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        edge.frame = rect
        edge.cornerRadius = corner
        wide.shadowPath = ring
        tight.shadowPath = ring
        CATransaction.commit()
        syncPulse()
    }

    /// Runs the pulse only while the view is in a window and motion is allowed.
    private func syncPulse() {
        let run = window != nil && superview != nil && !reduceMotion
        glow.opacity = reduceMotion ? 0.85 : 1
        guard run != (glow.animation(forKey: "pulse") != nil) else { return }
        guard run else { return glow.removeAnimation(forKey: "pulse") }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.5
        pulse.duration = 1.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "pulse")
    }
}

extension View {
    func attentionGlow(_ active: Bool, radius: CGFloat = 0) -> some View {
        modifier(AttentionGlow(active: active, radius: radius))
    }

    func consoleSurface(edge: Color? = nil, raised: Bool = true, edgeWidth: CGFloat = 1) -> some View {
        modifier(ConsoleSurface(edge: edge, raised: raised, edgeWidth: edgeWidth))
    }

    func panelSurface(radius: CGFloat = Radius.tile, edge: Color? = nil) -> some View {
        modifier(PanelSurface(radius: radius, edge: edge))
    }

    func glassSurface(_ role: GlassSurface.Role, radius: CGFloat) -> some View {
        modifier(GlassSurface(role: role, radius: radius))
    }

    func focusRing(_ active: Bool, radius: CGFloat = Radius.tile) -> some View {
        modifier(FocusRing(active: active, radius: radius))
    }
}

/// One-point separator in the hairline role.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(.inkHairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Terminal atoms

/// Status inside a terminal surface: a glyph and the lowercase state in the state's ink.
struct TerminalStatus: View {
    let state: TaskState
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: size * 0.5) {
            Text(state.glyph)
            Text(state.label.lowercased())
        }
        .font(Term.font(size))
        .foregroundStyle(state.ink)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
    }
}

/// The link to a worker's execution host while a persistent SSH connection is being
/// re-established. It sits beside the worker's own status, which it does not replace: the worker
/// keeps running on the host. Nothing is drawn for a connected host. The terminal style is for
/// status lines and gives up its word in a narrow tile, keeping the mark. The label style is for
/// panels and headers. Both carry the host in the help tag and the accessibility label.
struct HostLinkStatus: View {
    enum Style { case terminal, label }

    let host: String
    var style: Style = .terminal
    var size: CGFloat = 11.5

    private var statement: String {
        "The SSH link to \(host) is reconnecting. Work on \(host) keeps running."
    }

    var body: some View {
        Group {
            switch style {
            case .terminal:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: size * 0.5) {
                        Text("↻")
                        Text("reconnecting")
                    }
                    .fixedSize()
                    Text("↻").fixedSize()
                }
                .font(Term.font(size))
                .foregroundStyle(Term.amber)
            case .label:
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: size - 1.5, weight: .semibold))
                    Text("Reconnecting")
                }
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.attention)
                .fixedSize()
            }
        }
        .lineLimit(1)
        .help(statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host \(host) reconnecting")
        .accessibilityValue(statement)
    }
}

/// Terminal-styled action, drawn as `[ label ]`. It is a real button: Tab reaches it, Space
/// activates it, and it inverts under the pointer and while pressed.
struct TermButtonStyle: ButtonStyle {
    var ink: Color = Term.bright
    var size: CGFloat = 11.5

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, ink: ink, size: size)
    }

    private struct Face: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: ButtonStyleConfiguration
        let ink: Color
        let size: CGFloat

        var body: some View {
            let inverted = isEnabled && (isHovered || configuration.isPressed)
            HStack(spacing: 0) {
                Text("[ ").accessibilityHidden(true)
                configuration.label
                Text(" ]").accessibilityHidden(true)
            }
            .font(Term.font(size))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(inverted ? AnyShapeStyle(Term.background) : isEnabled ? AnyShapeStyle(ink) : AnyShapeStyle(.inkTermDim))
            .background(inverted ? ink : .clear)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }
}

/// A muted key hint in a terminal status line. Shown only for a key that acts in the current state.
struct TermHint: View {
    let keys: String
    let action: String
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: size * 0.55) {
            Text(keys).foregroundStyle(Term.text)
            Text(action).foregroundStyle(.inkTermDim)
        }
        .font(Term.font(size))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys) \(action)")
    }
}

// MARK: - Status and identity

/// Status label: a dot or symbol plus text. Color never carries the state alone.
struct StatusLabel: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    let text: String
    let tone: Tone
    var symbol: String = "circle.fill"
    var size: CGFloat = 11.5
    var pill = false

    var body: some View {
        HStack(spacing: 6) {
            if differentiate && symbol != "circle.fill" {
                Image(systemName: symbol).font(.system(size: size - 1, weight: .semibold))
            } else {
                Circle().frame(width: 6, height: 6)
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, pill ? 8 : 0)
        .padding(.vertical, pill ? 4 : 0)
        .background {
            if pill {
                Capsule().fill(tone == .working ? Palette.workingFill : Palette.attentionFill)
                    .overlay { Capsule().strokeBorder(tone == .working ? Palette.workingEdge : Palette.attentionSoftEdge) }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    init(_ state: TaskState, size: CGFloat = 11.5, pill: Bool = false) {
        self.init(text: state.label, tone: state.tone, symbol: state.symbol, size: size, pill: pill)
    }

    init(text: String, tone: Tone, symbol: String = "circle.fill", size: CGFloat = 11.5, pill: Bool = false) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
        self.size = size
        self.pill = pill
    }
}

/// Client identity mark. The provider supplies attribution only; it never selects a tile implementation.
struct AgentAvatar: View {
    let client: AgentClient
    var size: CGFloat = 30
    /// Set by console title bars, where the mark sits on the harness-coloured header: a dark well,
    /// a stronger edge and a brightened, heavier glyph replace the tint-on-tint treatment.
    var onHarnessHeader = false

    @Environment(\.usesStrongContrast) private var usesStrongContrast
    @Environment(\.usesOpaqueSurfaces) private var usesOpaqueSurfaces

    var body: some View {
        let accent = HarnessAccentStore.shared.accent(for: client)
        let ink = onHarnessHeader ? accent.headerGlyph(strong: usesStrongContrast)
                                  : accent.ink(strong: usesStrongContrast)
        let fill = onHarnessHeader ? accent.headerWell(opaque: usesOpaqueSurfaces)
                                   : accent.fill(opaque: usesOpaqueSurfaces)
        let edge = onHarnessHeader ? accent.headerAvatarEdge(strong: usesStrongContrast) : accent.avatarEdge
        // A small mark (console title bars) keeps a squared corner instead of rounding into a dot.
        let shape = RoundedRectangle(cornerRadius: min(Radius.avatar, size * 0.28), style: .continuous)
        let symbolWeight: Font.Weight = onHarnessHeader ? .bold : .semibold
        // 16/18 pt badges give the mark more of the well so its counters stay open; larger tiles keep air.
        let isBadge = size <= 20
        let markSide = (size * (isBadge ? 0.72 : 0.6)).rounded()
        Group {
            if let mark = HarnessMarkLibrary.image(for: client) {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: markSide, height: markSide)
            } else {
                // MCP is a protocol, not a product: it shares the native terminal with shells and custom names.
                Image(systemName: "terminal")
                    .font(.system(size: size * (isBadge ? 0.54 : 0.46), weight: symbolWeight))
            }
        }
        .foregroundStyle(ink)
        .frame(width: size, height: size)
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(edge) }
        .accessibilityHidden(true)
        .registersHarness(client)
    }
}

/// Which bundled product mark, if any, stands for a client. Typed identity only — never a session title.
enum HarnessMark {
    /// File stem inside `HarnessIcons`, or nil for the native terminal symbol (MCP, shells, custom, unknown).
    nonisolated static func assetName(for client: AgentClient) -> String? {
        switch client {
        case .claude: return "claudecode"
        case .codex: return "codex"
        case .mcp: return nil
        case .other(let name):
            // Exact normalized product-profile aliases; presentation only, routing stays `.other`.
            switch HarnessName.normalize(name) {
            case "agy", "antigravity", "antigravity cli", "antigravity-cli": return "antigravity"
            case "gemini", "gemini cli", "gemini-cli": return "geminicli"
            default: return nil
            }
        }
    }
}

/// Loads the local 24×24 single-ink template SVGs once. No network, no files outside the app's own resources.
@MainActor
enum HarnessMarkLibrary {
    private static let bundleName = "AgentCommander_AgentCommander.bundle"
    private static let directory = "HarnessIcons"
    private static var cache: [String: NSImage?] = [:]

    /// Nil means "draw the fallback symbol": unmapped client, missing bundle, or missing/unreadable asset.
    static func image(for client: AgentClient) -> NSImage? {
        guard let name = HarnessMark.assetName(for: client) else { return nil }
        if let cached = cache[name] { return cached }
        let image = load(name)
        cache[name] = image
        return image
    }

    private static let resources: Bundle? = {
        // Shipped .app: nested in Contents/Resources. SwiftPM launch: sibling of the executable.
        // `Bundle(url:)` is optional, so an absent or invalid bundle falls through to the terminal
        // symbol; `Bundle.module` is avoided because it traps when its bundle is missing.
        for root in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let url = root?.appendingPathComponent(bundleName, isDirectory: true),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    private static func load(_ name: String) -> NSImage? {
        guard let url = resources?.url(forResource: name, withExtension: "svg", subdirectory: directory),
              let image = NSImage(contentsOf: url), image.isValid
        else { return nil }
        image.isTemplate = true
        return image
    }
}

/// Mark for the platform a terminal executes on: the Apple logo for macOS, the word `linux` for
/// Linux, and a neutral host symbol when the platform is not reported. Decorative; the title bar
/// that shows it carries the spoken platform name.
struct PlatformMark: View {
    let platform: HostPlatform
    var size: CGFloat = 10
    /// Console title bars pass a brighter ink; other uses keep the terminal text colour.
    var tint: Color = Term.text

    var body: some View {
        Group {
            switch platform {
            case .localMac, .remoteMac:
                Image(systemName: "apple.logo").font(.system(size: size))
            case .remoteLinux:
                Text("linux").font(Term.font(size - 0.5, weight: .semibold))
            case .unknown:
                Image(systemName: "desktopcomputer").font(.system(size: size - 1, weight: .medium))
            }
        }
        .foregroundStyle(tint)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Application mark for the navigation rail.
struct BrandMark: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Image(systemName: "terminal.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: 32, height: 32)
            .background(LinearGradient(colors: [.white, Color(hex: 0xCBD0DD), Color(hex: 0x8C96AC)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .accessibilityLabel("Agent Commander")
    }
}

/// Single-letter project mark.
struct ProjectMark: View {
    let letter: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(letter)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(hex: 0xDCE8FE))
            .frame(width: 17, height: 17)
            .background(Color(hex: 0x32394A, opacity: 0.57), in: shape)
            .overlay { shape.strokeBorder(Color(hex: 0x8293B6, opacity: 0.42)) }
            .accessibilityHidden(true)
    }
}

// MARK: - Small labels

/// Keyboard key cap for shortcut hints.
struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(hex: 0xC1CAC5))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.19)) }
            .fixedSize()
    }
}

/// Count beside a section title.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(TypeRole.monoMeta)
            .foregroundStyle(Color(hex: 0xC4CFD0))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12)) }
            .accessibilityLabel("\(count) workers")
    }
}

/// Monospaced metadata with a leading symbol (host, branch, worktree).
struct MetaItem: View {
    let symbol: String
    let text: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.inkSecondary)
            Text(text).font(TypeRole.monoMeta).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Color(hex: 0xB6BDC9))
        .help(help ?? text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help ?? text)
    }
}

// MARK: - Buttons

/// Icon-only action. The accessible name is required.
struct SymbolButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Capsule control from the concepts. `prominent` is the single primary action of a surface.
struct CapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var height: CGFloat = 35

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Palette.onAccent : Color(hex: 0xEBECF4))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background {
                if prominent {
                    Capsule().fill(LinearGradient(colors: [Palette.accentTop, Palette.accentMid, Palette.accentBottom],
                                                  startPoint: .top, endPoint: .bottom))
                } else {
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0x464750, opacity: 0.66), Color(hex: 0x24262E, opacity: 0.55)],
                                                  startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { Capsule().strokeBorder(prominent ? Color(hex: 0xD9EAFF) : Palette.controlEdge) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Compact rectangular control for handing terminal input back. At least 28 pt tall (tokens.json).
struct HandbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(hex: 0xF3F5F4))
            .padding(.horizontal, 8)
            .frame(height: Metric.handbackHeight)
            .background(Palette.handbackFill, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.handbackEdge) }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Opaque input container used by text fields in sheets and replies.
struct FieldBox: ViewModifier {
    var focused = false
    var height: CGFloat? = Metric.fieldHeight

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        content
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(Palette.field, in: shape)
            .overlay { shape.strokeBorder(focused ? Palette.focus : Palette.fieldBorder, lineWidth: focused ? 1.5 : 1) }
    }
}

extension View {
    func fieldBox(focused: Bool = false, height: CGFloat? = Metric.fieldHeight) -> some View {
        modifier(FieldBox(focused: focused, height: height))
    }
}
