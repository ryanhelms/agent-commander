import AppKit
import SwiftUI

// ATOMIC LEVEL: Tokens, atoms and molecules for the network tray
// (design/mockups/commander-network-tray.html, increments 1 and 2).
// `MultiplayerTheme` is the tray's token layer. Each token names a role of the app theme
// (ThemeTokens.swift) and is resolved from `@Environment(\.theme)` where it is drawn, so the tray,
// the hosted composers and the wall's network components follow the theme the person chose.
// Nothing here asks which theme is active. Each component takes values and emits a targeted
// action; none reads the model.
//
//   Colour     `MultiplayerTheme.focus` is a `Color` that resolves its role in the environment.
//   Fill       `MultiplayerTheme.panelFill` is a shape style for a surface that may be a gradient.
//   Type       `MultiplayerTheme.sub` is a `MultiplayerType`; `.font(MultiplayerTheme.sub)` sets the
//              face, size, weight, tracking and case of that role in the current theme.
//   Shape      a view reads `@Environment(\.theme)` and asks it for `trayTile`, `trayControl`,
//              `trayChip` or `controlShape`.
//   Space      a view reads `theme.space`.

/// A colour role of the app theme, resolved where it is drawn. Increase Contrast swaps the rule
/// and outline roles as `ThemeInk` does.
struct MultiplayerInk: ShapeStyle, Hashable {
    let role: KeyPath<Theme, ThemeColor> & Sendable

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        ThemeInk(role: role).resolve(in: environment).resolve(in: environment)
    }

    static func == (left: MultiplayerInk, right: MultiplayerInk) -> Bool { left.role == right.role }
    func hash(into hasher: inout Hasher) { hasher.combine(role) }
}

/// A surface role of the app theme that may be a gradient, resolved where it is drawn.
struct MultiplayerFill: ShapeStyle {
    let role: KeyPath<Theme, ThemeFill> & Sendable

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.theme[keyPath: role].style
    }
}

/// A type role of the app theme. `.font(_:)` resolves it where it is drawn.
struct MultiplayerType: Sendable {
    let role: KeyPath<Theme, ThemeFont> & Sendable
    var digits = false

    /// Figures of equal width, so a ticking value doesn't shift.
    func monospacedDigit() -> MultiplayerType { MultiplayerType(role: role, digits: true) }

    /// The role's font in one theme, for a caller that needs a `Font` value.
    func font(in theme: Theme) -> Font {
        let font = theme[keyPath: role].font
        return digits ? font.monospacedDigit() : font
    }
}

private struct MultiplayerTypeModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let type: MultiplayerType

    nonisolated init(type: MultiplayerType) { self.type = type }

    func body(content: Content) -> some View {
        let role = theme[keyPath: type.role]
        // A role with no tracking and no case leaves both as the view inherited them.
        if role.tracking == 0, !role.uppercase {
            content.font(type.font(in: theme))
        } else {
            content.font(type.font(in: theme)).tracking(role.tracking).textCase(role.uppercase ? .uppercase : nil)
        }
    }
}

extension View {
    /// Sets a tray type role in the current theme.
    nonisolated func font(_ type: MultiplayerType) -> some View { modifier(MultiplayerTypeModifier(type: type)) }
}

enum MultiplayerTheme {
    private static func ink(_ role: KeyPath<Theme, ThemeColor> & Sendable) -> Color { Color(MultiplayerInk(role: role)) }
    private static func type(_ role: KeyPath<Theme, ThemeFont> & Sendable) -> MultiplayerType { MultiplayerType(role: role) }

    // DESIGN.md section 2 "Colour": the fourteen roles every theme has.
    static let panel = ink(\.color.panel)
    static let well = ink(\.color.well)
    static let border = ink(\.color.border)
    static let hair = ink(\.color.hair)
    static let foreground = ink(\.color.foreground)
    static let secondary = ink(\.color.secondary)
    static let focus = ink(\.color.focus)
    static let working = ink(\.color.working)
    static let attention = ink(\.color.attention)
    static let failure = ink(\.color.failure)
    static let selection = ink(\.color.selection)
    static let onAccent = ink(\.color.onAccent)

