import SwiftUI

// ATOMIC LEVEL: Molecules.
// Each molecule combines atoms for one understandable interaction and keeps its target, disabled
// reason and accessible value as its rendering changes. The same molecule serves the wall, the
// focused worker and the PiP; none of them has a private copy.

// MARK: - WorkerIdentity

/// Who a worker is: client mark, name and a line of attribution. Used by the wall tile, the focused
/// worker, the coordinator console and the PiP.
struct WorkerIdentity: View {
    enum Density { case tile, console, focused, pip }

    struct Detail {
        var symbol: String? = nil
        let text: String
    }

    let name: String
    let client: AgentClient
    var details: [Detail] = []
    var density: Density = .tile

    private var avatarSize: CGFloat { density == .console || density == .focused ? 37 : 30 }

    private var nameFont: Font {
        switch density {
        case .tile, .pip: TypeRole.tileName
        case .console: TypeRole.consoleName
        case .focused: TypeRole.focusTitle
        }
    }

    private var detailFont: Font { density == .tile ? TypeRole.provider : TypeRole.meta }

    var body: some View {
        HStack(spacing: density == .tile ? 8 : 11) {
            AgentAvatar(client: client, size: avatarSize)
            VStack(alignment: .leading, spacing: density == .tile ? 2 : 3) {
                Text(name).font(nameFont).tracking(density == .focused ? -0.5 : -0.2)
                    .foregroundStyle(Palette.foreground).lineLimit(1).truncationMode(.tail)
                if !details.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                            if index > 0 { Text("·").foregroundStyle(.inkSecondary).opacity(0.6) }
                            if let symbol = detail.symbol { Image(systemName: symbol).font(.system(size: 9)) }
                            Text(detail.text).lineLimit(1)
                        }
                    }
                    .font(detailFont)
                    .foregroundStyle(.inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([name, client.displayName] + details.map(\.text)).joined(separator: ", "))
    }
}

/// Host and branch (or worktree) of a worker in the tile's metadata row.
struct WorkerLocation: View {
    let host: String
    let location: String
    let isBranch: Bool

