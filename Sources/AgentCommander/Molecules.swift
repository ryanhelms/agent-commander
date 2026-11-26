import SwiftUI
import UniformTypeIdentifiers

// ATOMIC LEVEL: Molecules.
// Each molecule combines atoms for one understandable interaction and keeps its target, disabled
// reason and accessible value as its rendering changes. The same molecule serves the wall, the
// focused worker and the PiP; none of them has a private copy.

// MARK: - WorkerIdentity

/// Who a worker is: client mark, name and a line of attribution. Used where a worker is named
/// outside a terminal pane (the attention drawer, the request inspector). Terminal panes use
/// ConsoleTitleBar instead.
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

// MARK: - ConsoleTitleBar

/// The one title bar of an embedded terminal pane: the coordinator, a wall tile, the focused worker
/// and the PiP terminal all render it. One slim row carries a small client mark, the console title,
/// the execution host with its platform, and the branch or worktree. The trailing slot holds the
/// pane's real controls. It draws no window buttons, because a pane is not a window.
///
/// The host reads by platform, from explicit metadata only:
///   this Mac          apple mark, host name
///   Mac over SSH      apple mark, `ssh host`
///   Linux over SSH    `linux`, `ssh host`
///   not reported      neutral host mark, host name
///
/// The bar is always one line at a fixed height for its density, and nothing in it wraps. The
/// title, the trailing controls and the platform mark are kept at every width. As the pane
/// narrows the bar gives up, in order: the client word, the visible `ssh` prefix, the lineage,
/// the branch, and the host name. After that the title truncates at the tail, keeping a readable
/// start ahead of the trailing controls. The full statement, host and SSH hop included, stays in
/// the help tag and the accessibility label.
struct ConsoleTitleBar<Accessory: View>: View {
    enum Density { case tile, console, focused, pip }

    let title: String
    let client: AgentClient
    let host: String
    let platform: HostPlatform
    var location: String = ""
    var locationIsBranch = true
    /// Names above this console (run, then parent workers), shown before the title where needed.
    var lineage: [String] = []
    var density: Density = .tile
    @ViewBuilder let accessory: Accessory

    /// `.mark` keeps only the platform mark; the host stays in the help tag and spoken statement.
    private enum HostForm { case full, named, mark }

    private var height: CGFloat {
        switch density {
        case .tile: 30
        case .console: 32
        case .focused: 34
        case .pip: 28
        }
    }

    private var titleSize: CGFloat {
        switch density {
        case .tile: 12.5
        case .console: 13
        case .focused: 13.5
        case .pip: 12
        }
    }

    private var metaSize: CGFloat {
        switch density {
        case .tile, .pip: 10
        case .console: 10.5
        case .focused: 11
        }
    }

    /// Matches the inset of the terminal text beneath, so the bar and the scrollback share an edge.
    private var inset: CGFloat {
        switch density {
        case .tile, .pip: Metric.tileInset
        case .console: 17
        case .focused: 21
        }
    }

    /// The client word is left out when the console is named after its client.
    private var showsClientWord: Bool {
        title.caseInsensitiveCompare(client.displayName) != .orderedSame
    }

    @Environment(\.usesStrongContrast) private var usesStrongContrast