    // What each tray surface is made of. In console these are the roles above; another theme
    // gives them its own values.
    /// A raised region: the tray itself, a hosted composer, the zoom.
    static let panelFill = MultiplayerFill(role: \.surface.panelFill)
    static let panelEdge = ink(\.surface.panelEdge)
    /// The square mark and the avatar.
    static let markFill = ink(\.surface.markFill)
    static let markEdge = ink(\.surface.markEdge)
    /// A field, a text area and a sunken block.
    static let fieldFill = ink(\.surface.fieldFill)
    static let fieldEdge = ink(\.surface.fieldEdge)
    /// A standard control and the one primary action.
    static let controlFill = MultiplayerFill(role: \.surface.controlFill)
    static let controlEdge = ink(\.surface.controlEdge)
    static let controlInk = ink(\.surface.controlInk)
    static let primaryFill = MultiplayerFill(role: \.surface.primaryFill)
    static let primaryEdge = ink(\.surface.primaryEdge)
    /// A chip or a badge outline.
    static let tagEdge = ink(\.surface.tagEdge)
    /// An unselected tab.
    static let unselectedFill = ink(\.surface.unselectedFill)
    /// The footer, the status strip and a table header.
    static let footerFill = ink(\.surface.footerFill)
    static let headerFill = ink(\.surface.headerFill)
    /// A hot count.
    static let highlightFill = ink(\.surface.highlightFill)
    static let highlightInk = ink(\.surface.highlightInk)
    /// The wall's group of remote workers.
    static let groupFill = ink(\.wall.groupFill)
    static let groupEdge = ink(\.wall.groupEdge)

    /// The console theme's section inset, for a caller that can't read the environment. A view
    /// reads `theme.space.sectionInset`.
    static let sectionInset = Theme.console.space.sectionInset

    // Prose is set in the system face; anything that is data, a state or a count is monospaced.
    static let title = type(\.type.title)
    static let body = type(\.type.body)
    static let name = type(\.type.name)
    static let heading = type(\.type.heading)
    static let state = type(\.type.state)
    static let sub = type(\.type.sub)
    static let mono = type(\.type.mono)
    static let data = type(\.type.data)
    static let label = type(\.type.label)
    static let fingerprint = type(\.type.fingerprint)
    static let figure = type(\.type.figure)
    /// The wall group's title and the note beside it.
    static let groupTitle = type(\.wall.groupTitleType)
    static let groupNote = type(\.wall.groupNoteType)

    /// tokens.json color.harness.swatch: mint, sky, pink, lime.
    static let swatches = [Color(hex: 0x4ADE80), Color(hex: 0x38BDF8), Color(hex: 0xF472B6), Color(hex: 0xA3E635)]

    /// A server's colour. The contract carries none in increment 1, so it follows from the ID and
    /// stays the same across launches.
    static func swatch(for serverID: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in serverID.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return swatches[Int(hash % UInt32(swatches.count))]
    }
}

extension Theme {
    /// The outline of a whole region: the zoom, a group, the panel on its stage.
    var trayTile: RoundedRectangle { RoundedRectangle(cornerRadius: radius.tile, style: .continuous) }
    /// The outline of a field, a notice, a sunken block or joined cells.
    var trayControl: RoundedRectangle { RoundedRectangle(cornerRadius: radius.control, style: .continuous) }
    /// The outline of a chip, a badge or a mark.
    var trayChip: RoundedRectangle { RoundedRectangle(cornerRadius: radius.chip, style: .continuous) }

    /// The tray button's type: the theme's control face, one point smaller unless the button is large.
    func trayButtonType(large: Bool, primary: Bool) -> Font {
        let control = pageType.control
        return ThemeFont(face: control.face, size: control.size - (large ? 0 : 1),
                         weight: primary ? .semibold : control.weight).font
    }
}

// MARK: - Atoms

/// A status lamp. Each state has its own shape as well as its colour, and a word always sits beside it.
/// A theme whose status mark is a dot draws one round mark in the state's colour instead; the word
/// beside it still carries the state.
struct MultiplayerLamp: View {
    enum Kind: Equatable { case on, off, waiting, error, unknown, busy, away, doNotDisturb }

