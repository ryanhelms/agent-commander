import SwiftUI

// ATOMIC LEVEL: Foundations, atoms and molecules (main-window shell).
// Everything the three navigation templates and the toolbar share. Each reads `\.theme`, takes
// values and emits one targeted action. Nothing here reads a model.
//
//   ShellLayout         sizes of the shell's regions (foundation)
//   ShellCount          a place's count; a hot count is filled in the attention role (atom)
//   ShellPlaceMark      a place's symbol, or a project's letter on a square mark (atom)
//   shellSelectable     selected fill, the leading focus marker and pointer feedback (atom)
//   ShellLoadNote       a lamp and one sentence in a hairline-topped row (molecule)
//   ShellPlaceRow       mark + title + count, as one button with its ⌘-number (molecule)
//   ShellGroupHeading   a group's name and count, with an optional fold control (molecule)
//   ShellModeCell       one square cell of the mode rail (molecule)
//   ShellReadoutStrip   toolbar readouts: label over figure, split by hairlines (molecule)
//   ShellPresenceMenu   the presence readout, which is also the control (molecule)
//   ShellSegments       a few options as joined cells (molecule)
//   ShellProfileRow     avatar, name and presence for a sidebar footer (molecule)
//   shellSidebarSurface the navigation surface: floating glass or a docked well (atom)

// MARK: - Foundations

/// Sizes of the shell's regions and marks.
enum ShellLayout {
    /// A list sidebar (templates A and C).
    static let sidebarWidth: CGFloat = 224
    /// The mode rail of template B.
    static let railWidth: CGFloat = 48
    /// One square cell of the mode rail.
    static let railCell: CGFloat = 32
    /// A mode's icon inside its cell.
    static let railIcon: CGFloat = 18
    /// The context list beside the mode rail.
    static let contextWidth: CGFloat = 196
    /// The frame of a place's symbol or letter mark.
    static let placeMark: CGFloat = 18
    /// Space between a floating navigation surface's edge and its rows.
    static let floatingInset = Space.m
    /// The same for a docked surface.
    static let dockedInset = Space.s
    /// The count on the corner of a mode cell.
    static let cornerCount: CGFloat = 14
    /// Room the window's close, minimise and zoom buttons take on a drawn toolbar band.
    static let windowControls: CGFloat = 78
}

extension Theme {
    /// The navigation floats as a glass sheet over the window. Otherwise it is docked: a well
    /// against the window's leading edge, split from the canvas by a hairline.
    var navigationFloats: Bool { material.window == .glass }

    /// The outline of a row or cell that can be selected.
    var rowShape: RoundedRectangle { RoundedRectangle(cornerRadius: radius.control, style: .continuous) }
}

// MARK: - Atoms

/// A place's count. A hot count is filled in the attention role with `onAccent` ink.
struct ShellCount: View {
    @Environment(\.theme) private var theme
    let text: String
    var isHot = false
    /// The small form sits on the corner of a mode cell.
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.chip, style: .continuous)
        let height = compact ? ShellLayout.cornerCount : theme.space.chipHeightMin
        Text(text)
            .themeType(compact ? theme.type.fingerprint : theme.type.label)
            .monospacedDigit()
            .foregroundStyle(.theme(isHot ? \.surface.highlightInk : \.color.foreground))
            .lineLimit(1)
            .padding(.horizontal, compact ? 3 : Space.xs + 1)
            .frame(minWidth: height, minHeight: height)
            .background((isHot ? theme.surface.highlightFill : theme.color.hair).color, in: shape)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A place's mark: its symbol, or a project's letter on a square mark. Projects and resources are
/// square; people are round.
struct ShellPlaceMark: View {
    @Environment(\.theme) private var theme
    let mark: CommanderPlace.Mark
    var isSelected = false