    var body: some View {
        let accent = HarnessAccentStore.shared.accent(for: client)
        HStack(spacing: 7) {
            AgentAvatar(client: client, size: density == .tile || density == .pip ? 16 : 18,
                        onHarnessHeader: true)
            // One horizontal line in every density, most complete first.
            ViewThatFits(in: .horizontal) {
                row(lineage: true, client: true, host: .full, branch: true)
                row(lineage: true, client: false, host: .full, branch: true)
                // Named host and branch are kept together for as long as both fit.
                row(lineage: true, client: false, host: .named, branch: true)
                row(lineage: false, client: false, host: .named, branch: true)
                // Then the branch goes as a whole; platform and host stay.
                row(lineage: false, client: false, host: .named, branch: false)
                // Then the host name, so the console's name is never what gives way first.
                row(lineage: false, client: false, host: .mark, branch: false)
                // Last, the title truncates, keeping its first characters. The platform mark never goes.
                row(lineage: false, client: false, host: .mark, branch: false, truncates: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The title cluster is offered width ahead of the trailing controls.
            .layoutPriority(1)
            .help(statement)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statement)
            .accessibilityAddTraits(.isHeader)
            accessory
        }
        .padding(.leading, inset)
        .padding(.trailing, max(6, inset - 5))
        .frame(height: height)
        .harnessHeaderFill(client)
        .overlay(alignment: .bottom) {
            Rectangle().fill(accent.headerRule(strongContrast: usesStrongContrast)).frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func row(lineage showLineage: Bool, client showClient: Bool, host form: HostForm,
                     branch showBranch: Bool, truncates: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            titleCluster(lineage: showLineage, truncates: truncates)
            if showClient, showsClientWord {
                Text("— " + client.displayName.lowercased())
                    .font(Term.font(metaSize)).foregroundStyle(Term.text)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            hostCluster(form, truncates: truncates)
            if showBranch { branchCluster }
        }
    }

    @ViewBuilder private func titleCluster(lineage showLineage: Bool, truncates: Bool) -> some View {
        if showLineage, !lineage.isEmpty {
            Text(lineage.joined(separator: " › ") + " ›")
                .font(Term.font(metaSize)).foregroundStyle(Term.text)
                .lineLimit(1).fixedSize()
        }
        Text(title)
            .font(.system(size: titleSize, weight: .semibold))
            .foregroundStyle(Palette.foreground)
            .lineLimit(1).truncationMode(.tail)
            .fixedSize(horizontal: !truncates, vertical: false)
            // When truncating, the title keeps a readable start and its width ahead of the host.
            .frame(minWidth: truncates ? titleSize * 4.5 : nil, alignment: .leading)
            .layoutPriority(truncates ? 2 : 0)
    }

    /// Platform and host. `.full` spells out the SSH hop for a remote host; `.named` keeps the
    /// platform mark and the host name. The spoken statement names the SSH hop in both forms.
    /// When `truncates` is set the host name may shorten at the tail; the platform mark does not.
    private func hostCluster(_ form: HostForm, truncates: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            PlatformMark(platform: platform, size: metaSize, tint: Palette.foreground)
            if form == .full, platform.isRemote { Text("ssh").foregroundStyle(Term.cyan).fixedSize() }
            if form != .mark {
                Text(host).foregroundStyle(Term.text)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !truncates, vertical: false)
            }
        }
        .font(Term.font(metaSize)).lineLimit(1)
    }

    @ViewBuilder private var branchCluster: some View {
        if !location.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: locationIsBranch ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: metaSize - 1, weight: .semibold))
                Text(location)
            }
            .font(Term.font(metaSize)).foregroundStyle(Term.text)
            .lineLimit(1).fixedSize()
        }
    }

    /// Everything the bar can show, in one sentence, whatever the width has room for.
    private var statement: String {
        var parts = [title]
        if showsClientWord { parts.append(client.displayName) }
        parts.append("host \(host), \(platform.label)")
        if !location.isEmpty { parts.append((locationIsBranch ? "branch " : "worktree ") + location) }
        if !lineage.isEmpty { parts.append("in " + lineage.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

extension ConsoleTitleBar where Accessory == EmptyView {
    init(title: String, client: AgentClient, host: String, platform: HostPlatform, location: String = "",
         locationIsBranch: Bool = true, lineage: [String] = [], density: Density = .tile) {
        self.init(title: title, client: client, host: host, platform: platform, location: location,
                  locationIsBranch: locationIsBranch, lineage: lineage, density: density) { EmptyView() }
    }
}

// MARK: - InputOwnership

/// Names who directs a worker. While observing it reads "Input · holder". When the developer
/// controls the worker it reads "You have control" and offers a real Hand back button, shown only
/// when a hand-back action exists. Control means the developer's follow-up messages go to the
/// worker; it is not raw terminal input. Keyboard focus is a separate cue on the trailing edge.
struct InputOwnership: View {
    let workerName: String
    let control: InputControl
    var isKeyFocused = false
    var handBack: (() -> Void)? = nil
    /// Takes control of the worker for the developer. Offered while observing, where the action exists.
    var takeControl: (() -> Void)? = nil
    /// A control request for this worker is in flight; its buttons wait for the answer.
    var isBusy = false

    private var held: Bool { control == .held }

    private var title: String {
        switch control {
        case .observing(let holder): "Input · \(holder)"
        case .held: "You have control"
        }
    }

    /// Text size, so the cue matches the status line it sits in.
    var size: CGFloat = 11
    /// What handing back cancels, shown beside Hand back, e.g. `cancels 1 queued follow-up`. Nil
    /// when it cancels nothing.
    var handBackNote: String? = nil
    /// The full consequence, for the note's help tag and the button's accessibility hint.
    var handBackStatement: String? = nil

    var body: some View {
        // A quiet inline cue for a terminal status line: no chip, no fill.
        HStack(spacing: 10) {
            if isKeyFocused { KeyFocusCue(size: size) }
            // The words are shown whole or not at all. In a narrow tile the symbol stands alone, with
            // the full statement in its help tag and accessibility label.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: held ? "hand.raised" : "eye").font(.system(size: size - 1.5))
                    Text(title.lowercased()).lineLimit(1).fixedSize()
                }
                Image(systemName: held ? "hand.raised" : "eye").font(.system(size: size - 1.5))
            }
            .font(Term.font(size))
            .foregroundStyle(held ? AnyShapeStyle(Term.green) : AnyShapeStyle(.inkTermDim))
            .help(accessibilityTitle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)

            if held, let handBack {
                Button("hand back", action: handBack)
                    .buttonStyle(TermButtonStyle(ink: Term.green, size: size))
                    .disabled(isBusy)
                    .accessibilityLabel("Hand back control of \(workerName)")
                    .accessibilityHint(handBackStatement ?? "")
                if let handBackNote {
                    Text(handBackNote)
                        .font(Term.font(size - 0.5)).foregroundStyle(Term.amber)
                        .lineLimit(1).fixedSize()
                        .help(handBackStatement ?? handBackNote)
                        .accessibilityHidden(true)
                }
            }
            if !held, let takeControl {
                Button("take control", action: takeControl)
                    .buttonStyle(TermButtonStyle(size: size))
                    .disabled(isBusy)
                    .accessibilityLabel("Take control of \(workerName)")
            }
        }
    }

    private var accessibilityTitle: String {
        switch control {
        case .observing(let holder): "\(workerName) is directed by \(holder)"
        case .held: "You control \(workerName). Your follow-up messages go to it."
        }
    }
}

/// The trailing keyboard-focus cue of a status line. Shared by `InputOwnership` and the gated
/// ownership cues of a worker whose provider availability is exited or checking.
struct KeyFocusCue: View {
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard").font(.system(size: size - 1))
            Text("key focus")
        }
        .font(Term.font(size))
        .foregroundStyle(Term.text)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard focus")
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

/// The provider's exact choices for one request: one native button per choice. A click puts that
/// choice's exact ID in the request's own draft and sends it through the request's reply action,
/// because the service accepts only an offered ID. The feature layer's send reads that one
/// request's draft, so the answer is addressed to this request ID and no other request changes.
/// Every surface that answers a permission request draws this: `PrettyRequestForm` and
/// `RequestReply` (the focused Console prompt, the PiP prompt, the Attention panel and queue).
/// One row when the choices fit; otherwise one per line. The group is the request's focus target.
struct RequestChoiceButtons: View {
    let request: RequestPresentation
    let context: ReplyContext

    /// The answer a choice sends: its exact ID, never its label.
    static func answer(for choice: QuestionChoice) -> String { choice.id }

    var body: some View {
        let isSending = context.sending.contains(request.id)
        let unavailable = request.replyUnavailableStatement
        let blocked = !context.isOnline || isSending || unavailable != nil
        let isFocused = context.focus.wrappedValue == request.id
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(blocked: blocked, isSending: isSending, unavailable: unavailable) }
            VStack(alignment: .leading, spacing: 6) {
                buttons(blocked: blocked, isSending: isSending, unavailable: unavailable)
            }
        }
        // The request's one focus anchor, outside both layouts so the ID is never bound twice. An
        // explicit Next Request or follow-up blocker focuses this group and outlines it; it never
        // selects or sends a choice. Each button keeps its own click and keyboard activation.
        .padding(3)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Palette.focus, lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusable()
        .focusEffectDisabled()
        .focused(context.focus, equals: request.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choices for request \(request.shortID)")
    }

    @ViewBuilder
    private func buttons(blocked: Bool, isSending: Bool, unavailable: String?) -> some View {
        ForEach(request.choices) { choice in
            Button {
                // The exact ID, through the request's own draft and reply action. A send already
                // in flight for this request disables the buttons, and the model refuses a
                // second one, so one click answers once.
                guard !blocked else { return }
                context.draft(request.id).wrappedValue = Self.answer(for: choice)
                context.send(request)
            } label: {
                Text(verbatim: choice.label).lineLimit(2)
            }
            .buttonStyle(.bordered)
            .disabled(blocked)
            .help(unavailable ?? "Reply with \(choice.id)")
            .accessibilityLabel(choice.label)
            .accessibilityHint("Replies to request \(request.shortID) with \(choice.id)")
        }
        if isSending {
            ProgressView().controlSize(.small).accessibilityLabel("Sending reply")
        }
    }
}