    var body: some View {
        HStack(spacing: 10) {
            MetaItem(symbol: "desktopcomputer", text: host, help: "Host \(host)")
            if !location.isEmpty {
                MetaItem(symbol: isBranch ? "arrow.triangle.branch" : "folder", text: location,
                         help: (isBranch ? "Branch " : "Worktree ") + location)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - InputOwnership

/// Names who holds terminal input for a worker. While observing it reads "Input · holder". When the
/// developer holds input it reads "You have input" and offers a real Hand back button, shown only
/// when a hand-back action exists. Keyboard focus is a separate cue on the trailing edge.
struct InputOwnership: View {
    let workerName: String
    let control: InputControl
    var isKeyFocused = false
    var handBack: (() -> Void)? = nil

    private var held: Bool { control == .held }

    private var title: String {
        switch control {
        case .observing(let holder): "Input · \(holder)"
        case .held: "You have input"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: held ? "hand.raised" : "eye").font(.system(size: 10, weight: .medium))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(held ? Palette.heldText : Palette.ownerText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(held ? Palette.heldFill : Palette.ownerFill, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(held ? Palette.heldEdge : Palette.ownerEdge) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)

            if held, let handBack {
                Button("Hand back", action: handBack)
                    .buttonStyle(HandbackButtonStyle())
                    .accessibilityLabel("Hand back input for \(workerName)")
            }
            Spacer(minLength: 4)
            if isKeyFocused {
                HStack(spacing: 3) {
                    Image(systemName: "keyboard").font(.system(size: 11))
                    Text("Key focus")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD5D9E5))
                .accessibilityLabel("Keyboard focus")
            }
        }
    }

    private var accessibilityTitle: String {
        switch control {
        case .observing(let holder): "Terminal input for \(workerName) is held by \(holder)"
        case .held: "You hold terminal input for \(workerName)"
        }
    }
}

// MARK: - RequestReply

/// What a reply surface needs from the feature layer. Drafts and focus are keyed by request ID, so
/// a draft follows its request between the PiP and the focused worker.
struct ReplyContext {
    let draft: (String) -> Binding<String>
    let focus: FocusState<String?>.Binding
    let sending: Set<String>
    let isOnline: Bool
    /// Emits the request to answer. The feature layer reads that request's own draft.
    let send: (RequestPresentation) -> Void
}

/// The one reply control. It answers exactly one request by ID and never touches terminal input.
/// The PiP and the focused worker both render this view. The page shows a given request in only one
/// of them at a time, so the request ID is a unique focus target.
struct RequestReply: View {
    let request: RequestPresentation
    let context: ReplyContext

    var body: some View {
        let draft = context.draft(request.id)
        let isSending = context.sending.contains(request.id)
        let blocked = !context.isOnline || isSending
        let isEmpty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isFocused = context.focus.wrappedValue == request.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        HStack(alignment: .center, spacing: 7) {
            TextField("Reply to \(request.workerName)…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1...4)
                .focused(context.focus, equals: request.id)
                .disabled(blocked)
                .onSubmit { if !blocked && !isEmpty { context.send(request) } }
                .accessibilityLabel("Reply to request \(request.shortID) from \(request.workerName)")
            if isSending {
                ProgressView().controlSize(.small).accessibilityLabel("Sending reply")
            } else {
                Button { context.send(request) } label: {
                    Image(systemName: isEmpty ? "paperplane" : "paperplane.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isEmpty || blocked ? Palette.secondary : Palette.working)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ⌘↩ belongs to the reply field that holds keyboard focus, and to no other instance.
                // Several replies can be on screen at once (PiP beside a focused worker); an unfocused
                // one must never receive the shortcut. A click still sends this button's own request.
                .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                .disabled(blocked || isEmpty)
                .help(context.isOnline ? "Send reply to \(request.workerName) (⌘↩ while typing)" : "The local service is offline")
                .accessibilityLabel("Send reply to \(request.workerName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.field, in: shape)
        .overlay { shape.strokeBorder(isFocused ? Palette.focus : Palette.fieldBorder, lineWidth: isFocused ? 1.5 : 1) }
    }
}

/// The instruction a worker or coordinator was given, with who gave it and when. Shared by the
/// coordinator console and the focused worker.
struct AssignmentBlock: View {
    let label: String
    let time: String?
    let text: String
    var lineLimit = 6
    var fontSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let time { Text(time).font(TypeRole.monoMeta) }
                Text(label.uppercased()).font(TypeRole.kicker).tracking(1)
            }
            .foregroundStyle(.inkSecondary)
            Text(text)
                .font(.system(size: fontSize, design: .monospaced)).lineSpacing(fontSize * 0.5)
                .foregroundStyle(Color(hex: 0xE1E4EE))
                .lineLimit(lineLimit).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11).padding(.vertical, 10)
                .background(Palette.assignmentFill)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.assignmentRule).frame(width: 2) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)\(time.map { ", \($0)" } ?? ""). \(text)")
    }
}

/// Compose line addressed to one named agent: a worker's terminal while the developer holds its
/// input, or the coordinator. It exists only where the matching action is available and emits the
/// text for that one target.
struct TerminalComposer: View {
    let workerName: String
    /// Field prompt. Defaults to typing into the worker's terminal.
    var prompt: String? = nil
    /// The terminal line is outlined to mark held input; the coordinator line is a quiet footer.
    var outlined = true
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 9) {
            Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(.inkSecondary)
            TextField(prompt ?? "Type in the \(workerName) terminal…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($isFocused)
                .onSubmit(submit)
                .accessibilityLabel(prompt ?? "Terminal input for \(workerName)")
            Button(action: submit) {
                Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Palette.working, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.75 : 1)
            .accessibilityLabel("Send to \(workerName)")
        }
        .padding(.horizontal, 13)
        .frame(minHeight: outlined ? 46 : 42)
        .background(Palette.footer)
        .overlay {
            if outlined || isFocused {
                Rectangle().strokeBorder(isFocused ? Palette.focus : Color(hex: 0x92AFD3).opacity(0.7), lineWidth: 1)
            }
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        send(value)
        text = ""
    }
}

/// Bell and request ID beside a worker's status.
struct NeedsInputFlag: View {
    let request: RequestPresentation

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bell").font(.system(size: 9))
            Text(request.shortID).font(TypeRole.monoMeta)
        }
        .foregroundStyle(Palette.attention)
        .help("Request \(request.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Request \(request.id) is waiting")
    }
}

/// Amber notice that names a waiting worker and jumps to its request.
struct AttentionNotice: View {
    let request: RequestPresentation
    let detail: String
    let open: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left").font(.system(size: 12)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(request.workerName) needs input").font(.system(size: 11.5, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xBBAD91)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.attention)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Palette.attentionFill, in: shape)
            .overlay { shape.strokeBorder(Palette.attentionSoftEdge) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(request.workerName) needs input. Show request \(request.shortID).")
    }
}

// MARK: - Navigation and headings

/// Path of names separated by chevrons.
struct Breadcrumb: View {
    let items: [String]
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).opacity(0.7) }
                Text(item).lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.inkSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.joined(separator: ", "))
    }
}

/// Lineage of a worker inside its run, in the monospaced metadata role.
struct LineagePath: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                if index > 0 { Text("›").opacity(0.6) }
                Text(name).lineLimit(1)
            }
        }
        .font(TypeRole.monoID)
        .foregroundStyle(.inkSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lineage: " + names.joined(separator: ", "))
    }
}

/// Title of a pane: symbol, name and an optional count.
struct SectionTitle: View {
    let symbol: String
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.inkSecondary)
            Text(title).font(TypeRole.sectionTitle).foregroundStyle(Palette.foreground)
            if let count { CountBadge(count: count) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Fixed-height bar above a pane, with leading and trailing slots.
struct SectionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: Metric.sectionBarHeight)
    }
}

