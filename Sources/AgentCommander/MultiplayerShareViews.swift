import AppKit
import SwiftUI

// ATOMIC LEVEL: Molecules and organisms for share and consult
// (design/COMMANDER-NETWORK-INCREMENT-3.md; design/mockups/commander-network-tray.html, state f and
// the Inc 3 rows of the command-center tray).
//   Molecules:  MultiplayerDecisionRow, MultiplayerLinkRow, MultiplayerActionCheck, MultiplayerChoice,
//               MultiplayerContextField, MultiplayerLoadNote
//   Organisms:  MultiplayerRemoteWorkBand, MultiplayerSharingBand, MultiplayerDirectoryPage,
//               MultiplayerRequestAccessPage, MultiplayerAccessRequestsPage, MultiplayerApprovalPage,
//               MultiplayerGrantSheet, MultiplayerConsultPage, MultiplayerHandoffComposer,
//               MultiplayerHandoffList, MultiplayerHandoffDetail, MultiplayerThreadPage, MultiplayerAuditPage
// Each takes values and emits actions; MultiplayerPanel wires them to MultiplayerShareModel.

// MARK: - Molecules

/// A request that waits for a yes or a no. The text opens the full review.
struct MultiplayerDecisionRow: View {
    let color: Color
    let title: String
    let detail: String
    var declineTitle = "Deny"
    var acceptTitle = "Approve"
    let isBusy: Bool
    let onOpen: () -> Void
    let onDecline: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerSwatch(color: color)
                .frame(width: 20)
                .padding(.top, 4)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Review this request")
            .accessibilityLabel("\(title). \(detail)")
            .accessibilityHint("Opens the full request")
            Button(declineTitle, action: onDecline)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(isBusy)
                .accessibilityLabel("\(declineTitle): \(title)")
            Button(acceptTitle, action: onAccept)
                .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                .disabled(isBusy)
                .accessibilityLabel("\(acceptTitle): \(title)")
        }
        .frame(minHeight: 30)
    }
}

/// A row that opens a page: what is there, how much of it, and a chevron.
struct MultiplayerLinkRow: View {
    let symbol: String
    let title: String
    let caption: String
    var count: Int = 0
    var isHot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.inkSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                    Text(caption).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    Text("\(count)")
                        .font(MultiplayerTheme.heading.monospacedDigit())
                        .foregroundStyle(isHot ? MultiplayerTheme.attention : MultiplayerTheme.foreground)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(MultiplayerRowButtonStyle())
        .accessibilityLabel(count > 0 ? "\(title), \(count). \(caption)" : "\(title). \(caption)")
    }
}

/// One action the person can tick, with what it lets a friend do.
struct MultiplayerActionCheck: View {
    let action: String
    let detail: String?
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? MultiplayerTheme.focus : MultiplayerTheme.border)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(MultiplayerCapability.title(action))
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                    if let detail {
                        Text(detail)
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(MultiplayerRowButtonStyle())
        .accessibilityLabel(MultiplayerCapability.title(action))
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A few named options, one chosen, with its label and a line saying what the choice means.
struct MultiplayerChoice<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    var note: String? = nil

    var body: some View {
        MultiplayerField(label: label, hint: note) {
            MultiplayerSegments(label: label, options: options, title: title, selection: $selection)
        }
    }
}

/// Files attached as context: each with its size and a way to take it off, and the way to add more.
struct MultiplayerContextField: View {
    let items: [MultiplayerContextItem]
    let problem: String?
    let onChoose: () -> Void
    let onDrop: ([URL]) -> Void
    let onDetach: (MultiplayerContextItem) -> Void

    var body: some View {
        MultiplayerField(label: "Context files",
                         hint: items.isEmpty ? "Attach text files, diffs or logs. Drop them here or choose them. They go to your friend’s worker with the prompt."
                                             : "\(MultiplayerContextBundle.size(MultiplayerContextBundle.bytes(items))) of 90 KiB attached.",
                         problem: problem) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: Space.s) {
                        Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.inkSecondary)
                        Text(item.name.multiplayerDisplay)
                            .font(MultiplayerTheme.mono)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Space.s)
                        Text(MultiplayerContextBundle.size(item.bytes))
                            .font(MultiplayerTheme.sub.monospacedDigit())
                            .foregroundStyle(.inkSecondary)
                        SymbolButton(symbol: "xmark", label: "Remove \(item.name.multiplayerDisplay)") { onDetach(item) }
                            .foregroundStyle(.inkSecondary)
                    }
                    .accessibilityElement(children: .contain)
                }
                Button(action: onChoose) { Label(items.isEmpty ? "Attach files…" : "Attach more…", systemImage: "paperclip") }
                    .buttonStyle(MultiplayerTrayButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { onDrop(files) }
                return !files.isEmpty
            }
        }
    }
}

/// A list still being read, or one that couldn't be.
struct MultiplayerLoadNote: View {
    let loading: String
    let failure: String?
    let onRetry: () -> Void