/// The one reply control. It answers exactly one request by ID and never touches terminal input.
/// The PiP and the focused worker both render this view. The page shows a given request in only one
/// of them at a time, so the request ID is a unique focus target.
///
/// While the asking worker is disconnected the reply is closed on every surface: the field and the
/// send action are disabled, a draft written earlier stays in place, and one line above the prompt
/// says why. The full reason, with the service's explanation, is the help tag and the accessible
/// value of that line and of the closed controls.
///
/// While a persistent SSH link reconnects the reply stays open, because the worker is still
/// running. The same line says the reply can be sent now and is held until the host returns:
/// Commander keeps one answer and the worker reads it when the link comes back. The full
/// statement is the help tag and accessible value of that line and the hint of the controls.
struct RequestReply: View {
    let request: RequestPresentation
    let context: ReplyContext

    var body: some View {
        let draft = context.draft(request.id)
        let isSending = context.sending.contains(request.id)
        let unavailable = request.replyUnavailableStatement
        let held = request.replyHeldStatement
        let blocked = !context.isOnline || isSending || unavailable != nil
        let isEmpty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isFocused = context.focus.wrappedValue == request.id && unavailable == nil
        let sendHelp = unavailable
            ?? (context.isOnline
                ? "Send reply to \(request.workerName) (↩ or ⌘↩ while typing)"
                    + (held == nil ? "" : ". Commander holds it until \(request.host) reconnects.")
                : "The local service is offline")

        VStack(alignment: .leading, spacing: 4) {
        if let unavailable {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("! ").accessibilityHidden(true)
                Text("reply unavailable until \(request.host) reconnects").lineLimit(2)
            }
            .font(Term.font(11)).foregroundStyle(Term.amber)
            .fixedSize(horizontal: false, vertical: true)
            .help(unavailable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reply unavailable")
            .accessibilityValue(unavailable)
        } else if let held {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("↻ ").accessibilityHidden(true)
                Text("reply now · held until \(request.host) reconnects").lineLimit(2)
            }
            .font(Term.font(11)).foregroundStyle(Term.amber)
            .fixedSize(horizontal: false, vertical: true)
            .help(held)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reply is held until \(request.host) reconnects")
            .accessibilityValue(held)
        }
        if !request.choices.isEmpty {
            // A permission request with the provider's exact choices: the same buttons as the
            // Pretty form, in place of the free-form prompt, which the service would refuse.
            RequestChoiceButtons(request: request, context: context)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
        // A terminal prompt: an amber mark, a native multiline field in the terminal face, and an
        // explicit send action. Black behind bright text, with an amber outline while it has focus.
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("❯").font(Term.font(12, weight: .semibold))
                .foregroundStyle(blocked ? AnyShapeStyle(.inkTermDim) : AnyShapeStyle(Term.amber))
                .accessibilityHidden(true)
            TextField("Reply to \(request.workerName)", text: draft,
                      prompt: Text(unavailable == nil ? "reply to \(request.workerName.lowercased())"
                                                      : "\(request.workerName.lowercased()) is disconnected"),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(Term.font(12))
                .foregroundStyle(Term.bright)
                .lineLimit(1...4)
                .focused(context.focus, equals: request.id)
                .disabled(blocked)
                .onSubmit { if !blocked && !isEmpty { context.send(request) } }
                .accessibilityLabel("Reply to request \(request.shortID) from \(request.workerName)")
                .accessibilityHint(unavailable ?? held ?? "")
            if isSending {
                Text("sending…").font(Term.font(11.5)).foregroundStyle(Term.amber)
                    .accessibilityLabel("Sending reply")
            } else {
                Button(isFocused ? "send ↩" : "send") { context.send(request) }
                    .buttonStyle(TermButtonStyle(ink: Term.amber))
                    // ⌘↩ belongs to the reply field that holds keyboard focus, and to no other instance.
                    // Several replies can be on screen at once (PiP beside a focused worker); an unfocused
                    // one must never receive the shortcut. A click still sends this button's own request.
                    .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                    .disabled(blocked || isEmpty)
                    .help(sendHelp)
                    .accessibilityLabel("Send reply to \(request.workerName)")
                    .accessibilityHint(unavailable ?? held ?? "")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Term.background)
        .overlay { Rectangle().strokeBorder(isFocused ? Term.amber : Term.promptEdge, lineWidth: 1) }
        }
        }
    }
}

