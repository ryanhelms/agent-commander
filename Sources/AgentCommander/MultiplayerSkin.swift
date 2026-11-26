import AppKit
import SwiftUI

// ATOMIC LEVEL: Atoms and molecules of the tray's own skin.
// Direction: an operations console for an agent network. Hard lines, hairline grids, corners of
// two points or less, monospace for anything that is data, a lamp and a word for every state.
// Identity is shown as it is verified: pins and fingerprints as hash chips with copy. Agents are
// square, people are round. Every colour, radius and face comes from `MultiplayerTheme`, so a
// later skin redefines that one enum.
// No stock macOS control is drawn here. Each control is a Button, Menu, Toggle or text field
// underneath, so keyboard focus, the focus ring, VoiceOver and the menu bar panel behave natively.
//   Atoms:      MultiplayerSpinner, MultiplayerMark, MultiplayerMeter, MultiplayerFieldBox
//   Molecules:  MultiplayerSegments, MultiplayerMenuField, MultiplayerHashChip, MultiplayerAgentChip,
//               MultiplayerStatusStrip, MultiplayerTabBar, MultiplayerReadout

// MARK: - Atoms

/// Work in progress: an arc that turns, or stands still when motion is reduced.
struct MultiplayerSpinner: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0.08, to: 0.7)
                .stroke(MultiplayerTheme.focus, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("In progress")
    }
}

/// The square mark of a thing that isn't a person: an agent, a repository, a state.
struct MultiplayerMark: View {
    let symbol: String
    var tone: Tone = .neutral
    var size: CGFloat = MultiplayerLayout.rowIcon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.chipRadius)
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(tone.color))
            .frame(width: size, height: size)
            .background(MultiplayerTheme.well, in: shape)
            .overlay { shape.strokeBorder(tone == .neutral ? MultiplayerTheme.border : tone.color.opacity(0.55)) }
            .accessibilityHidden(true)
    }
}

/// How much of a limit is used: a segmented bar, with the figures beside it said in words.
struct MultiplayerMeter: View {
    let used: Int
    let limit: Int
    var cells = 16
    /// The bar counts something wanted, such as accepted results: it stays `working` when full.
    var isGood = false

    private var fraction: Double { limit > 0 ? min(Double(used) / Double(limit), 1) : 0 }

    var body: some View {
        let lit = Int((fraction * Double(cells)).rounded(.up))
        let color = isGood ? MultiplayerTheme.working : fraction >= 1 ? MultiplayerTheme.failure : fraction >= 0.8 ? MultiplayerTheme.attention : MultiplayerTheme.working
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { index in
                Rectangle()
                    .fill(index < lit ? color : MultiplayerTheme.hair)
                    .frame(width: 5, height: 9)
            }
        }
        .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.slow), value: lit)
        .accessibilityElement()
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent\(isGood ? "" : " used")")
    }
}

/// The tray's field: a sunken box with a hard edge that takes the focus colour.
struct MultiplayerFieldBox: ViewModifier {
    var focused = false
    var height: CGFloat? = MultiplayerLayout.fieldHeight

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.controlRadius)
        content
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(MultiplayerTheme.well, in: shape)
            .overlay { shape.strokeBorder(focused ? MultiplayerTheme.focus : MultiplayerTheme.border, lineWidth: focused ? 1.5 : 1) }
    }
}

extension View {
    func multiplayerFieldBox(focused: Bool = false, height: CGFloat? = MultiplayerLayout.fieldHeight) -> some View {
        modifier(MultiplayerFieldBox(focused: focused, height: height))
    }
}

// MARK: - Molecules