    var body: some View {
        Group {
            switch mark {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: theme.type.body.size, weight: .regular))
                    .foregroundStyle(.theme(isSelected ? \.color.foreground : \.color.secondary))
            case .letter(let letter):
                let shape = RoundedRectangle(cornerRadius: theme.radius.chip, style: .continuous)
                Text(letter)
                    .themeType(theme.type.fingerprint)
                    .foregroundStyle(.theme(\.color.focus))
                    .frame(width: ShellLayout.placeMark, height: ShellLayout.placeMark)
                    .background(theme.surface.markFill.color, in: shape)
                    .overlay { shape.strokeBorder(.theme(\.surface.markEdge)) }
            }
        }
        .frame(width: ShellLayout.placeMark, height: ShellLayout.placeMark)
        .accessibilityHidden(true)
    }
}

/// Selection and pointer feedback for a row or cell. The selected one takes the selected fill and,
/// where the theme has a selection marker, a `focus` leading edge; otherwise the selected outline.
struct ShellSelectable: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let isSelected: Bool
    var isPressed = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = theme.rowShape
        content
            .background {
                if isSelected {
                    shape.fill(theme.surface.selectedFill.style)
                } else if isEnabled, hovering || isPressed {
                    shape.fill(theme.surface.hitFill.color)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected, theme.line.selectedMarker > 0 {
                    Rectangle().fill(.theme(\.color.focus)).frame(width: theme.line.selectedMarker)
                }
            }
            .clipShape(shape)
            .overlay {
                if isSelected, theme.line.selectedMarker == 0 {
                    shape.strokeBorder(.theme(\.surface.selectedEdge), lineWidth: theme.line.hairline)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(theme.motion.animation(theme.motion.fast), value: hovering)
            .animation(theme.motion.animation(theme.motion.fast), value: isSelected)
    }
}

/// A plain button that takes the shell's selection and pointer feedback.
struct ShellRowButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ShellSelectable(isSelected: isSelected, isPressed: configuration.isPressed))
    }
}

/// The surface the navigation sits on: a floating glass sheet, or a well docked to the window's
/// leading edge with a hairline against the canvas.
struct ShellSidebarSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if theme.navigationFloats {
            content
                .glassSurface(.navigation, radius: Radius.sidebar)
                .padding(.leading, Metric.navigationLeading)
                .padding(.trailing, Metric.navigationTrailing)
                .padding(.bottom, Metric.navigationBottom)
        } else {
            content
                .background(theme.color.well.color)
                .overlay(alignment: .trailing) { ThemeRule(vertical: true) }
        }
    }
}

extension View {
    func shellSidebarSurface() -> some View { modifier(ShellSidebarSurface()) }
}

// MARK: - Molecules

/// A lamp and one sentence in a hairline-topped row: what is being read, why it couldn't be, or
/// that there is nothing. `working` is the lit lamp of "Nothing is waiting for you".
struct ShellLoadNote: View {
    @Environment(\.theme) private var theme
    let text: String
    var lamp: MultiplayerLamp.Kind = .off

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemeRule()
            HStack(spacing: Space.s) {
                MultiplayerLamp(kind: lamp)
                Text(text).themeType(theme.type.body).foregroundStyle(.theme(\.color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, theme.space.bandTop)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(text)
    }
}

/// One place as a row: its mark, its title and its count. Choosing it emits the place's ID.
struct ShellPlaceRow: View {
    @Environment(\.theme) private var theme
    let item: CommanderNavigation.Item
    let select: (String) -> Void
    /// Offered in the row's context menu when the place can be shared.
    var share: ((String) -> Void)? = nil