/// What the service reports is wrong with a console, as lines in its scrollback: a failure in red
/// behind `✗`, a lost connection in amber behind `!`. The coordinator console and the worker tile
/// in both variants render this view, so a disconnect reads the same on each.
struct ConsoleNotice: View {
    let text: String
    /// The console's status. A disconnected console's notice is its connection explanation.
    let state: TaskState
    var size: CGFloat = 11.5

    private var isDisconnect: Bool { state == .disconnected }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(isDisconnect ? "! " : "✗ ").accessibilityHidden(true)
            Text(text).lineLimit(4).textSelection(.enabled)
        }
        .font(Term.font(size)).foregroundStyle(isDisconnect ? Term.amber : Term.red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDisconnect ? "Disconnected: \(text)" : "Error: \(text)")
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
        // The first entry of the scrollback: `❯ label  time`, then the instruction in the bright ink.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("❯ ").foregroundStyle(.inkTermDim)
                Text(label.lowercased()).fontWeight(.semibold).foregroundStyle(Term.text)
                if let time { Text("  " + time).foregroundStyle(.inkTermDim) }
            }
            .font(Term.font(fontSize))
            .lineLimit(1)
            Text(text)
                .font(Term.font(fontSize)).lineSpacing(fontSize * 0.4)
                .foregroundStyle(Term.bright)
                .lineLimit(lineLimit).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, fontSize * 1.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)\(time.map { ", \($0)" } ?? ""). \(text)")
    }
}