/// A few named options, one chosen: joined cells on one hairline frame.
struct MultiplayerSegments<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.controlRadius)
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isOn = option == selection
                if index > 0 { Rectangle().fill(MultiplayerTheme.border).frame(width: 1) }
                Button { selection = option } label: {
                    Text(title(option))
                        .font(MultiplayerTheme.data)
                        .foregroundStyle(isOn ? MultiplayerTheme.onAccent : MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(isOn ? MultiplayerTheme.focus : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MultiplayerRowButtonStyle())
                .accessibilityLabel(title(option))
                .accessibilityValue(isOn ? "Selected" : "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.border) }
        .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// One value chosen from a list: a field that opens a menu.
struct MultiplayerMenuField<Option: Hashable>: View {
    let label: String
    let placeholder: String
    let options: [(value: Option, title: String)]
    @Binding var selection: Option
    var isEnabled = true

    var body: some View {
        let current = options.first { $0.value == selection }?.title
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: Space.s) {
                Text(current ?? placeholder)
                    .font(MultiplayerTheme.name)
                    .foregroundStyle(current == nil ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(MultiplayerTheme.foreground))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
            .multiplayerFieldBox()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!isEnabled || options.isEmpty)
        .opacity(isEnabled && !options.isEmpty ? 1 : 0.5)
        // The menu and its drawn label would otherwise each be offered as a menu button.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(current ?? placeholder)
        .accessibilityHint("Opens a list to choose from")
    }
}

/// A key as identity: what it is, the hash cut short, whether it is pinned, and a way to copy it.
struct MultiplayerHashChip: View {
    enum Trust: Equatable {
        case pinned, system, changed, plain

        var title: String? {
            switch self {
            case .pinned: "Pinned"
            case .system: "System trust"
            case .changed: "Changed"
            case .plain: nil
            }
        }

        var symbol: String {
            switch self {
            case .pinned: "pin.fill"
            case .system: "checkmark.shield"
            case .changed: "exclamationmark.triangle.fill"
            case .plain: "number"
            }
        }

        var color: Color {
            switch self {
            case .pinned, .system: MultiplayerTheme.working
            case .changed: MultiplayerTheme.failure
            case .plain: Palette.secondary
            }
        }
    }

    let label: String
    /// The full value: a colon-separated fingerprint or any other hash. Empty shows the trust alone.
    let hash: String
    var trust: Trust = .plain
    var onCopy: ((String) -> Void)? = nil
    @State private var copied = false

    /// "9E:D9:9C…C6:55:BF": the head and the tail, which is what people compare first.
    static func short(_ hash: String) -> String {
        let parts = hash.split(separator: ":")
        if parts.count > 6 { return parts.prefix(3).joined(separator: ":") + "…" + parts.suffix(3).joined(separator: ":") }
        return hash.count > 18 ? "\(hash.prefix(8))…\(hash.suffix(6))" : hash
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.chipRadius)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: trust.symbol).font(.system(size: 8.5, weight: .semibold))
                Text(trust.title ?? label).font(MultiplayerTheme.label)
            }
            .foregroundStyle(trust.color)
            .padding(.horizontal, 5)
            .frame(maxHeight: .infinity)
            .background(trust.color.opacity(0.12))
            if !hash.isEmpty {
                Rectangle().fill(trust.color.opacity(0.45)).frame(width: 1)
                Text(Self.short(hash))
                    .font(MultiplayerTheme.fingerprint)
                    .foregroundStyle(MultiplayerTheme.foreground)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                if let onCopy {
                    Rectangle().fill(MultiplayerTheme.border).frame(width: 1)
                    Button {
                        onCopy(hash)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(copied ? MultiplayerTheme.working : Palette.secondary)
                            .frame(width: 20)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy the full \(label.lowercased())")
                    .accessibilityLabel("Copy the full \(label.lowercased())")
                }
            }
        }
        .frame(height: 18)
        .fixedSize()
        .clipShape(shape)
        .overlay { shape.strokeBorder(trust.color.opacity(0.45)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hash.isEmpty ? (trust.title ?? label) : "\(label), \(trust.title ?? "not pinned"), \(Self.short(hash))")
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// What runs an agent: its harness and model, and how many it can run at once.
struct MultiplayerAgentChip: View {
    let capabilities: MultiplayerCapabilities

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MultiplayerTheme.chipRadius)
        let parts = [capabilities.harness.isEmpty ? nil : MultiplayerCapabilities.harnessTitle(capabilities.harness),
                     capabilities.model.isEmpty ? nil : capabilities.model.multiplayerDisplay].compactMap { $0 }
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Rectangle().fill(MultiplayerTheme.border).frame(width: 1) }
                Text(part)
                    .font(MultiplayerTheme.label)
                    .foregroundStyle(index == 0 ? MultiplayerTheme.focus : MultiplayerTheme.foreground)
                    .padding(.horizontal, 5)
                    .frame(maxHeight: .infinity)
                    .background(index == 0 ? MultiplayerTheme.selection : Color.clear)
            }
            if let slots = capabilities.slots {
                Rectangle().fill(MultiplayerTheme.border).frame(width: 1)
                Text("×\(slots)")
                    .font(MultiplayerTheme.label)
                    .foregroundStyle(.inkSecondary)
                    .padding(.horizontal, 5)
            }
        }
        .frame(height: 16)
        .fixedSize()
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.border) }
        .accessibilityElement()
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(capabilities.headline ?? "Agent")
    }
}