    var body: some View {
        Button { select(item.place.id) } label: {
            HStack(spacing: Space.s + 1) {
                ShellPlaceMark(mark: item.place.mark, isSelected: item.isSelected)
                Text(item.place.title)
                    .themeType(theme.type.body)
                    .foregroundStyle(.theme(item.isSelected ? \.color.foreground : \.surface.softInk))
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                if let badge = item.place.badge {
                    ShellCount(text: badge, isHot: item.place.isHot)
                }
            }
            .padding(.horizontal, Space.s + 1)
            .frame(maxWidth: .infinity, minHeight: theme.space.rowIcon, alignment: .leading)
        }
        .buttonStyle(ShellRowButtonStyle(isSelected: item.isSelected))
        .shellShortcut(item.shortcut)
        .help(item.shortcut.map { "\(item.place.title) (⌘\($0))" } ?? item.place.title)
        .accessibilityLabel(item.place.spoken)
        .accessibilityValue(item.isSelected ? "Selected" : "")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityIdentifier("shell-place-\(item.place.id)")
        .contextMenu {
            if item.place.canShare, let share { Button("Share…") { share(item.place.id) } }
        }
    }
}

extension View {
    /// ⌘ and the number, when the place or mode has one. A window that keeps ⌘-numbers for
    /// something else passes other modifiers.
    @ViewBuilder func shellShortcut(_ number: Int?, modifiers: EventModifiers = .command) -> some View {
        if let number, let key = "\(number)".first {
            keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else {
            self
        }
    }
}

extension EventModifiers {
    /// The modifiers as a key cap reads them, in the system's order: "⌥⌘".
    var shellKeyCap: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A group's heading: its name in secondary ink, a count in full ink, and a fold control when the
/// group can be folded.
struct ShellGroupHeading: View {
    @Environment(\.theme) private var theme
    let title: String
    /// Shown beside the name: the hot counts of a folded group.
    var count = 0
    /// Nil when the group can't be folded.
    var isCollapsed: Bool? = nil
    var toggle: () -> Void = {}

    var body: some View {
        if let isCollapsed {
            Button(action: toggle) { label(chevron: isCollapsed ? "chevron.right" : "chevron.down") }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(isCollapsed ? "Shows this group's places" : "Hides this group's places")
                .accessibilityAddTraits(.isHeader)
        } else {
            label(chevron: nil).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        }
    }

    private func label(chevron: String?) -> some View {
        HStack(spacing: Space.xs + 2) {
            ThemeHeading(text: title)
            if count > 0 { ShellCount(text: "\(count)", isHot: true) }
            Spacer(minLength: 0)
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: theme.type.label.size - 1, weight: .semibold))
                    .foregroundStyle(.theme(\.color.secondary))
            }
        }
        .padding(.horizontal, Space.s + 1)
        .frame(minHeight: theme.space.chipHeightMax)
        .contentShape(Rectangle())
    }
}

/// One square cell of the mode rail: the mode's icon, with its hot count on the corner.
struct ShellModeCell: View {
    @Environment(\.theme) private var theme
    let item: CommanderNavigation.ModeItem
    /// The keys held with the mode's number.
    var modifiers: EventModifiers = .command
    let select: (String) -> Void

    var body: some View {
        Button { select(item.mode.id) } label: {
            Image(systemName: item.mode.symbol)
                .font(.system(size: ShellLayout.railIcon - 3, weight: .regular))
                .foregroundStyle(.theme(item.isSelected ? \.color.foreground : \.color.secondary))
                .frame(width: ShellLayout.railIcon, height: ShellLayout.railIcon)
                .frame(width: ShellLayout.railCell, height: ShellLayout.railCell)
        }
        .buttonStyle(ShellRowButtonStyle(isSelected: item.isSelected))
        .overlay(alignment: .topTrailing) {
            if item.hotCount > 0 {
                ShellCount(text: "\(min(item.hotCount, 99))", isHot: true, compact: true)
                    .offset(x: Space.xs + 1, y: -Space.xs)
                    .allowsHitTesting(false)
            }
        }
        .shellShortcut(item.shortcut, modifiers: modifiers)
        .help(item.shortcut.map { "\(item.mode.title) (\(modifiers.shellKeyCap)\($0))" } ?? item.mode.title)
        .accessibilityLabel(item.hotCount > 0 ? "\(item.mode.title), \(item.hotCount) waiting" : item.mode.title)
        .accessibilityValue(item.isSelected ? "Selected" : "")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityIdentifier("shell-mode-\(item.mode.id)")
    }
}