/// Compose line addressed to one named agent: a follow-up message to a worker the developer
/// controls, or a message to the coordinator. It sends a message; it is not keystrokes into a
/// terminal. It exists only where the matching action is available and emits the text for that
/// one target, exactly as written: several lines are kept and nothing is trimmed. While a send is
/// in flight the line is locked, so the same text cannot go twice, and the draft is cleared only
/// once the send is accepted.
struct TerminalComposer: View {
    let workerName: String
    /// Field prompt. Defaults to a follow-up for the worker.
    var prompt: String? = nil
    /// The follow-up line is outlined to mark that the developer controls the worker; the
    /// coordinator line is a quiet footer.
    var outlined = true
    /// Returns true when the message was accepted.
    let send: (String) async -> Bool
    /// File context for the follow-up: a link to a file in the worker's checkout or a snapshot of
    /// a file. Nil where the session accepts neither, and the line is as before. A draft without
    /// files always goes through `send`.
    var context: FollowUpContextAccess? = nil
    @State private var text = ""
    @State private var isSending = false
    /// Files attached to this draft, in the order they are sent.
    @State private var files: [FollowUpContextItem] = []
    /// The file chooser is open.
    @State private var isChoosing = false
    /// The kind of file the chooser is for. Kept until the chooser reports.
    @State private var chosenKind: FollowUpContextKind?
    /// Why the last chosen file could not be attached.
    @State private var fileError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
        let title = prompt ?? "Follow up with \(workerName)"
        VStack(alignment: .leading, spacing: 5) {
            if context != nil, !files.isEmpty || fileError != nil {
                attachments
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("❯").font(Term.font(12, weight: .semibold))
                    .foregroundStyle(isSending ? AnyShapeStyle(.inkTermDim) : AnyShapeStyle(Term.cyan))
                    .accessibilityHidden(true)
                TextField(title, text: $text, prompt: Text(title.lowercased()), axis: .vertical)
                    .textFieldStyle(.plain).font(Term.font(12))
                    .foregroundStyle(Term.bright)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .disabled(isSending)
                    .onSubmit(submit)
                    .accessibilityLabel(prompt ?? "Follow-up message for \(workerName)")
                if let context {
                    FollowUpContextMenu(linkUnavailable: context.linkUnavailable,
                                        snapshotUnavailable: context.snapshotUnavailable,
                                        isEnabled: !isSending) { kind in
                        fileError = nil
                        chosenKind = kind
                        isChoosing = true
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                if isSending {
                    Text("sending…").font(Term.font(11.5)).foregroundStyle(Term.cyan)
                        .accessibilityLabel("Sending to \(workerName)")
                } else {
                    Button(isFocused ? "send ↩" : "send", action: submit)
                        .buttonStyle(TermButtonStyle(ink: Term.cyan))
                        .disabled(isEmpty)
                        .help("Send to \(workerName) (↩; ⌥↩ for a new line)")
                        .accessibilityLabel("Send to \(workerName)")
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .frame(minHeight: outlined ? 34 : 32)
        .background(Term.background)
        .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
        .overlay {
            if outlined || isFocused {
                Rectangle().strokeBorder(isFocused ? Term.cyan : Term.promptEdge, lineWidth: 1)
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            attach(result)
        }
    }

    /// The selected files above the field, each removable, and why the last choice failed.
    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files) { file in
                            FollowUpContextChip(item: file, isEnabled: !isSending) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                    }
                }
                .padding(.leading, 19)
            }
            if let fileError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "! " + fileError).foregroundStyle(Term.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("dismiss") { self.fileError = nil }
                        .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                }
                .font(Term.font(10.75))
                .padding(.leading, 19)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("File not attached: \(fileError)")
            }
        }
    }

    private func attach(_ result: Result<[URL], Error>) {
        // The chooser clears its presentation before it reports, so the kind is kept apart.
        guard let kind = chosenKind, let context else { return }
        chosenKind = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch context.prepare(url, kind) {
            case .success(let item):
                files.append(item)
                fileError = nil
            case .failure(let error):
                fileError = error.localizedDescription
            }
        case .failure(let error):
            fileError = error.localizedDescription
        }
        isFocused = true
    }

    private func submit() {
        // Emptiness is judged without whitespace, but the text that goes out is the literal draft.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !isSending, hasText || !files.isEmpty else { return }
        let message = text
        let attached = files
        isSending = true
        Task {
            // A draft without files keeps the original text request.
            let accepted: Bool
            if let context, !attached.isEmpty {
                accepted = await context.send(message, attached)
            } else {
                accepted = await send(message)
            }
            isSending = false
            // Cleared only on acceptance, and only if the developer has not edited it meanwhile.
            if accepted, text == message, files == attached {
                text = ""
                files = []
                fileError = nil
            }
        }
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
        // An amber line in the scrollback. The whole line is the button that opens the request.
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("? ").fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(request.workerName) needs input").fontWeight(.semibold).lineLimit(1)
                    Text(request.isWorkerDisconnected ? "\(detail) · disconnected"
                         : request.hostIsReconnecting ? "\(detail) · \(request.host) reconnecting" : detail)
                        .foregroundStyle(.inkTermDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("[ view ]")
            }
            .font(Term.font(11.5))
            .foregroundStyle(Term.amber)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Term.amberWash)
            .overlay(alignment: .leading) { Rectangle().fill(Term.amber).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(request.workerName) needs input. Show request \(request.shortID).")
        .accessibilityHint(request.replyUnavailableStatement ?? request.replyHeldStatement ?? "")
    }
}

// MARK: - Terminal request prompt and status line

/// A pending request inside a terminal scrollback: `? input needed <id>`, the exact question and
/// the shared RequestReply as its prompt. The focused worker and the PiP both render this view; the
/// density only changes type size.
struct RequestPrompt: View {
    enum Density { case focused, compact }

    let request: RequestPresentation
    let reply: ReplyContext
    var density: Density = .focused
    var inset: CGFloat = 12