/// One figure of the status strip or of a readout: a small label over a value.
struct MultiplayerReadout: Identifiable {
    let id: String
    let label: String
    let value: String
    var lamp: MultiplayerLamp.Kind? = nil
    var tone: Tone = .neutral
    /// What VoiceOver says for the whole cell.
    var spoken: String? = nil
}

/// The tray's telemetry line: a hairline grid of readouts that stays above the tabs.
struct MultiplayerStatusStrip<Trailing: View>: View {
    let cells: [MultiplayerReadout]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(width: 1) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.label)
                        .font(MultiplayerTheme.label)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let lamp = cell.lamp { MultiplayerLamp(kind: lamp, size: 8, pulses: true) }
                        Text(cell.value)
                            .font(MultiplayerTheme.figure)
                            .foregroundStyle(cell.tone == .neutral ? MultiplayerTheme.foreground : cell.tone.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multiplayerTicking(cell.value)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(cell.spoken ?? "\(cell.label), \(cell.value)")
            }
            trailing
        }
        .background(MultiplayerTheme.well)
        .overlay(alignment: .bottom) { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
    }
}

extension MultiplayerStatusStrip where Trailing == EmptyView {
    init(cells: [MultiplayerReadout]) {
        self.init(cells: cells) { EmptyView() }
    }
}

/// The tray's three places. The chosen tab carries the focus colour on its lower edge.
struct MultiplayerTabBar: View {
    struct Tab: Identifiable {
        let id: MultiplayerTrayTab
        var count = 0
        var isHot = false
    }

    let tabs: [Tab]
    @Binding var selection: MultiplayerTrayTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let isOn = tab.id == selection
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(width: 1) }
                Button { selection = tab.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.id.symbol).font(.system(size: 11, weight: .medium))
                        Text(tab.id.title).font(MultiplayerTheme.heading)
                        if tab.count > 0 {
                            Text("\(tab.count)")
                                .multiplayerTicking(tab.count)
                                .font(MultiplayerTheme.label)
                                .foregroundStyle(tab.isHot ? MultiplayerTheme.onAccent : MultiplayerTheme.foreground)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 14)
                                .background(tab.isHot ? MultiplayerTheme.attention : MultiplayerTheme.hair,
                                            in: RoundedRectangle(cornerRadius: MultiplayerTheme.chipRadius))
                        }
                    }
                    .foregroundStyle(isOn ? MultiplayerTheme.foreground : Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(isOn ? MultiplayerTheme.panel : MultiplayerTheme.well)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(isOn ? MultiplayerTheme.focus : MultiplayerTheme.hair).frame(height: isOn ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MultiplayerRowButtonStyle())
                .keyboardShortcut(tab.id.shortcut, modifiers: .command)
                .help("\(tab.id.title) (⌘\(String(tab.id.shortcut.character)))")
                .accessibilityLabel(tab.count > 0 ? "\(tab.id.title), \(tab.count) \(tab.id.countNoun)" : tab.id.title)
                .accessibilityValue(isOn ? "Selected" : "")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                .accessibilityHint("Tab \(index + 1) of \(tabs.count)")
            }
        }
        .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
        .accessibilityAddTraits(.isTabBar)
    }
}