    var body: some View {
        if let failure {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(failure)
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(MultiplayerTheme.failure)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onRetry).buttonStyle(MultiplayerTrayButtonStyle())
            }
        } else {
            HStack(spacing: Space.s) {
                MultiplayerSpinner()
                Text(loading).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The system's open panel, for context files and for the checkout an artifact goes into.
@MainActor
enum MultiplayerFilePanel {
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose text files to send as context"
        panel.prompt = "Attach"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseCheckout(for name: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the checkout for \(name)"
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}

private func stateText(_ title: String, _ tone: Tone) -> some View {
    Text(title)
        .font(MultiplayerTheme.state)
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.inkSecondary) : AnyShapeStyle(tone.color))
        .lineLimit(1)
}

// MARK: - Home and server bands

/// Hand-offs, reviews and fan-outs you sent, across servers: what, to whose agent, and how it stands.
struct MultiplayerRemoteWorkBand: View {
    struct Item: Identifiable {
        let id: String
        var symbol = "arrow.up.right"
        /// What kind of work it is, for VoiceOver and the tooltip.
        var kind = "Hand-off"
        let title: String
        let detail: String
        let color: Color
        let state: String
        let tone: Tone
        let open: () -> Void
    }

    let items: [Item]
    static let preview = 4
    @State private var showsAll = false

    var body: some View {
        if !items.isEmpty {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "Live remote work", count: "\(items.count)")
                    ForEach(showsAll ? items : Array(items.prefix(Self.preview))) { item in
                        Button(action: item.open) {
                            HStack(spacing: Space.s) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.inkSecondary)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(MultiplayerTheme.name)
                                        .foregroundStyle(MultiplayerTheme.foreground)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        MultiplayerSwatch(color: item.color)
                                        Text(item.detail).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                stateText(item.state, item.tone)
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MultiplayerRowButtonStyle())
                        .multiplayerArriving()
                        .help(item.kind)
                        .accessibilityLabel("\(item.kind): \(item.title), \(item.detail), \(item.state)")
                        .accessibilityHint("Opens it")
                    }
                    if items.count > Self.preview {
                        Button(showsAll ? "Show fewer" : "Show all \(items.count)") { showsAll.toggle() }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .padding(.top, 4)
                    }
                }
                .multiplayerStreaming(showsAll)
            }
        }
    }
}

/// One server's ways into share and consult.
struct MultiplayerSharingBand: View {
    let directoryCount: Int
    let requestCount: Int
    let approvalCount: Int
    let handoffCount: Int
    let canShare: Bool
    let onShare: () -> Void
    let onDirectory: () -> Void
    let onRequests: () -> Void
    let onApprovals: () -> Void
    let onHandoffs: () -> Void
    let onAudit: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 0) {
                MultiplayerBandHeading(title: "Share and consult") {
                    Button(action: onShare) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(!canShare)
                        .help(canShare ? "Give a friend access to one of your resources" : "Add a friend and a resource first")
                }
                MultiplayerLinkRow(symbol: "square.grid.2x2", title: "Shared directory",
                                   caption: directoryCount == 0 ? "Nothing from friends yet" : "What friends offer, and what you can use",
                                   count: directoryCount, action: onDirectory)
                if approvalCount > 0 {
                    MultiplayerLinkRow(symbol: "hand.raised", title: "Waiting for your approval",
                                       caption: "Requests under Ask each time", count: approvalCount, isHot: true,
                                       action: onApprovals)
                }
                MultiplayerLinkRow(symbol: "tray.2", title: "Access requests", caption: "Sent to you and by you",
                                   count: requestCount, isHot: true, action: onRequests)
                MultiplayerLinkRow(symbol: "arrow.up.right", title: "Hand-offs", caption: "Tasks you gave a friend’s agent",
                                   count: handoffCount, action: onHandoffs)
                MultiplayerLinkRow(symbol: "list.bullet.rectangle", title: "Audit",
                                   caption: "Every use of what you shared, and what you sent", action: onAudit)
            }
        }
    }
}