    private var size: CGFloat { density == .focused ? 13 : 11.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .focused ? 6 : 5) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("? ").foregroundStyle(Term.amber)
                    Text("input needed").fontWeight(.semibold).foregroundStyle(Term.amber)
                    Text("  " + request.shortID).foregroundStyle(.inkTermDim).help("Request \(request.id)")
                }
                .font(Term.font(size - 1))
                .lineLimit(1)
                // The choice list appended for text surfaces is left out when buttons draw it.
                Text(request.promptWithoutChoiceList)
                    .font(Term.font(size, weight: .semibold))
                    .lineSpacing(size * 0.3)
                    .foregroundStyle(Term.bright)
                    .lineLimit(density == .focused ? 8 : 6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, (size - 1) * 1.2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input needed, request \(request.shortID). \(request.promptWithoutChoiceList)")
            RequestReply(request: request, context: reply)
        }
        .padding(.leading, inset).padding(.trailing, inset).padding(.vertical, density == .focused ? 9 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Term.amberWash)
        .overlay(alignment: .leading) { Rectangle().fill(Term.amber).frame(width: 2) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(request.shortID) from \(request.workerName)")
    }
}

/// The slim footer of a terminal surface. Leading: the live status as a glyph and a word. Then an
/// amber `[ view request ]` action, only while a request waits and a way to reach it exists. It
/// stays for a disconnected worker, whose request can still be read.
/// Trailing: whatever is useful in the current state (input ownership, a key hint). It never carries
/// run or worker IDs or an attach command.
struct TerminalStatusLine<Trailing: View>: View {
    let state: TaskState
    var size: CGFloat = 11.5
    var inset: CGFloat = Metric.tileInset
    var request: RequestPresentation? = nil
    var openRequest: (() -> Void)? = nil
    /// The execution host, while its persistent SSH link is reconnecting. Nil otherwise. It
    /// follows the status, which stays the worker's own.
    var reconnectingHost: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TerminalStatus(state: state, size: size)
            // Its word is kept ahead of the trailing cue's. In a narrow tile the mark stands alone.
            if let reconnectingHost { HostLinkStatus(host: reconnectingHost, size: size).layoutPriority(2) }
            if let request, let openRequest {
                Button("view request", action: openRequest)
                    .buttonStyle(TermButtonStyle(ink: Term.amber, size: size))
                    .help("Show request \(request.shortID) from \(request.workerName)")
                    .accessibilityLabel("View request \(request.shortID) from \(request.workerName)")
            }
            Spacer(minLength: 6)
            // Offered the remaining width before the spacer, so a cue that can show its words does.
            trailing.layoutPriority(1)
        }
        .padding(.horizontal, inset)
        .frame(minHeight: (size * 2.3).rounded())
        .background(Term.bar)
        .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
    }
}

extension TerminalStatusLine where Trailing == EmptyView {
    init(state: TaskState, size: CGFloat = 11.5, inset: CGFloat = Metric.tileInset,
         request: RequestPresentation? = nil, openRequest: (() -> Void)? = nil,
         reconnectingHost: String? = nil) {
        self.init(state: state, size: size, inset: inset, request: request, openRequest: openRequest,
                  reconnectingHost: reconnectingHost) { EmptyView() }
    }
}

// MARK: - Structured transcript

/// One tool call in a transcript: a disclosure row with the tool's name, its summary and its
/// state, and the result beneath when open. The row is a real button, so Tab reaches it and Space
/// opens it. A call with no result text yet has nothing to open and is not a button target. The
/// state is the call's `ToolStatus`. An error the output does not already state is shown above the
/// output in the status ink, so a failure with no output still opens.
struct TranscriptToolRow: View {
    let name: String
    let detail: String?
    /// Nil while the call is still running.
    let result: ToolResult?
    let isExpanded: Bool
    var fontSize: CGFloat = TypeRole.wallTerminalSize
    /// The face of the row. The call, its status mapping and its disclosure are the same in both.
    var style: Style = .terminal
    /// The worker is waiting for the developer's reply and this is its open call. Only a call
    /// with no result reads as awaiting approval; every other call keeps its own status.
    var isAwaitingApproval = false
    let toggle: () -> Void

    enum Style {
        /// A line of the terminal transcript.
        case terminal
        /// A quiet inline card in the Pretty conversation, below the prominence of the agent's text.
        case pretty
    }

    private var status: ToolStatus {
        isAwaitingApproval && result == nil ? .awaitingApproval : ToolStatus(result: result)
    }
    private var canExpand: Bool { result?.error != nil || !(result?.output ?? "").isEmpty }

    var body: some View {
        switch style {
        case .terminal: terminal
        case .pretty: pretty
        }
    }