/// The tray's three primary places.
enum MultiplayerTrayTab: String, CaseIterable, Identifiable, Sendable {
    case agents, network, people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .network: "Network"
        case .people: "People"
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .network: "point.3.connected.trianglepath.dotted"
        case .people: "person.2"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .agents: "1"
        case .network: "2"
        case .people: "3"
        }
    }

    /// What the tab's count counts, for VoiceOver.
    var countNoun: String {
        switch self {
        case .agents: "waiting on you"
        case .network: "need attention"
        case .people: "new"
        }
    }
}

// MARK: - Motion

/// The tray's motion tokens: short, eased out, never a bounce. With Reduce Motion on, movement
/// becomes a fade or nothing.
extension MultiplayerTheme {
    enum Motion {
        private static let motion = Theme.console.motion

        /// Hover and press feedback.
        static let fast = motion.fast
        /// A row arriving or leaving, a tab changing, a count ticking.
        static let standard = motion.standard
        /// A meter filling.
        static let slow = motion.slow
        /// One beat of a live lamp.
        static let pulse = motion.pulse
        /// How far an arriving row travels.
        static let travel = motion.travel

        static func ease(_ duration: Double = standard) -> Animation { motion.animation(duration) }
    }
}

/// A row that arrives by sliding in under a fade and leaves by fading: an approval answered, a
/// trace line streaming in. With Reduce Motion it only fades.
struct MultiplayerArriving: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion
            ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: -MultiplayerTheme.Motion.travel)),
                          removal: .opacity.combined(with: .offset(x: MultiplayerTheme.Motion.travel))))
    }
}

/// Animates a list as its rows come and go, at the tray's standard pace.
struct MultiplayerStreaming<Value: Equatable>: ViewModifier {
    let value: Value

    func body(content: Content) -> some View {
        content.animation(MultiplayerTheme.Motion.ease(), value: value)
    }
}

/// A figure that ticks to its new value instead of jumping.
struct MultiplayerTicking<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(MultiplayerTheme.Motion.ease(), value: value)
    }
}

/// Hover and press feedback for a custom control: a tint under the pointer, a dip when pressed.
struct MultiplayerResponsive: ViewModifier {
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(MultiplayerTheme.foreground.opacity(!isEnabled ? 0 : isPressed ? 0.10 : hovering ? 0.06 : 0))
            .onHover { hovering = $0 }
            .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: hovering)
            .animation(MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: isPressed)
    }
}

/// A plain button that still answers the pointer: for rows, tabs and cells that are buttons.
struct MultiplayerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MultiplayerResponsive(isPressed: configuration.isPressed))
    }
}

/// A live lamp's beat: a ring that swells and fades around it. Still with Reduce Motion.
struct MultiplayerPulse: ViewModifier {
    let isLive: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    func body(content: Content) -> some View {
        content
            .background {
                if isLive, !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 1)
                        .scaleEffect(beat ? 2.1 : 1)
                        .opacity(beat ? 0 : 0.7)
                        .onAppear {
                            withAnimation(.easeOut(duration: MultiplayerTheme.Motion.pulse).repeatForever(autoreverses: false)) { beat = true }
                        }
                }
            }
    }
}

extension View {
    func multiplayerArriving() -> some View { modifier(MultiplayerArriving()) }
    func multiplayerStreaming<Value: Equatable>(_ value: Value) -> some View { modifier(MultiplayerStreaming(value: value)) }
    func multiplayerTicking<Value: Equatable>(_ value: Value) -> some View { modifier(MultiplayerTicking(value: value)) }
}