/// One figure of a readout strip: a small label over a value, with an optional lamp.
struct ShellReadout: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    var lamp: MultiplayerLamp.Kind? = nil
    var tone: Tone = .neutral
    /// What VoiceOver says for the whole cell.
    var spoken: String? = nil
}

/// The label-over-figure cell that a readout and the presence menu share.
struct ShellReadoutCell: View {
    @Environment(\.theme) private var theme
    let readout: ShellReadout
    /// The readout opens a menu: a chevron sits beside its label.
    var opensMenu = false
    /// A strip under a page header shows its figures in `figure`; a toolbar shows them in `data`.
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(readout.label).themeType(theme.type.label).textCase(nil)
                if opensMenu {
                    Image(systemName: "chevron.down").font(.system(size: theme.type.label.size * 0.7, weight: .bold))
                }
            }
            .foregroundStyle(.theme(\.color.secondary))
            .lineLimit(1)
            HStack(spacing: Space.xs + 1) {
                if let lamp = readout.lamp { MultiplayerLamp(kind: lamp, size: 8) }
                Text(readout.value)
                    .themeType(large ? theme.type.figure : theme.type.data)
                    .monospacedDigit()
                    .foregroundStyle(.theme(readout.tone == .neutral ? \.color.foreground : readout.tone.role))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(theme.motion.animation(theme.motion.standard), value: readout.value)
            }
        }
        .padding(.horizontal, Space.m - 2)
        .padding(.vertical, large ? Space.s - 1 : Space.xs)
        .frame(maxWidth: large ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A row of readouts on the well, split by hairlines, in the status-strip style. A readout with an
/// action is a button; `trailing` holds a control that is itself a readout (the presence menu).
struct ShellReadoutStrip<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let cells: [ShellReadout]
    /// The strip under a page header fills the width; the toolbar's hugs its content.
    var large = false
    /// Called with a readout's ID when it is pressed. Nil leaves the readouts as text.
    var open: ((String) -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if index > 0 { ThemeRule(vertical: true) }
                if let open {
                    Button { open(cell.id) } label: { ShellReadoutCell(readout: cell, large: large) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cell.spoken ?? "\(cell.label), \(cell.value)")
                        .accessibilityIdentifier("shell-readout-\(cell.id)")
                } else {
                    ShellReadoutCell(readout: cell, large: large)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(cell.spoken ?? "\(cell.label), \(cell.value)")
                }
            }
            if Trailing.self != EmptyView.self {
                if !cells.isEmpty { ThemeRule(vertical: true) }
                trailing
            }
        }
        .fixedSize(horizontal: !large, vertical: true)
        .background(theme.color.well.color, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline) }
    }
}

extension ShellReadoutStrip where Trailing == EmptyView {
    init(cells: [ShellReadout], large: Bool = false, open: ((String) -> Void)? = nil) {
        self.init(cells: cells, large: large, open: open) { EmptyView() }
    }
}

/// The presence readout, which is also the control: the presence the servers show now, and the
/// five choices in a native menu.
struct ShellPresenceMenu: View {
    let profile: CommanderProfile
    let pick: (MultiplayerPresenceChoice) -> Void