    /// Pretty: one rounded row with the tool, its summary and its state. Open, the result sits in
    /// the same card in the terminal face, whole and selectable.
    private var pretty: some View {
        let shape = RoundedRectangle(cornerRadius: fontSize * 0.7, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                    Image(systemName: detail?.hasPrefix("$") == true ? "terminal" : "wrench.and.screwdriver")
                        .font(.system(size: fontSize - 1.5, weight: .medium))
                        .foregroundStyle(.inkSecondary)
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(Palette.foreground.opacity(0.88))
                        .lineLimit(1).fixedSize()
                    if let detail {
                        Text(detail)
                            .font(Term.font(fontSize - 0.5))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(isExpanded ? 4 : 1).truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: fontSize * 0.5)
                    Text("\(status.mark) \(status.word)")
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(status.ink)
                        .lineLimit(1).fixedSize()
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: fontSize - 3.5, weight: .semibold))
                            .foregroundStyle(.inkSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, fontSize * 0.75).padding(.vertical, fontSize * 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel("Tool \(name)\(detail.map { ", \($0)" } ?? ""), \(status.word)")
            .accessibilityValue(canExpand ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityHint(canExpand ? "Shows or hides the tool's result" : "")
            if isExpanded, let result, canExpand {
                Rectangle().fill(.inkHairline).frame(height: 1)
                resultText(result)
                    .padding(.horizontal, fontSize * 0.75).padding(.vertical, fontSize * 0.6)
                    .background(Palette.well)
            }
        }
        .background(Palette.panel.opacity(0.7), in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.inkHairline, lineWidth: 1) }
    }

    private func resultText(_ result: ToolResult) -> some View {
        VStack(alignment: .leading, spacing: fontSize * 0.2) {
            if let error = result.separateError {
                Text(error)
                    .foregroundStyle(status.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(name) \(status.word): \(error)")
            }
            if !result.output.isEmpty {
                Text(result.output)
                    .foregroundStyle(Term.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Result of \(name): \(result.output)")
            }
        }
        .font(Term.font(fontSize - 0.5)).lineSpacing(fontSize * 0.2)
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.25) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(canExpand ? (isExpanded ? "▾ " : "▸ ") : "· ").foregroundStyle(.inkTermDim)
                    Text(name).fontWeight(.semibold).foregroundStyle(Term.violet)
                    if let detail {
                        Text(" " + detail)
                            .foregroundStyle(detail.hasPrefix("$") ? Term.cyan : Term.text)
                            .lineLimit(isExpanded ? 4 : 1).truncationMode(.tail)
                    }
                    Text("  \(status.mark) \(status.word)")
                        .foregroundStyle(status.ink)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .font(Term.font(fontSize))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel("Tool \(name)\(detail.map { ", \($0)" } ?? ""), \(status.word)")
            .accessibilityValue(canExpand ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityHint(canExpand ? "Shows or hides the tool's result" : "")
            if isExpanded, let result, canExpand {
                resultText(result)
                .padding(.leading, fontSize * 0.9)
                .overlay(alignment: .leading) { Rectangle().fill(Term.dim).frame(width: 1) }
                .padding(.leading, fontSize * 0.3)
            }
        }
    }
}

/// The status of a tool result whose call the service did not send, when that result carries an
/// error: the mark and word of its `ToolStatus`, then the error unless the output already states
/// it. Console and Pretty both place it above the orphan's output.
struct ToolResultStatusLine: View {
    let result: ToolResult
    var fontSize: CGFloat = TypeRole.wallTerminalSize

    var body: some View {
        let status = ToolStatus(result: result)
        let error = result.separateError
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(status.mark) \(status.word)").fontWeight(.semibold).fixedSize()
            if let error { Text("  " + error).textSelection(.enabled) }
        }
        .font(Term.font(fontSize)).foregroundStyle(status.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tool result \(status.word)" + (error.map { ": \($0)" } ?? ""))
    }
}

