import SwiftUI

// ATOMIC LEVEL: Atoms (theme layer).
// Theme-aware forms of the atoms that workspace pages use. Each reads only `\.theme`, takes
// values and emits a targeted action. The atoms in Atoms.swift stay as they are because the
// cockpit and the exempt console surfaces still use them.
//
//   ThemeRule         one hairline, horizontal or vertical
//   themePanel        raised region: fill, edge, radius and shadow from the theme
//   themeField        sunken input box
//   ThemeHeading      small heading over a group (a kicker in black glass, a mono heading in console)
//   ThemeStatus       state: a dot or a lamp, plus its word
//   ThemeButtonStyle  standard and primary actions
//   themeSwitch       switch form for a Toggle
//   ThemeCanvas       window backdrop for a page drawn outside the cockpit shell

/// One-point separator in the theme's hair role.
struct ThemeRule: View {
    @Environment(\.theme) private var theme
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(.theme(\.color.hair))
            .frame(width: vertical ? theme.line.hairline : nil, height: vertical ? nil : theme.line.hairline)
            .accessibilityHidden(true)
    }
}

/// Raised region for content. `radius` is the most the region may round; the theme's tile radius caps it.
struct ThemePanel: ViewModifier {
    @Environment(\.theme) private var theme
    var radius: CGFloat = .infinity
    var edge: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(radius, theme.radius.tile), style: .continuous)
        let shadow = theme.surface.panelShadow
        content
            .background(theme.surface.panelFill.style)
            .clipShape(shape)
            .overlay {
                if let edge {
                    shape.strokeBorder(edge, lineWidth: theme.line.hairline)
                } else {
                    shape.strokeBorder(.theme(\.surface.panelEdge), lineWidth: theme.line.hairline)
                }
            }
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }
}

/// Sunken input container. The edge turns `focus` when the field has focus.
struct ThemeField: ViewModifier {
    @Environment(\.theme) private var theme
    var focused = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        content
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, minHeight: theme.space.fieldHeight, alignment: .leading)
            .background(theme.surface.fieldFill.color, in: shape)
            .overlay {
                if focused {
                    shape.strokeBorder(.theme(\.color.focus), lineWidth: theme.line.focusedField)
                } else {
                    shape.strokeBorder(.theme(\.surface.fieldEdge), lineWidth: theme.line.hairline)
                }
            }
    }
}

extension View {
    func themePanel(radius: CGFloat = .infinity, edge: Color? = nil) -> some View {
        modifier(ThemePanel(radius: radius, edge: edge))
    }

    func themeField(focused: Bool = false) -> some View { modifier(ThemeField(focused: focused)) }

    /// The theme's switch form for a Toggle.
    func themeSwitch() -> some View { modifier(ThemeSwitch()) }
}

/// Small heading over a group, in the theme's `heading` role and secondary ink.
struct ThemeHeading: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text).themeType(theme.type.heading).foregroundStyle(.theme(\.color.secondary))
    }
}

/// A state: its mark and its word. Colour never carries the state alone: black glass pairs the
/// dot with the word (and a symbol under Differentiate Without Colour), console gives each tone
/// its own lamp shape.
struct ThemeStatus: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    let text: String
    let tone: Tone
    var symbol: String = "circle.fill"

    var body: some View {
        HStack(spacing: 6) {
            switch theme.style.statusMark {
            case .lamp:
                MultiplayerLamp(kind: lamp)
            case .dot:
                if differentiate && symbol != "circle.fill" {
                    Image(systemName: symbol).font(.system(size: theme.type.state.size - 1, weight: .semibold))
                } else {
                    Circle().frame(width: 6, height: 6)
                }
            }
            Text(text).lineLimit(1)
        }
        .themeType(theme.type.state)
        .foregroundStyle(.theme(tone.role))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var lamp: MultiplayerLamp.Kind {
        switch tone {
        case .working: .on
        case .attention: .busy
        case .failure: .error
        case .focus: .unknown
        case .neutral: .off
        }
    }
}

/// An action. `prominent` is the one primary action of a region; `compact` fits a toolbar row.
struct ThemeButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = theme.controlShape
        configuration.label
            .themeType(theme.pageType.control)
            .foregroundStyle(.theme(prominent ? \.color.onAccent : \.surface.controlInk))
            .lineLimit(1)
            .padding(.horizontal, Space.m + 2)
            .frame(height: compact ? theme.space.controlHeight : theme.space.controlHeightLarge)
            .background((prominent ? theme.surface.primaryFill : theme.surface.controlFill).style, in: shape)
            .overlay { shape.strokeBorder(.theme(prominent ? \.surface.primaryEdge : \.surface.controlEdge)) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(shape)
            .animation(theme.motion.animation(theme.motion.fast), value: configuration.isPressed)
    }
}

struct ThemeSwitch: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        switch theme.style.switchShape {
        case .native: content.toggleStyle(.switch).tint(theme.surface.switchTint.color)
        case .square: content.toggleStyle(MultiplayerSwitchStyle())
        }
    }
}

/// Window backdrop for a page shown outside the cockpit shell (headless renders, auxiliary windows).
/// It is always opaque: the theme's window colour under its canvas fill.
struct ThemeCanvas<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.usesOpaqueSurfaces) private var opaque
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(.theme(\.color.foreground))
            .background {
                if opaque { theme.material.opaqueCanvasFill.color } else { Rectangle().fill(theme.material.canvasFill.style) }
            }
            .background(theme.color.window.color)
    }
}

/// The main window's footer: the app's version from its bundle, on the footer fill under a hairline.
struct AppVersionFooter: View {
    @Environment(\.theme) private var theme
    var version: String = AppVersionFooter.bundleVersion

    /// The git version the build stamped ("v0.1.0-pilot.3-236-g441beb9"), else "0.1.0 (1)" from the
    /// bundle; "Development build" when run outside a bundle.
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        if let git = info?["AgentCommanderGitVersion"] as? String, !git.isEmpty { return git }
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }

    var body: some View {
        VStack(spacing: 0) {
            ThemeRule()
            HStack {
                Spacer(minLength: Space.m)
                Text("Agent Commander \(version)").themeType(theme.type.sub)
                    .foregroundStyle(.theme(\.color.secondary))
                    .textSelection(.enabled)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 22)
            .background(theme.surface.footerFill.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent Commander version \(version)")
    }
}