    let kind: Kind
    var size: CGFloat = 9
    /// A live lamp beats while it is on. Off by default, so lists of lamps stay still.
    var pulses = false
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch theme.style.statusMark {
            case .lamp: lamp
            case .dot: Circle().fill(dotColor).padding(size / 6)
            }
        }
        .frame(width: size, height: size)
        .modifier(MultiplayerPulse(isLive: pulses && kind == .on, color: MultiplayerTheme.working))
        .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch kind {
        case .on: MultiplayerTheme.working
        case .off: MultiplayerTheme.secondary
        case .waiting, .unknown: MultiplayerTheme.focus
        case .error, .doNotDisturb: MultiplayerTheme.failure
        case .busy, .away: MultiplayerTheme.attention
        }
    }

    @ViewBuilder private var lamp: some View {
            switch kind {
            case .on:
                Circle().fill(MultiplayerTheme.working)
            case .off:
                Circle().strokeBorder(.inkSecondary, lineWidth: 1.5)
            case .waiting:
                Circle().trim(from: 0.12, to: 0.88)
                    .stroke(MultiplayerTheme.focus, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(0.75)
            case .error:
                RoundedRectangle(cornerRadius: 1).fill(MultiplayerTheme.failure)
                    .padding(1)
                    .rotationEffect(.degrees(45))
            case .unknown:
                Circle().strokeBorder(MultiplayerTheme.focus, lineWidth: 1.5)
            case .busy:
                RoundedRectangle(cornerRadius: 2).fill(MultiplayerTheme.attention)
            case .away:
                Circle().strokeBorder(MultiplayerTheme.attention, lineWidth: 1.5)
                    .background {
                        Circle().fill(MultiplayerTheme.attention)
                            .mask(alignment: .leading) { Rectangle().frame(width: size / 2) }
                    }
            case .doNotDisturb:
                Circle().strokeBorder(MultiplayerTheme.failure, lineWidth: 1.5)
                    .overlay { Rectangle().fill(MultiplayerTheme.failure).frame(height: 2).padding(.horizontal, 1.5) }
            }
    }
}

extension MultiplayerServerState {
    var lamp: MultiplayerLamp.Kind {
        switch self {
        case .online: .on
        case .connecting, .keychainPending: .waiting
        case .certChanged, .error: .error
        case .signedOut, .offline: .off
        case .unknown: .unknown
        }
    }
}

extension MultiplayerPersonPresence {
    var lamp: MultiplayerLamp.Kind {
        switch self {
        case .online: .on
        case .busy: .busy
        case .away: .away
        case .dnd: .doNotDisturb
        case .offline: .off
        case .unknown: .unknown
        }
    }
}

/// The tray's switch. The track is green when on and an outline when off, in a key window or not,
/// so the two states never look alike. It draws no label; the label is still spoken. A theme whose
/// switch is native gets the system switch in the theme's tint, also without its label.
struct MultiplayerSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.theme) private var theme

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch theme.style.switchShape {
        case .native:
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(theme.surface.switchTint.color)
        case .square:
            square(configuration)
        }
    }

    private func square(_ configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            let track = theme.trayControl
            track
                .fill(configuration.isOn ? MultiplayerTheme.working : Color.clear)
                .overlay { track.strokeBorder(configuration.isOn ? MultiplayerTheme.working : MultiplayerTheme.secondary, lineWidth: 1.5) }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle()
                        .fill(configuration.isOn ? MultiplayerTheme.panel : MultiplayerTheme.secondary)
                        .frame(width: 10)
                        .padding(3.5)
                }
                .frame(width: 30, height: 18)
                .contentShape(Rectangle())
                .animation(theme.motion.animation(theme.motion.fast), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A person's picture in a circle, or their initial when they have none. People are round; agents
/// and resources are square (MultiplayerMark).
struct MultiplayerAvatar: View {
    /// PNG or JPEG bytes.
    let image: Data?
    let name: String
    var size: CGFloat = 22

    var body: some View {
        let shape = Circle()
        Group {
            if let picture = image.flatMap(NSImage.init(data:)) {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(name.multiplayerDisplay.prefix(1).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MultiplayerTheme.markFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.markEdge) }
        .accessibilityHidden(true)
    }
}

/// A server's colour chip.
struct MultiplayerSwatch: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 4, height: 12)
            .accessibilityHidden(true)
    }
}