    var body: some View {
        Menu {
            ForEach(MultiplayerPresenceChoice.allCases) { option in
                Button { pick(option) } label: {
                    if option == profile.choice {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            ShellReadoutCell(readout: ShellReadout(id: "presence", label: "presence", value: profile.presenceTitle,
                                                   lamp: profile.presence?.lamp ?? .off),
                             opensMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the presence your friends see")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your presence")
        .accessibilityValue(profile.presenceTitle)
        .accessibilityHint("Opens a list to choose from")
        .accessibilityIdentifier("shell-presence")
    }
}

/// The toolbar's readouts: server health, then presence when the sidebar doesn't hold it.
struct ShellToolbarReadouts: View {
    let servers: CommanderServerHealth
    /// Nil where the profile and presence sit in the sidebar footer.
    let profile: CommanderProfile?
    let openServers: () -> Void
    let pickPresence: (MultiplayerPresenceChoice) -> Void

    private var lamp: MultiplayerLamp.Kind {
        switch servers.tone {
        case .working: .on
        case .attention: .busy
        case .failure: .error
        default: .off
        }
    }

    var body: some View {
        let cell = ShellReadout(id: "servers", label: "servers", value: servers.figure, lamp: lamp,
                                tone: servers.tone == .working ? .neutral : servers.tone,
                                spoken: "servers, \(servers.spoken)")
        ShellReadoutStrip(cells: [cell], open: { _ in openServers() }) {
            if let profile { ShellPresenceMenu(profile: profile, pick: pickPresence) }
        }
        .help("Servers: \(servers.spoken)")
    }
}

/// A few options as joined cells on one hairline frame. The chosen cell is filled `focus`.
struct ShellSegments<Option: Hashable>: View {
    @Environment(\.theme) private var theme
    let options: [(value: Option, title: String, help: String)]
    let selection: Option
    let choose: (Option) -> Void

    var body: some View {
        let shape = theme.controlShape
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isOn = option.value == selection
                if index > 0 { ThemeRule(vertical: true) }
                Button { choose(option.value) } label: {
                    Text(option.title)
                        .themeType(theme.pageType.control)
                        .foregroundStyle(.theme(isOn ? \.color.onAccent : \.surface.controlInk))
                        .lineLimit(1)
                        .padding(.horizontal, Space.m - 2)
                        .frame(minHeight: theme.space.controlHeight)
                        .background {
                            if isOn { Rectangle().fill(theme.surface.primaryFill.style) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityValue(isOn ? "Selected" : "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .fixedSize()
        .clipShape(shape)
        .overlay { shape.strokeBorder(.theme(\.surface.controlEdge), lineWidth: theme.line.hairline) }
        .animation(theme.motion.animation(theme.motion.fast), value: selection)
    }
}

/// The person at this Mac, for a sidebar footer: a round avatar, the name, and the presence as a
/// lamp and a word that opens the presence choices.
struct ShellProfileRow: View {
    @Environment(\.theme) private var theme
    let profile: CommanderProfile
    let pick: (MultiplayerPresenceChoice) -> Void

    var body: some View {
        Menu {
            ForEach(MultiplayerPresenceChoice.allCases) { option in
                Button { pick(option) } label: {
                    if option == profile.choice {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Space.s + 1) {
                MultiplayerAvatar(image: nil, name: profile.name, size: theme.space.rowIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                    HStack(spacing: Space.xs + 1) {
                        MultiplayerLamp(kind: profile.presence?.lamp ?? .off, size: 8)
                        Text(profile.presenceTitle).themeType(theme.type.state).foregroundStyle(.theme(\.color.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: theme.type.label.size - 1, weight: .semibold))
                    .foregroundStyle(.theme(\.color.secondary))
            }
            .padding(.horizontal, Space.s + 1)
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose the presence your friends see")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.name), your presence")
        .accessibilityValue(profile.presenceTitle)
        .accessibilityHint("Opens a list to choose from")
        .accessibilityIdentifier("shell-profile")
    }
}

/// The sidebar's own heading: the app, and where its service runs.
struct ShellBrandHeader: View {
    @Environment(\.theme) private var theme
    var title = "Commander"
    var state = "Local service"

    var body: some View {
        HStack(spacing: Space.m - 1) {
            if theme.navigationFloats { BrandMark() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                ThemeStatus(text: state, tone: .working)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