/// The structured transcript of one console, in the terminal face: agent and developer text with
/// selectable content, and tool calls as disclosure rows. The coordinator, the wall tile, the
/// focused worker and the PiP all render this view when the service sends structured messages;
/// density is the font size and inset. Without structured messages the same surfaces show the
/// TerminalWell. It follows new entries while the reader is at the end.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    /// Name shown on the agent's speaker line.
    let agentName: String
    var fontSize: CGFloat = TypeRole.wallTerminalSize
    var inset: CGFloat = Metric.tileInset
    /// The worker whose console this is. With it, each entry offers its fields, as it does in
    /// Pretty mode. A fixture without one shows the transcript alone.
    var consoleID: String? = nil
    /// Where an entry's fields open: beneath it in a roomy console, in a popover elsewhere.
    var density: PrettyDensity = .compact
    /// Open tool rows, by tool-call ID.
    @State private var expanded = Set<String>()

    var body: some View {
        // A streamed reply is one entry: the characters the agent sent, end to end, with its own
        // line breaks. Every other entry stays as it arrived, in order, with the service's text.
        let entries = TranscriptEntry.displayed(self.entries, mode: .console)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: fontSize * 0.5) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: fontSize * 0.2) {
                        if index == 0 || entries[index - 1].isFromUser != entry.isFromUser {
                            speaker(fromUser: entry.isFromUser)
                                .padding(.top, index == 0 ? 0 : fontSize * 0.35)
                        }
                        if let consoleID {
                            VStack(alignment: .leading, spacing: fontSize * 0.2) { content(entry) }
                                .recordDetail(consoleID: consoleID, entry: entry, face: .terminal, density: density)
                        } else {
                            content(entry)
                        }
                    }
                }
            }
            .padding(.horizontal, inset).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Console transcript, \(agentName)")
    }

    private func speaker(fromUser: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(fromUser ? "❯ " : "● ").foregroundStyle(fromUser ? AnyShapeStyle(.inkTermDim) : AnyShapeStyle(Term.cyan))
            Text(fromUser ? "you" : agentName.lowercased())
                .fontWeight(.semibold)
                .foregroundStyle(fromUser ? Term.text : Term.cyan)
        }
        .font(Term.font(fontSize)).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fromUser ? "You" : agentName)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func content(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .prose(let text, let fromUser):
            // A joined reply keeps its exact text. Line breaks at its two ends are not drawn,
            // since the row already starts and ends a line; those inside it are.
            Text(Self.inline(text.trimmingCharacters(in: .newlines), base: fromUser ? Term.bright : Term.text))
                .font(Term.font(fontSize)).lineSpacing(fontSize * 0.3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name, let detail, let result):
            TranscriptToolRow(name: name, detail: detail, result: result,
                              isExpanded: expanded.contains(entry.id), fontSize: fontSize) {
                if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }
        case .output(let result):
            if result.error != nil { ToolResultStatusLine(result: result, fontSize: fontSize) }
            if !result.output.isEmpty {
                Text(result.output)
                    .font(Term.font(fontSize - 0.5)).lineSpacing(fontSize * 0.2)
                    .foregroundStyle(.inkTermDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .other(let role, let written):
            // `system` text is the harness's own output and reads as the agent's, as before. Any
            // other role is named on a dim line first, and an entry with no text says so. A reply
            // that streamed only whitespace has nothing to read either; its text is in its fields.
            let text = written.contains(where: { !$0.isWhitespace }) ? written : ""
            if role != "system" || text.isEmpty {
                Text(verbatim: "· " + (role.isEmpty ? "record" : role) + (text.isEmpty ? " · no text, see fields" : ""))
                    .font(Term.font(fontSize - 0.5)).foregroundStyle(.inkTermDim)
                    .accessibilityLabel("\(role.isEmpty ? "Record" : role)" + (text.isEmpty ? ", no text" : ""))
            }
            if !text.isEmpty {
                Text(Self.inline(text, base: Term.text))
                    .font(Term.font(fontSize)).lineSpacing(fontSize * 0.3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Text with `` `code` `` spans in the command ink, without the backticks. Everything else is
    /// shown literally.
    private static func inline(_ text: String, base: Color) -> AttributedString {
        var result = AttributedString()
        let pieces = text.components(separatedBy: "`")
        // An odd number of backticks leaves the last one unpaired; it is then shown as written.
        let paired = pieces.count % 2 == 1
        for (index, piece) in pieces.enumerated() {
            let isCode = paired && index % 2 == 1
            var run = AttributedString(!paired && index > 0 ? "`" + piece : piece)
            run.foregroundColor = isCode ? Term.cyan : base
            result += run
        }
        return result
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

/// Chooses where pending requests appear in the cockpit: the side panel or the PiP stack. A
/// native menu with the two presentations the cockpit renders.
struct AttentionPresentationMenu: View {
    @Binding var selection: AttentionPresentation

    /// The presentations the cockpit can show, default first.
    static let options: [AttentionPresentation] = [.drawer, .pip]

    var body: some View {
        Menu {
            Picker("Show requests in", selection: $selection) {
                ForEach(Self.options) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: selection == .pip ? "pip" : "sidebar.right")
                .font(.system(size: 12)).frame(width: 23, height: 23)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.inkSecondary)
        .help("Show requests in: \(selection.title)")
        .accessibilityLabel("Show requests in")
        .accessibilityValue(selection.title)
    }
}

/// Local service state in the title bar.
struct ConnectionIndicator: View {
    let connection: CockpitModel.Connection
    /// The headless host whose service this is. Nil for this Mac's own service.
    var host: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            switch connection {
            case .online:
                Circle().fill(Color(hex: 0x96D8B0)).frame(width: 7, height: 7)
                Text(host.map { "\($0) online" } ?? "Service online")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .offline:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.failure)
                Text(host.map { "\($0) offline" } ?? "Service offline")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(hex: 0xE0E1EA))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let service = host.map { "Service on \($0)" } ?? "Local service"
        switch connection {
        case .online: return "\(service) online"
        case .connecting: return "Connecting to \(service.prefix(1).lowercased() + service.dropFirst())"
        case .offline(let reason): return "\(service) offline. \(reason)"
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
    /// Opens the network tray's share sheet for this project's repository. Its context menu shows it.
    var share: (() -> Void)? = nil
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
        .contextMenu {
            if let share = item.share { Button("Share…", action: share) }
        }
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
    /// Tints the label for a state such as "Check delivery". Nil keeps the neutral tag.
    var tone: Tone? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tone?.color ?? Color(hex: 0xD2D7E1))
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