/// The tray's control in the theme's button shape: outlined, the one primary action filled, a
/// destructive one in failure ink.
struct MultiplayerTrayButtonStyle: ButtonStyle {
    enum Role { case standard, primary, danger }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.theme) private var theme
    var role: Role = .standard
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = theme.controlShape
        configuration.label
            .font(theme.trayButtonType(large: large, primary: role == .primary))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, large ? 14 : 10)
            .frame(minHeight: large ? theme.space.controlHeightLarge : theme.space.controlHeight)
            .background(role == .primary ? MultiplayerTheme.primaryFill : MultiplayerTheme.controlFill, in: shape)
            .modifier(MultiplayerResponsive(isPressed: configuration.isPressed))
            .clipShape(shape)
            .overlay { shape.strokeBorder(edge) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(shape)
    }

    private var ink: Color {
        switch role {
        case .standard: MultiplayerTheme.controlInk
        case .primary: MultiplayerTheme.onAccent
        case .danger: MultiplayerTheme.failure
        }
    }

    private var edge: Color {
        switch role {
        case .standard: MultiplayerTheme.controlEdge
        case .primary: MultiplayerTheme.primaryEdge
        case .danger: MultiplayerTheme.failure
        }
    }
}

/// A small outlined note beside a name.
struct MultiplayerBadge: View {
    let text: String
    var symbol: String? = nil
    var tone: Tone = .neutral
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = theme.trayChip
        HStack(spacing: 3) {
            // The word carries the meaning. A tick symbol would otherwise be spoken as "Selected".
            if let symbol { Image(systemName: symbol).font(.system(size: 7.5, weight: .semibold)).accessibilityHidden(true) }
            Text(text).font(MultiplayerTheme.label)
        }
            .foregroundStyle(tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(tone.color))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 15)
            .background(tone == .neutral ? Color.clear : tone.color.opacity(0.12), in: shape)
            .overlay { shape.strokeBorder(tone == .neutral ? MultiplayerTheme.tagEdge : tone.color.opacity(0.45)) }
    }
}

extension Tone {
    /// The tone lamp (DESIGN.md): the lamp for a state the view knows only by its tone.
    var lamp: MultiplayerLamp.Kind {
        switch self {
        case .working: .on
        case .attention: .busy
        case .failure: .error
        case .focus: .unknown
        case .neutral: .off
        }
    }
}

/// A health-check step's mark: a round tick, a square cross, or the step's number before it runs.
struct MultiplayerStepMark: View {
    let number: Int
    /// Nil before the step has run.
    let passed: Bool?

    var body: some View {
        Group {
            switch passed {
            case true?:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MultiplayerTheme.panel)
                    .frame(width: 16, height: 16)
                    .background(MultiplayerTheme.working, in: Circle())
            case false?:
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MultiplayerTheme.panel)
                    .frame(width: 16, height: 16)
                    .background(MultiplayerTheme.failure, in: RoundedRectangle(cornerRadius: 3))
            case nil:
                Text("\(number)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.inkSecondary)
                    .frame(width: 16, height: 16)
                    .overlay { Circle().strokeBorder(MultiplayerTheme.border) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A certificate fingerprint in two lines the person can select and compare.
struct MultiplayerFingerprintText: View {
    let fingerprint: String

    var body: some View {
        Text(MultiplayerFingerprint.lines(fingerprint))
            .font(MultiplayerTheme.fingerprint)
            .foregroundStyle(MultiplayerTheme.foreground)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            // One static text. Selectable text is otherwise offered twice, once by the selection
            // view and once by the text inside it, and neither carries the label.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Fingerprint \(fingerprint.multiplayerDisplay.replacingOccurrences(of: ":", with: " "))")
    }
}

// MARK: - Molecules

/// A lamp with its word.
struct MultiplayerStateLabel: View {
    let lamp: MultiplayerLamp.Kind
    let text: String
    var tone: Tone = .neutral
    var pulses = false

    var body: some View {
        HStack(spacing: 5) {
            MultiplayerLamp(kind: lamp, pulses: pulses)
            Text(text)
                .font(MultiplayerTheme.state)
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(tone.color))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(text)
    }
}

/// One band of the tray: a padded region with a hairline under it.
struct MultiplayerBand<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, theme.space.sectionInset)
                .padding(.top, theme.space.bandTop)
                .padding(.bottom, theme.space.bandBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(MultiplayerTheme.hair).frame(height: theme.line.hairline)
        }
    }
}

/// A band's heading: its name, an optional count in full ink, and its one action.
struct MultiplayerBandHeading<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @Environment(\.theme) private var theme
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(MultiplayerTheme.heading)
                .foregroundStyle(.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(count)
                    .font(MultiplayerTheme.heading.monospacedDigit())
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .multiplayerTicking(count)
            }
            Spacer(minLength: Space.s)
            trailing
        }
        .frame(minHeight: theme.space.controlHeight)
    }
}