/// Agents as first-class entries: yours with who holds access and control, and friends' with what
/// runs them and what you can do with each. A row's actions sit under its text as one strip, so
/// the text keeps the row's full width.
struct MultiplayerAgentRoster: View {
    let mine: [MultiplayerPending<MultiplayerResource>]
    let theirs: [MultiplayerPending<MultiplayerDirectoryEntry>]
    let serverName: (String) -> String
    let grantCount: (MultiplayerPending<MultiplayerResource>) -> Int
    /// The friend who holds control of one of your workers now.
    var holder: (MultiplayerPending<MultiplayerResource>) -> String? = { _ in nil }
    let isWaiting: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Bool
    let isBusy: Bool
    /// Servers where one prompt can go to several workers.
    var fanoutServers: [String] = []
    let onShare: (MultiplayerPending<MultiplayerResource>) -> Void
    let onAudit: (MultiplayerPending<MultiplayerResource>) -> Void
    var onControl: (MultiplayerPending<MultiplayerResource>) -> Void = { _ in }
    let onConsult: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Void
    let onHandOff: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Void
    var onWatch: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Void = { _ in }
    var onReview: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Void = { _ in }
    let onRequest: (MultiplayerPending<MultiplayerDirectoryEntry>) -> Void
    let onDirectory: (String) -> Void
    var onFanout: (String) -> Void = { _ in }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Your agents", count: mine.isEmpty ? nil : "\(mine.count)")
                if mine.isEmpty {
                    Text("No agent of yours is on the network yet. Choose Share… on a worker in the cockpit, or add one on a server’s page.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(mine) { agent in
                    let count = grantCount(agent)
                    let name = agent.item.name.multiplayerDisplay
                    let held = holder(agent)
                    row(tone: count > 0 ? .working : .neutral, name: agent.item.name, server: agent.server,
                        badge: held.map { ("\($0.multiplayerDisplay) has control", "hand.point.up.left", Tone.attention) }
                            ?? (count == 0 ? ("Not shared", nil, Tone.neutral) : ("Shared with \(count)", nil, Tone.working)),
                        chip: nil, owner: nil,
                        verbs: [
                            MultiplayerRowVerb(id: "share", title: "Share…", isEnabled: !isBusy, hint: "Share \(name)") { onShare(agent) },
                            MultiplayerRowVerb(id: "control", title: "Control", isEnabled: count > 0,
                                            hint: count > 0 ? "Hand over control of \(name)" : "Share \(name) before handing over control") { onControl(agent) },
                            MultiplayerRowVerb(id: "audit", title: "Audit", hint: "Audit for \(name)") { onAudit(agent) },
                        ])
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Friends’ agents", count: theirs.isEmpty ? nil : "\(theirs.count)") {
                    serverMenu("Fan out", fanoutServers, help: "Send one prompt to several workers", action: onFanout)
                    serverMenu("Directory", MultiplayerUnique.keep(theirs.map(\.server)) { $0 }, help: "Everything friends offer",
                               action: onDirectory)
                }
                if theirs.isEmpty {
                    Text("When a friend publishes an agent, it shows up here with what runs it and what it offers.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(theirs) { agent in
                    let entry = agent.item
                    let name = entry.name.multiplayerDisplay
                    let waiting = isWaiting(agent)
                    row(tone: entry.granted.isEmpty ? .neutral : .working, name: entry.name, server: agent.server,
                        badge: entry.granted.isEmpty ? (waiting ? ("Request waiting", "clock", Tone.attention) : ("Offered", nil, Tone.neutral))
                                                     : ("Granted", "checkmark", Tone.working),
                        chip: entry.capabilities, owner: entry.owner,
                        verbs: [
                            entry.canConsult ? MultiplayerRowVerb(id: "consult", title: "Consult", isPrimary: true, isEnabled: !isBusy,
                                                               hint: "Consult \(name)") { onConsult(agent) } : nil,
                            entry.canHandOff ? MultiplayerRowVerb(id: "handoff", title: "Hand off", isEnabled: !isBusy,
                                                               hint: "Hand off a task to \(name)") { onHandOff(agent) } : nil,
                            entry.canWatch ? MultiplayerRowVerb(id: "watch", title: "Watch", hint: "Watch \(name) work") { onWatch(agent) } : nil,
                            entry.canReview ? MultiplayerRowVerb(id: "review", title: "Review", isEnabled: !isBusy,
                                                              hint: "Ask \(name) for a code review") { onReview(agent) } : nil,
                            !waiting && !entry.requestable.isEmpty
                                ? MultiplayerRowVerb(id: "request", title: entry.granted.isEmpty ? "Request access" : "Request more",
                                                  isEnabled: !isBusy, hint: "Request access to \(name)") { onRequest(agent) } : nil,
                        ].compactMap { $0 })
                }
            }
        }
    }

    /// A heading action that names a server: a button for one, a menu for several, nothing for none.
    @ViewBuilder private func serverMenu(_ title: String, _ servers: [String], help: String,
                                         action: @escaping (String) -> Void) -> some View {
        if servers.count == 1, let only = servers.first {
            Button(title) { action(only) }.buttonStyle(MultiplayerTrayButtonStyle()).help(help)
        } else if servers.count > 1 {
            Menu {
                ForEach(servers, id: \.self) { id in Button(serverName(id)) { action(id) } }
            } label: { Text(title) }
            .menuStyle(.button)
            .buttonStyle(MultiplayerTrayButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): choose a server")
        }
    }

    private func row(tone: Tone, name: String, server: String, badge: (text: String, symbol: String?, tone: Tone),
                     chip: MultiplayerCapabilities?, owner: String?, verbs: [MultiplayerRowVerb]) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            MultiplayerMark(symbol: "terminal", tone: tone, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name.multiplayerDisplay)
                            .font(MultiplayerTheme.name)
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        MultiplayerBadge(text: badge.text, symbol: badge.symbol, tone: badge.tone)
                            .fixedSize()
                    }
                    HStack(spacing: 6) {
                        if let chip, chip.headline != nil { MultiplayerAgentChip(capabilities: chip) }
                        MultiplayerSwatch(color: MultiplayerTheme.swatch(for: server))
                        Text(owner.map { "\($0.multiplayerDisplay) on \(serverName(server))" } ?? serverName(server))
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel([name.multiplayerDisplay, badge.text, chip?.headline,
                                     owner.map { "owned by \($0.multiplayerDisplay)" }, "on \(serverName(server))"]
                    .compactMap { $0 }.joined(separator: ", "))
                if !verbs.isEmpty { MultiplayerVerbStrip(verbs: verbs).padding(.top, 2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Directory and access requests

/// Friends' resources on one server: what each offers, what you hold, and what you can do next.
struct MultiplayerDirectoryPage: View {
    let entries: [MultiplayerDirectoryEntry]
    let isBusy: Bool
    /// The resource already has a request of yours waiting.
    let isWaiting: (String) -> Bool
    let onRequest: (MultiplayerDirectoryEntry) -> Void
    let onConsult: (MultiplayerDirectoryEntry) -> Void
    let onHandOff: (MultiplayerDirectoryEntry) -> Void

    private var owners: [String] { MultiplayerUnique.keep(entries.map(\.owner)) { $0 } }

    var body: some View {
        if entries.isEmpty {
            MultiplayerBand {
                Text("No friend on this server has published a resource yet. When one does, it shows up here with what it offers.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(owners, id: \.self) { owner in
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: owner.isEmpty ? "A friend" : owner.multiplayerDisplay)
                    ForEach(entries.filter { $0.owner == owner }) { entry in
                        card(entry)
                    }
                }
            }
        }
    }

    private func card(_ entry: MultiplayerDirectoryEntry) -> some View {
        MultiplayerWell {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    MultiplayerMark(symbol: MultiplayerResourceKind.symbol(for: entry.kind),
                                    tone: entry.granted.isEmpty ? .neutral : .working, size: 20)
                    Text(entry.name.multiplayerDisplay)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(MultiplayerResourceKind.title(for: entry.kind).multiplayerDisplay)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                if let capabilities = entry.capabilities {
                    VStack(alignment: .leading, spacing: 4) {
                        if capabilities.headline != nil { MultiplayerAgentChip(capabilities: capabilities) }
                        if !capabilities.tags.isEmpty {
                            Text(capabilities.tags.joined(separator: "  "))
                                .font(MultiplayerTheme.mono)
                                .foregroundStyle(.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Tools and environments: \(capabilities.tags.formatted(.list(type: .and)))")
                        }
                    }
                }
                let shown = entry.offered.filter { !MultiplayerSharePolicy.isCompanion($0) || entry.offered.count == 1 }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.self) { action in
                        let granted = entry.granted.contains(action)
                        HStack(spacing: 6) {
                            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 10.5))
                                .foregroundStyle(granted ? MultiplayerTheme.working : MultiplayerTheme.border)
                            Text(MultiplayerCapability.title(action))
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(granted ? AnyShapeStyle(MultiplayerTheme.foreground) : AnyShapeStyle(.inkSecondary))
                            Spacer(minLength: Space.s)
                            Text(granted ? "Granted to you" : "Offered")
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if shown.isEmpty {
                        Text("Offers no actions yet.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                }
                HStack(spacing: 6) {
                    if isWaiting(entry.id) {
                        MultiplayerBadge(text: "Request waiting", symbol: "clock")
                    }
                    Spacer(minLength: 0)
                    if !entry.requestable.isEmpty, !isWaiting(entry.id) {
                        Button("Request access") { onRequest(entry) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: entry.granted.isEmpty ? .primary : .standard))
                            .disabled(isBusy)
                            .accessibilityLabel("Request access to \(entry.name.multiplayerDisplay)")
                    }
                    if entry.canHandOff {
                        Button("Hand off") { onHandOff(entry) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                            .disabled(isBusy)
                            .accessibilityLabel("Hand off a task to \(entry.name.multiplayerDisplay)")
                    }
                    if entry.canConsult {
                        Button("Consult") { onConsult(entry) }
                            .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                            .disabled(isBusy)
                            .accessibilityLabel("Consult \(entry.name.multiplayerDisplay)")
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Asks the owner for some of what a resource offers, with a line saying why.
struct MultiplayerRequestAccessPage: View {
    let entry: MultiplayerDirectoryEntry
    @Binding var draft: MultiplayerAccessDraft

    var body: some View {
        MultiplayerEditorTemplate(title: "Ask \(entry.owner.multiplayerDisplay) for \(entry.name.multiplayerDisplay)",
                                  intro: "They get a request in Needs you and decide the limits. Nothing is shared until they grant it.") {
            MultiplayerField(label: "Actions") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.requestable, id: \.self) { action in
                        MultiplayerActionCheck(action: action, detail: nil, isOn: draft.actions.contains(action)) {
                            if draft.actions.contains(action) { draft.actions.remove(action) } else { draft.actions.insert(action) }
                        }
                    }
                }
            }
            MultiplayerField(label: "Note", hint: "Optional. Say what you want to use it for.", problem: draft.problem) {
                MultiplayerTextField(label: "Note", placeholder: "Run the relay tests before I merge", text: $draft.note)
            }
        }
    }
}

/// Requests friends sent you, and the ones you sent.
struct MultiplayerAccessRequestsPage: View {
    let incoming: [MultiplayerAccessRequest]
    let outgoing: [MultiplayerAccessRequest]
    let resourceName: (String) -> String
    let color: Color
    let now: Date
    let isBusy: Bool
    let onReview: (MultiplayerAccessRequest) -> Void
    let onDecline: (MultiplayerAccessRequest) -> Void
    let onWithdraw: (MultiplayerAccessRequest) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Sent to you", count: incoming.isEmpty ? nil : "\(incoming.count)")
                if incoming.isEmpty {
                    empty("No one is waiting on you.")
                }
                ForEach(incoming) { request in
                    MultiplayerDecisionRow(color: color,
                                           title: "\(request.requester.multiplayerDisplay) asks for \(resourceName(request.resource).multiplayerDisplay)",
                                           detail: Self.detail(request), declineTitle: "Decline", acceptTitle: "Review",
                                           isBusy: isBusy,
                                           onOpen: { onReview(request) },
                                           onDecline: { onDecline(request) },
                                           onAccept: { onReview(request) })
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                MultiplayerBandHeading(title: "Sent by you", count: outgoing.isEmpty ? nil : "\(outgoing.count)")
                if outgoing.isEmpty {
                    empty("Ask for access from the shared directory.")
                }
                ForEach(outgoing) { request in
                    HStack(alignment: .top, spacing: Space.s) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(resourceName(request.resource).multiplayerDisplay), from \(request.owner.multiplayerDisplay)")
                                .font(MultiplayerTheme.name)
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .lineLimit(1)
                            Text("\(request.actionsTitle), \(MultiplayerActivityRow.time(request.createdAt, now: now))")
                                .font(MultiplayerTheme.sub)
                                .foregroundStyle(.inkSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        if request.isPending {
                            Button("Withdraw") { onWithdraw(request) }
                                .buttonStyle(MultiplayerTrayButtonStyle())
                                .disabled(isBusy)
                                .accessibilityLabel("Withdraw your request for \(resourceName(request.resource).multiplayerDisplay)")
                        } else {
                            stateText(request.statusTitle, request.status == "granted" ? .working : .neutral)
                        }
                    }
                    .frame(minHeight: 32)
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).padding(.vertical, 4)
    }

    static func detail(_ request: MultiplayerAccessRequest) -> String {
        let note = MultiplayerText.clean(request.note, limit: 140, redact: true)
        return note.isEmpty ? request.actionsTitle : "\(request.actionsTitle). “\(note)”"
    }
}

// MARK: - Approval (state f)

/// One request under Ask each time: who, what they want to run, and the grant it runs under.
struct MultiplayerApprovalPage: View {
    let approval: MultiplayerApproval
    let serverName: String
    let color: Color
    let resourceName: String
    let kind: String
    /// The grant the request runs under, when status lists it.
    let grant: MultiplayerGrant?
    let now: Date

    var body: some View {
        if approval.isSuggestion { suggestion } else { request }
    }

    /// A Co-pilot suggestion: the text a friend wants your worker to see, and what approving does.
    @ViewBuilder private var suggestion: some View {
        let who = approval.peer.isEmpty ? "Your friend" : approval.peer.multiplayerDisplay
        let worker = resourceName.multiplayerDisplay
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                row("From") {
                    HStack(spacing: 5) {
                        Text(who)
                        Text("on").foregroundStyle(.inkSecondary)
                        MultiplayerSwatch(color: color)
                        Text(serverName)
                    }
                }
                row("For") { Text("\(MultiplayerResourceKind.title(for: kind)) \(worker)") }
                MultiplayerWell(edge: MultiplayerTheme.attention.opacity(0.5)) {
                    VStack(alignment: .leading, spacing: 5) {
                        MultiplayerBadge(text: "Suggested message", symbol: "lightbulb", tone: .attention)
                        Text(approval.request.isEmpty ? "The suggestion carried no text." : approval.request)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("Suggested message: \(approval.request)")
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "If you approve")
                Text("\(worker) gets this text as a message from you and answers it. \(who) sees only the answer. Deny, and \(who) is told it was denied.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                row("Arrived") { Text(MultiplayerActivityRow.time(approval.arrived, now: now)) }
                if let expires = approval.expires {
                    row("Answer by") { Text(MultiplayerTime.display(expires, now: now)) }
                }
                Text("Every suggestion waits for you, whatever the grant says, unless you hand over control.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var request: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                row("Who") {
                    HStack(spacing: 5) {
                        Text(approval.peer.isEmpty ? "A friend" : approval.peer.multiplayerDisplay)
                        Text("on").foregroundStyle(.inkSecondary)
                        MultiplayerSwatch(color: color)
                        Text(serverName)
                    }
                }
                row("Wants to") { Text(MultiplayerCapability.title(approval.action)) }
                row("On") { Text("\(MultiplayerResourceKind.title(for: kind)) \(resourceName.multiplayerDisplay)") }
                if !approval.request.isEmpty {
                    MultiplayerWell {
                        Text(approval.request)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(MultiplayerTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityLabel("The request: \(approval.request)")
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Grant")
                row("Approval") { MultiplayerBadge(text: MultiplayerApprovalMode.ask.title) }
                if let grant {
                    row("Limits") { Text(Self.limits(grant, now: now)) }
                }
                row("Arrived") { Text(MultiplayerActivityRow.time(approval.arrived, now: now)) }
                if let expires = approval.expires {
                    row("Answer by") { Text(MultiplayerTime.display(expires, now: now)) }
                }
                Text("It runs on this Mac with your provider account. \(approval.peer.isEmpty ? "Your friend" : approval.peer.multiplayerDisplay) sees the result, not your files. Unanswered requests expire by themselves.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(label)
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .frame(width: 72, alignment: .leading)
            value()
                .font(MultiplayerTheme.name)
                .foregroundStyle(MultiplayerTheme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    static func limits(_ grant: MultiplayerGrant, now: Date) -> String {
        var parts: [String] = []
        if let uses = grant.maxUses {
            parts.append(uses >= MultiplayerGrantLimits.usesRange.upperBound ? "Unlimited uses" : "Up to \(MultiplayerGrantLimits.usesTitle(uses))")
        }
        if let expiresAt = grant.expiresAt { parts.append("expires \(MultiplayerTime.display(expiresAt, now: now))") }
        return parts.isEmpty ? "As you set them" : parts.joined(separator: ", ")
    }
}

// MARK: - Grant sheet

/// Who gets what, and the owner's policy for it: approval, expiry, uses, token budget and who pays.
struct MultiplayerGrantSheet: View {
    @Binding var draft: MultiplayerShareDraft
    /// More than one only when the sheet was opened from the cockpit.
    let servers: [MultiplayerServerSummary]
    let friends: [MultiplayerFriend]
    let resources: [MultiplayerResource]
    let resource: MultiplayerShareResource?
    let companions: [String]
    let onServer: (String) -> Void
    let onResourceChange: () -> Void
    let onToggle: (String) -> Void
    @FocusState private var budgetFocused: Bool

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                if let target = draft.target {
                    MultiplayerWell {
                        HStack(spacing: Space.s) {
                            Image(systemName: MultiplayerResourceKind.symbol(for: target.kind)).foregroundStyle(.inkSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.summary).font(MultiplayerTheme.name).foregroundStyle(MultiplayerTheme.foreground)
                                Text(target.target.multiplayerDisplay)
                                    .font(MultiplayerTheme.mono)
                                    .foregroundStyle(.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if servers.count > 1 {
                        MultiplayerField(label: "Server") {
                            MultiplayerMenuField(label: "Server", placeholder: "Choose a server",
                                                 options: servers.map { ($0.id, $0.displayName) },
                                                 selection: Binding(get: { draft.server }, set: onServer))
                        }
                    }
                } else {
                    MultiplayerField(label: "Resource") {
                        MultiplayerMenuField(label: "Resource", placeholder: "Choose a resource",
                                             options: resources.map {
                                                 ($0.id, "\($0.name.multiplayerDisplay), \(MultiplayerResourceKind.title(for: $0.kind).lowercased())")
                                             },
                                             selection: $draft.resourceID)
                            .onChange(of: draft.resourceID) { onResourceChange() }
                    }
                }
                MultiplayerField(label: "Friend", hint: friends.isEmpty ? "No friends on this server yet." : nil) {
                    MultiplayerMenuField(label: "Friend", placeholder: "Choose a friend",
                                         options: friends.map { ($0.handle, $0.handle.multiplayerDisplay) },
                                         selection: $draft.handle)
                }
            }
        }
        if let resource {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: 2) {
                    MultiplayerBandHeading(title: "They can")
                    if resource.choices.isEmpty {
                        Text("\(resource.name.multiplayerDisplay) offers no actions to share.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                    }
                    ForEach(resource.choices, id: \.self) { action in
                        MultiplayerActionCheck(action: action,
                                               detail: draft.actions.contains(action)
                                                   ? MultiplayerCapability.explanation(action, resource: resource.name.multiplayerDisplay) : nil,
                                               isOn: draft.actions.contains(action)) { onToggle(action) }
                    }
                    if !companions.isEmpty {
                        Text("Also granted, so they can follow what they send: \(companions.map { MultiplayerCapability.title($0).lowercasedFirst }.formatted(.list(type: .and))).")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    if resource.isNew {
                        Text("This is the usual list for a \(MultiplayerResourceKind.title(for: resource.kind).lowercased()). Sharing adds it to this server first, then grants what it really offers.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
        }
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.m) {
                MultiplayerChoice(label: "Approval", options: MultiplayerApprovalMode.allCases, title: \.title,
                                  selection: $draft.approval, note: draft.approval.explanation)
                MultiplayerChoice(label: "Expires after", options: MultiplayerShareExpiry.allCases, title: \.title,
                                  selection: $draft.expiry)
                MultiplayerChoice(label: "Uses", options: MultiplayerShareUses.allCases, title: \.title,
                                  selection: $draft.uses, note: "Access ends at whichever limit is reached first.")
                MultiplayerField(label: "Token budget",
                                 hint: "Across all uses. Leave empty for no token limit. Counted when Commander reports a run’s tokens.",
                                 problem: draft.budgetProblem) {
                    HStack(spacing: Space.s) {
                        MultiplayerTextField(label: "Token budget", placeholder: "No limit", text: $draft.budgetText,
                                             monospaced: true, isFocused: budgetFocused)
                            .focused($budgetFocused)
                            .frame(width: 130)
                        Text("tokens").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary).accessibilityHidden(true)
                    }
                }
                MultiplayerChoice(label: "Cost", options: MultiplayerAttribution.allCases, title: \.title,
                                  selection: $draft.attribution, note: draft.attribution.explanation(handle: draft.handle))
            }
        }
    }
}

// MARK: - Consult and Hand off

/// One prompt to a friend's worker, the files that go with it, and what came back.
struct MultiplayerConsultPage: View {
    @Binding var draft: MultiplayerConsultDraft
    let entry: MultiplayerDirectoryEntry?
    let reply: MultiplayerSentRequest?
    let attachProblem: String?
    let onChoose: () -> Void
    let onDrop: ([URL]) -> Void
    let onDetach: (MultiplayerContextItem) -> Void
    let onThread: (MultiplayerSentRequest) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if let reply {
            MultiplayerBand {
                VStack(alignment: .leading, spacing: Space.s) {
                    MultiplayerBandHeading(title: reply.succeeded ? "Answer" : "No answer yet") {
                        Button("Open thread") { onThread(reply) }
                            .buttonStyle(MultiplayerTrayButtonStyle())
                    }
                    if reply.succeeded {
                        MultiplayerWell {
                            Text(reply.value?.readable ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(reply.refusal ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(MultiplayerRequestState.tone(reply.status) == .failure
                                             ? AnyShapeStyle(MultiplayerTheme.failure) : AnyShapeStyle(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        MultiplayerEditorTemplate(title: "Ask \(name)", intro: intro) {
            MultiplayerField(label: "Prompt") {
                MultiplayerTextArea(label: "Prompt", text: $draft.prompt, lines: 5)
                    .focused($focused)
            }
            MultiplayerContextField(items: draft.context, problem: attachProblem ?? draft.problem,
                                    onChoose: onChoose, onDrop: onDrop, onDetach: onDetach)
        }
        .onAppear { focused = true }
    }

    private var name: String {
        guard let entry else { return "a friend’s worker" }
        return "\(entry.owner.multiplayerDisplay)’s \(entry.name.multiplayerDisplay)"
    }

    private var intro: String {
        let base = "The worker answers with its own tools on your friend’s Mac. You get the answer; their files stay with them."
        guard let headline = entry?.capabilities?.headline else { return base }
        return "\(headline). \(base)"
    }
}

/// A task a friend's agent runs by itself: a title, the task, and the files it needs.
struct MultiplayerHandoffComposer: View {
    @Binding var draft: MultiplayerHandoffDraft
    let entry: MultiplayerDirectoryEntry?
    let attachProblem: String?
    let onChoose: () -> Void
    let onDrop: ([URL]) -> Void
    let onDetach: (MultiplayerContextItem) -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, task }

    var body: some View {
        MultiplayerEditorTemplate(title: "Hand off to \(entry.map { "\($0.owner.multiplayerDisplay)’s \($0.name.multiplayerDisplay)" } ?? "a friend’s agent")",
                                  intro: "Their Commander starts a new run for this task on their Mac. You follow it under Hand-offs, and nothing it produces is applied here until you choose to.") {
            MultiplayerField(label: "Title") {
                MultiplayerTextField(label: "Title", placeholder: "Fix flaky reconnect test", text: $draft.title,
                                     isFocused: focus == .title)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .task }
            }
            MultiplayerField(label: "Task", hint: "Say what done looks like. The agent has only this and the files below.") {
                MultiplayerTextArea(label: "Task", text: $draft.task, lines: 6)
                    .focused($focus, equals: .task)
            }
            MultiplayerContextField(items: draft.context, problem: attachProblem ?? draft.problem,
                                    onChoose: onChoose, onDrop: onDrop, onDetach: onDetach)
        }
        .onAppear { focus = .title }
    }
}

/// The hand-offs you sent on one server, newest first.
struct MultiplayerHandoffList: View {
    let rows: [MultiplayerSentRequest]
    let state: (MultiplayerSentRequest) -> (title: String, tone: Tone)
    let target: (MultiplayerSentRequest) -> String
    let now: Date
    let onOpen: (MultiplayerSentRequest) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 2) {
                if rows.isEmpty {
                    Text("You haven’t handed anything off on this server. Open the shared directory and choose Hand off on an agent you’ve been granted.")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    let state = state(row)
                    Button { onOpen(row) } label: {
                        HStack(spacing: Space.s) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title.isEmpty ? "Untitled hand-off" : row.title.multiplayerDisplay)
                                    .font(MultiplayerTheme.name)
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                    .lineLimit(1)
                                Text("\(target(row)), \(MultiplayerActivityRow.time(row.at, now: now))")
                                    .font(MultiplayerTheme.sub)
                                    .foregroundStyle(.inkSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            stateText(state.title, state.tone)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.inkSecondary)
                        }
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MultiplayerRowButtonStyle())
                    .accessibilityLabel("\(row.title.multiplayerDisplay), \(target(row)), \(state.title)")
                }
            }
        }
    }
}

/// One hand-off: its state, the report its run wrote, and the artifacts it left to apply.
struct MultiplayerHandoffDetail: View {
    let row: MultiplayerSentRequest
    let target: String
    let state: (title: String, tone: Tone)
    let report: MultiplayerHandoffReport?
    let now: Date
    let isBusy: Bool
    let onApply: (Int, MultiplayerArtifact) -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(row.title.isEmpty ? "Untitled hand-off" : row.title.multiplayerDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    stateText(state.title, state.tone)
                }
                MultiplayerSummaryLine(label: "Handed to", value: target)
                MultiplayerSummaryLine(label: "Sent", value: MultiplayerActivityRow.time(row.at, now: now))
                if let run = row.run { MultiplayerSummaryLine(label: "Run", value: run, monospaced: true) }
                if let updated = report?.updatedAt {
                    MultiplayerSummaryLine(label: "Checked", value: MultiplayerActivityRow.time(updated, now: now))
                }
                if row.run == nil, let refusal = row.refusal {
                    Text(refusal)
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(MultiplayerRequestState.tone(row.status) == .failure
                                         ? AnyShapeStyle(MultiplayerTheme.failure) : AnyShapeStyle(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let report {
            let text = report.report ?? report.summary
            if !text.isEmpty {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.s) {
                        MultiplayerBandHeading(title: report.report == nil ? "Latest summary" : "Result report")
                        MultiplayerWell { MultiplayerMarkdown(text: text) }
                    }
                }
            }
            if report.isResult {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: 2) {
                        MultiplayerBandHeading(title: "Artifacts", count: report.artifacts.isEmpty ? nil : "\(report.artifacts.count)")
                        if report.artifacts.isEmpty {
                            Text("The run left nothing to apply yet.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                        }
                        ForEach(Array(report.artifacts.enumerated()), id: \.offset) { index, artifact in
                            MultiplayerRow(symbol: artifact.symbol, title: artifact.name,
                                           monospacedTitle: artifact.kind == "branch",
                                           caption: "\(artifact.kindTitle). \(artifact.applyHint)") {
                                if let title = artifact.applyTitle {
                                    Button(title) { onApply(index, artifact) }
                                        .buttonStyle(MultiplayerTrayButtonStyle())
                                        .disabled(isBusy)
                                        .accessibilityLabel("\(title.replacingOccurrences(of: "…", with: "")) \(artifact.name.multiplayerDisplay)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Thread and audit

/// A request's comments, oldest first, and the field to add one.
struct MultiplayerThreadPage: View {
    /// One comment as VoiceOver reads it: "sam, agent, 2 min ago: text".
    static func spoken(_ comment: MultiplayerComment, now: Date) -> String {
        let who = comment.author.isEmpty ? (comment.isAgent ? "Agent" : "Someone") : comment.author.multiplayerDisplay
        let parts = [who, comment.isAgent && !comment.author.isEmpty ? "agent" : nil, MultiplayerActivityRow.time(comment.at, now: now)]
        return "\(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")): \(comment.text)"
    }

    let title: String
    let state: MultiplayerLoad<MultiplayerThread>
    @Binding var draft: String
    let now: Date
    let onRetry: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                if !title.isEmpty {
                    Text(title.multiplayerDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                switch state {
                case .loading: MultiplayerLoadNote(loading: "Reading the thread from the owner’s device…", failure: nil, onRetry: onRetry)
                case .failed(let message): MultiplayerLoadNote(loading: "", failure: message, onRetry: onRetry)
                case .loaded(let thread):
                    if thread.comments.isEmpty {
                        Text("No comments yet. Yours starts the thread.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                    }
                    ForEach(thread.comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: comment.isAgent ? "terminal" : "person")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.inkSecondary)
                                Text(comment.author.isEmpty ? (comment.isAgent ? "Agent" : "Someone") : comment.author.multiplayerDisplay)
                                    .font(MultiplayerTheme.heading)
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                if comment.isAgent { MultiplayerBadge(text: "Agent") }
                                Spacer(minLength: Space.s)
                                Text(MultiplayerActivityRow.time(comment.at, now: now))
                                    .font(MultiplayerTheme.sub)
                                    .foregroundStyle(.inkSecondary)
                            }
                            Text(comment.text)
                                .font(.system(size: 12))
                                .foregroundStyle(MultiplayerTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(Self.spoken(comment, now: now))
                        .multiplayerArriving()
                    }
                }
            }
            .multiplayerStreaming(state.value?.comments.count ?? 0)
        }
        MultiplayerBand {
            MultiplayerField(label: "Comment", hint: "Travels sealed to your friend’s device, like the request itself.") {
                MultiplayerTextArea(label: "Comment", text: $draft, lines: 3)
            }
        }
    }
}

/// Every use of a resource: who, what, when, how it ended and what it cost.
struct MultiplayerAuditPage: View {
    let state: MultiplayerLoad<[MultiplayerAuditEntry]>
    let resourceName: (String) -> String
    let now: Date
    let onRetry: () -> Void

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case .loading: MultiplayerLoadNote(loading: "Reading the audit log…", failure: nil, onRetry: onRetry)
                case .failed(let message): MultiplayerLoadNote(loading: "", failure: message, onRetry: onRetry)
                case .loaded(let entries):
                    if !entries.isEmpty {
                        let refused = entries.filter { $0.outcomeTone == .failure }.count
                        MultiplayerStatusStrip(cells: [
                            MultiplayerReadout(id: "runs", label: "requests", value: "\(entries.count)"),
                            MultiplayerReadout(id: "tokens", label: "tokens", value: entries.reduce(0) { $0 + $1.tokens }.formatted()),
                            MultiplayerReadout(id: "refused", label: "refused", value: "\(refused)", tone: refused > 0 ? .failure : .neutral),
                        ])
                        .overlay { Rectangle().strokeBorder(MultiplayerTheme.hair) }
                        .padding(.bottom, 6)
                    }
                    if entries.isEmpty {
                        Text("Nothing has run yet. Each request a friend sends, and each one you send, is recorded here with its outcome.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Text("\(entry.peer.isEmpty ? "Someone" : entry.peer.multiplayerDisplay): \(MultiplayerCapability.title(entry.action).lowercasedFirst)")
                                    .font(MultiplayerTheme.name)
                                    .foregroundStyle(MultiplayerTheme.foreground)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                stateText(entry.outcomeTitle, entry.outcomeTone)
                            }
                            Text(Self.caption(entry, resourceName: resourceName, now: now))
                                .font(MultiplayerTheme.sub.monospacedDigit())
                                .foregroundStyle(.inkSecondary)
                                .lineLimit(1)
                            let summary = MultiplayerText.clean(entry.summary, limit: 200, redact: true)
                            if !summary.isEmpty {
                                Text(summary)
                                    .font(MultiplayerTheme.sub)
                                    .foregroundStyle(.inkSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    static func caption(_ entry: MultiplayerAuditEntry, resourceName: (String) -> String, now: Date) -> String {
        var parts = [resourceName(entry.resource).multiplayerDisplay, MultiplayerActivityRow.time(entry.started ?? entry.ended, now: now)]
        if let started = entry.started, let ended = entry.ended, ended > started {
            let seconds = Int(ended.timeIntervalSince(started).rounded())
            parts.append(seconds < 60 ? "\(max(seconds, 1)) s" : "\(seconds / 60) min")
        }
        if let tokens = entry.tokensTitle { parts.append(tokens) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Cockpit entry

/// "Share…" in the cockpit's worker and repository menus: opens the tray in its own window on the
/// grant sheet for that worker or repository.
@MainActor
enum MultiplayerShareLauncher {
    /// The menu action, or nil where this copy has no network helper.
    static func action(_ target: MultiplayerShareTarget) -> (() -> Void)? {
        guard !target.target.isEmpty, MultiplayerModel.shared.client != nil else { return nil }
        return { share(target) }
    }

    static func share(_ target: MultiplayerShareTarget, in model: MultiplayerModel = .shared) {
        MultiplayerLinkWindow.show(model)
        Task {
            // The window's first read may still be on its way: wait for a server that can take the share.
            for _ in 0..<40 where model.share.shareServers.isEmpty {
                if model.hasLoaded, !model.servers.contains(where: { $0.state == .online || $0.state == .connecting }) { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            model.share.startShare(target)
        }
    }
}
