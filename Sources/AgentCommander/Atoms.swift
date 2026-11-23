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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    @Environment(\.colorSchemeContrast) private var contrast
    let active: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(Palette.focus, lineWidth: contrast == .increased ? 3 : 2)
                    .padding(-5)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
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

    private var ink: Color {
        switch client {
        case .claude: Palette.claudeInk
        case .codex: Palette.codexInk
        case .mcp: Palette.mcpInk
        case .other: Palette.secondary
        }
    }

    private var fill: Color {
        switch client {
        case .claude: Palette.claudeFill
        case .codex: Palette.codexFill
        case .mcp: Palette.mcpFill
        case .other: Palette.chrome
        }
    }

    private var edge: Color {
        switch client {
        case .claude: Palette.claudeEdge
        case .codex: Palette.codexEdge
        case .mcp: Palette.mcpEdge
        case .other: Palette.border
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.avatar, style: .continuous)
        Group {
            switch client {
            case .claude: Image(systemName: "asterisk").font(.system(size: size * 0.58, weight: .bold))
            case .codex: Text(">_").font(.system(size: size * 0.5, weight: .bold, design: .monospaced)).tracking(-1.5)
            case .mcp: Image(systemName: "command").font(.system(size: size * 0.5, weight: .semibold))
            case .other: Image(systemName: "terminal").font(.system(size: size * 0.46, weight: .semibold))
            }
        }
        .foregroundStyle(ink)
        .frame(width: size, height: size)
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(edge) }
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