extension MultiplayerBandHeading where Trailing == EmptyView {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// One saved server: favorite star, colour, name and host, its state in a lamp and a word, and
/// Sign in while it is signed out. The name opens the server's page.
struct MultiplayerServerRow: View {
    let server: MultiplayerServerSummary
    let now: Date
    let isBusy: Bool
    /// This Mac hosts the relay.
    var hostedHere = false
    /// The person's request to join, once the relay turned their sign-in away. While it waits the
    /// row says so; once approved, Sign in is the row's primary action.
    var request: MultiplayerMembershipRequestStatus? = nil
    let onOpen: () -> Void
    let onFavorite: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: Space.s) {
            Button(action: onFavorite) {
                Image(systemName: server.favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(server.favorite ? MultiplayerTheme.attention : MultiplayerTheme.border)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(server.favorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(server.favorite ? "Remove \(server.displayName) from favorites" : "Add \(server.displayName) to favorites")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        MultiplayerSwatch(color: MultiplayerTheme.swatch(for: server.id))
                        Text(server.displayName)
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if hostedHere { MultiplayerBadge(text: "Hosted here") }
                        if server.unseen > 0 { MultiplayerBadge(text: "\(server.unseen) new", symbol: "circle.fill") }
                    }
                    Text(server.host)
                        .font(MultiplayerTheme.mono)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(server.displayName)")

            .accessibilityLabel("\(server.displayName), \(server.host)\(hostedHere ? ", hosted on this Mac" : "")\(server.unseen > 0 ? ", \(server.unseen) new in activity" : "")")
            .accessibilityHint("Opens this server’s settings, friends and sharing")

            if server.state == .signedOut, let request, !request.offersSignIn {
                // A request that waits on the admins: signing in again would only be refused again.
                MultiplayerStateLabel(lamp: request.lamp, text: request.phase == .sending ? "Sending…" : "Requested",
                                      tone: request.tone)
            } else if server.state == .signedOut {
                Button("Sign in", action: onSignIn)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: request?.phase == .approved ? .primary : .standard))
                    .disabled(isBusy)
                    .accessibilityLabel("Sign in to \(server.displayName)")
            } else {
                MultiplayerStateLabel(lamp: server.shownState.lamp, text: server.stateTitle(now: now), tone: server.shownState.tone,
                                      pulses: true)
            }
        }
        .frame(minHeight: 34)
          // The key this server is known by, as identity: pinned, changed, or left to macOS.
          HStack(spacing: 6) {
              MultiplayerHashChip(label: "Pin", hash: MultiplayerFingerprint.text(pin: server.pin) ?? "",
                                  trust: server.state == .certChanged ? .changed : server.pin.isEmpty ? .system : .pinned,
                                  onCopy: { MultiplayerHashChip.copy($0) })
              if !server.handle.isEmpty {
                  Text("as \(server.handle.multiplayerDisplay)")
                      .font(MultiplayerTheme.mono)
                      .foregroundStyle(.inkSecondary)
                      .lineLimit(1)
              }
          }
          .padding(.leading, 28)
        }
        .padding(.bottom, 6)
    }
}