/// Key cap plus the action it performs. It is a real button, so pointer and keyboard reach the same action.
struct KeyHint: View {
    let keys: String
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                KeyCap(keys: keys)
                Text(title).font(.system(size: 10)).foregroundStyle(.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(title), \(keys)")
    }
}

/// Local service state in the title bar.
struct ConnectionIndicator: View {
    let connection: CockpitModel.Connection

    var body: some View {
        HStack(spacing: 7) {
            switch connection {
            case .online:
                Circle().fill(Color(hex: 0x96D8B0)).frame(width: 7, height: 7)
                Text("Service online")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .offline:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.failure)
                Text("Service offline")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(hex: 0xE0E1EA))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch connection {
        case .online: "Local service online"
        case .connecting: "Connecting to local service"
        case .offline(let reason): "Local service offline. \(reason)"
        }
    }
}

/// Full-width notice with a reason, a symbol and one action.
struct NoticeBanner: View {
    let text: String
    let symbol: String
    let tone: Tone
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(text, systemImage: symbol).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
        }
        .font(.callout)
        .foregroundStyle(Palette.foreground)
        .padding(.horizontal, Metric.runHeaderInset)
        .padding(.vertical, 9)
        .background(tone.color.opacity(0.14))
    }
}

/// One destination in the navigation rail or sidebar.
struct NavigationItem: Identifiable {
    enum Mark { case symbol(String), letter(String) }

    let id: String
    let title: String
    let mark: Mark
    var badge: Int = 0
    var isActive = false
    var isEnabled = true
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
}

struct NavigationRow: View {
    let item: NavigationItem
    let expanded: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: item.action) {
            HStack(spacing: 11) {
                ZStack(alignment: .topTrailing) {
                    switch item.mark {
                    case .symbol(let name):
                        Image(systemName: name).font(.system(size: 14)).frame(width: 18, height: 18)
                    case .letter(let letter):
                        ProjectMark(letter: letter)
                    }
                    if item.badge > 0 && !expanded {
                        Text("\(min(item.badge, 9))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0x352A17))
                            .frame(width: 14, height: 14)
                            .background(Color(hex: 0xE6C58E), in: Circle())
                            .offset(x: 8, y: -6)
                    }
                }
                if expanded {
                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if item.badge > 0 {
                        Text("\(item.badge)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xF0CF96))
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color(hex: 0x4B3C25), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .foregroundStyle(item.isActive ? Palette.foreground : Color(hex: 0xD3D4DD))
            .padding(.horizontal, expanded ? 9 : 0)
            .frame(maxWidth: .infinity, minHeight: 35, alignment: expanded ? .leading : .center)
            .background {
                if item.isActive {
                    shape.fill(LinearGradient(colors: [Palette.navActiveTop, Palette.navActiveBottom],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { shape.strokeBorder(Palette.navActiveEdge) }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .keyboardShortcut(item.shortcut)
        .help(item.title)
        .accessibilityLabel(item.badge > 0 ? "\(item.title), \(item.badge) waiting" : item.title)
        .accessibilityAddTraits(item.isActive ? .isSelected : [])
    }
}

// MARK: - Form pieces

/// Label above a control.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(TypeRole.label).foregroundStyle(Palette.foreground)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Read-only value shown in the field shape, for settings that have a single supported choice.
struct StaticField: View {
    var symbol: String? = nil
    let value: String
    /// Marks a value chosen from several options. The live form has single-choice values only.
    var showsChevron = false

    var body: some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.inkSecondary) }
            Text(value).font(TypeRole.body).foregroundStyle(Palette.foreground).lineLimit(1)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.inkSecondary)
            }
        }
        .fieldBox()
        .accessibilityElement(children: .combine)
    }
}

/// Small bordered tag for an allowed capability.
struct CapabilityChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0xD2D7E1))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color(hex: 0x1D1E27), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0x3C404E)) }
    }
}

/// One option in an exclusive choice, with its consequence spelled out.
struct ChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                Circle().strokeBorder(isSelected ? Palette.focus : Color(hex: 0x566156), lineWidth: 1)
                if isSelected { Circle().fill(Palette.focus).padding(4) }
            }
            .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background {
            if isSelected {
                shape.fill(LinearGradient(colors: [Color(hex: 0x293344), Color(hex: 0x19212C)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(Palette.field)
            }
        }
        .overlay { shape.strokeBorder(isSelected ? Color(hex: 0x8BA3C4) : Palette.fieldBorder) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A host with the way Commander reaches it and whether it is reachable now.
struct HostAvailabilityRow: View {
    let symbol: String
    let name: String
    let detail: String
    let status: String
    let tone: Tone
    var statusSymbol = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.inkSecondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.foreground)
                Text(detail).font(.system(size: 12)).foregroundStyle(.inkSecondary)
            }
            Spacer(minLength: 8)
            StatusLabel(text: status, tone: tone, symbol: statusSymbol, size: 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Key and value on one line.
struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(Palette.foreground)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Uppercase tracked caption above a group.
struct Kicker: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(TypeRole.kicker).tracking(1.1).foregroundStyle(.inkSecondary)
    }
}