/// The blocking notice under a server whose pinned certificate changed.
struct MultiplayerCertificateNotice: View {
    let serverName: String
    let onReview: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = theme.trayControl
        HStack(alignment: .center, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commander blocked this connection")
                    .font(MultiplayerTheme.heading)
                    .foregroundStyle(MultiplayerTheme.failure)
                Text("\(serverName) presented a certificate that doesn’t match the one you pinned.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review…", action: onReview)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .accessibilityLabel("Review the certificate for \(serverName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(MultiplayerTheme.failure.opacity(0.10), in: shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.failure) }
        .accessibilityElement(children: .contain)
    }
}

/// A friend on one server: presence lamp, picture, name, the other servers they're on, and Share.
struct MultiplayerFriendRow: View {
    let person: MultiplayerContactEntry
    let avatar: Data?
    let canShare: Bool
    let isBusy: Bool
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            MultiplayerLamp(kind: person.presence.lamp)
                .frame(width: 20)
            MultiplayerAvatar(image: avatar, name: person.title)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(person.title)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let badge = person.linkBadge {
                        MultiplayerBadge(text: badge, symbol: "link")
                    }
                }
                Text([person.handleCaption, person.caption].compactMap { $0 }.joined(separator: ", "))
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("Share", action: onShare)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isBusy || !canShare)
                .help(canShare ? "Share a resource with \(person.title)" : "Add a resource on this server first")
                .accessibilityLabel("Share with \(person.title)")
        }
        .frame(minHeight: 32)
    }
}

/// One line of the activity feed: when, on which server, and what happened.
struct MultiplayerActivityRow: View {
    let event: MultiplayerActivityEvent
    let serverName: String?
    let color: Color
    let isNew: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(Self.time(event.at, now: now))
                .font(MultiplayerTheme.mono)
                .foregroundStyle(.inkSecondary)
                .frame(width: 58, alignment: .leading)
            MultiplayerSwatch(color: color)
            Text(event.line(on: serverName))
                .font(.system(size: 12, weight: isNew ? .semibold : .regular))
                .foregroundStyle(MultiplayerTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isNew ? "New. " : "")\(Self.time(event.at, now: now)), \(event.line(on: serverName))")
    }

    /// The clock time today, the day and month before that.
    static func time(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(Date.FormatStyle().day().month(.abbreviated))
    }
}

/// Several lines of plain text in the tray's well, for a list the person edits.
struct MultiplayerTextArea: View {
    let label: String
    @Binding var text: String
    var lines = 3
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = theme.trayControl
        TextEditor(text: $text)
            .font(MultiplayerTheme.mono)
            .foregroundStyle(MultiplayerTheme.foreground)
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(height: CGFloat(lines) * 16 + 14)
            .background(MultiplayerTheme.fieldFill, in: shape)
            .overlay { shape.strokeBorder(MultiplayerTheme.fieldEdge) }
            .accessibilityLabel(label)
    }
}

/// Something waiting on the person: who, what, and the answer. A request that can be refused has
/// the refusal first and the answer after it as the primary button.
struct MultiplayerNeedRow: View {
    let color: Color
    let title: String
    let detail: String
    /// The refusing answer, such as Decline. Nil leaves the one answer.
    var declineTitle: String? = nil
    var onDecline: (() -> Void)? = nil
    let actionTitle: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerSwatch(color: color)
                .frame(width: 20)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let declineTitle, let onDecline {
                Button(declineTitle, action: onDecline)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .disabled(isBusy)
                    .accessibilityLabel("\(declineTitle): \(title)")
            }
            Button(actionTitle, action: action)
                .buttonStyle(MultiplayerTrayButtonStyle(role: onDecline == nil ? .standard : .primary))
                .disabled(isBusy)
                .accessibilityLabel("\(actionTitle): \(title)")
        }
        .frame(minHeight: 30)
    }
}

/// One step of the health check: its mark, its name and what the helper found.
struct MultiplayerProbeStepRow<Detail: View>: View {
    let number: Int
    let title: String
    /// Nil before the step has run.
    let passed: Bool?
    let detail: String?
    @ViewBuilder var extra: Detail

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerStepMark(number: number, passed: passed)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(passed == false ? MultiplayerTheme.failure
                                     : passed == nil ? MultiplayerTheme.secondary : MultiplayerTheme.foreground)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title): \(passed == true ? "passed" : passed == false ? "failed" : "not checked yet")")
    }
}

/// A labeled value, the label in secondary ink at a fixed measure.
struct MultiplayerSettingRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Space.m) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .frame(width: 128, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}

/// A sunken block for a value the person reads closely.
struct MultiplayerWell<Content: View>: View {
    var edge: Color? = nil
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        let shape = theme.trayControl
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MultiplayerTheme.fieldFill, in: shape)
            .overlay { if let edge { shape.strokeBorder(edge) } }
    }
}
