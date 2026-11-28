import AppKit
import SwiftUI

// The MQTT Bridge plugin's panel in the Plugins mode: broker figures, the topic tree, the live
// message list and one payload (DESIGN.md "MQTT panel").
//
//   Molecules  MQTTTopicTreeRow     one level of the tree: disclosure, name, count
//              MQTTMessageRow       one message as a table row: time, topic, payload, size
//   Organisms  MQTTTopicBrowser      the tree on a panel, with "All topics" first
//              MQTTMessageList      the live list on a panel, with its state and Pause
//              MQTTPayloadInspector the chosen message: metadata, then the payload in a chosen form
//   Page       MQTTPanelPage        WorkspacePage: header, readout strip, NetworkSplit(tree + list | payload)
//
// The page takes an `MQTTContext` (values and intents). The feed (MQTTBridge.swift) owns the
// subscription and every read. The panel never publishes: "Open web UI" hands that to the bridge.

enum MQTTLayout {
    static let treeWidth: CGFloat = 248
    /// The least the message list can take: time, a topic, a payload and the size.
    static let listMinimum: CGFloat = 420
    /// The height of the tree and of the list. Each scrolls inside it.
    static let listHeight: CGFloat = 520
    static let indent: CGFloat = 14
    static let columns = [ShellColumn(title: "Time", width: 78), ShellColumn(title: "Topic"),
                          ShellColumn(title: "Payload"), ShellColumn(title: "Size", width: 58, alignment: .trailing)]
}

extension MQTTMessage {
    /// The time of day with milliseconds: "19:59:59.412".
    var clock: String {
        guard let time else { return "" }
        return time.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }

    var spoken: String {
        "\(topic), \(preview), \(MQTTPayload.byteCount(size))\(retain ? ", retained" : ""), at \(clock)"
    }
}

// MARK: - Molecules

/// One level of the topic tree. The name selects the node, which filters the list to the node
/// and everything under it; the chevron only opens and closes it.
struct MQTTTopicTreeRow: View {
    let row: MQTTTopicRow
    var isSelected = false
    let select: () -> Void
    let toggle: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: CGFloat(row.depth) * MQTTLayout.indent, height: 1)
            if row.hasChildren {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .foregroundStyle(.theme(\.color.secondary))
                        .frame(width: 16, height: theme.space.controlHeightLarge)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Close \(row.node.path)" : "Open \(row.node.path)")
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
            Button(action: select) {
                HStack(spacing: Space.s) {
                    Text(row.node.name.isEmpty ? "(empty)" : row.node.name).themeType(theme.type.data)
                        .foregroundStyle(.theme(row.node.isTopic || isSelected ? \.color.foreground : \.color.secondary))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    Text(row.node.total.formatted()).themeType(theme.type.label).monospacedDigit()
                        .foregroundStyle(.theme(\.color.secondary))
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, minHeight: theme.space.controlHeightLarge, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.node.path), \(row.node.total) messages")
            .accessibilityHint("Shows the messages on this topic and under it")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.horizontal, Space.s)
        .modifier(ShellSelectable(isSelected: isSelected))
        .animation(theme.motion.animation(theme.motion.fast), value: row.isExpanded)
        .accessibilityIdentifier("mqtt-topic-\(row.node.path)")
    }
}

/// One message in the live list.
struct MQTTMessageRow: View {
    let message: MQTTMessage
    var isSelected = false
    let select: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let columns = MQTTLayout.columns
        ShellTableRow(isSelected: isSelected, spoken: message.spoken, hint: "Shows the payload", select: select) {
            Text(message.clock).themeType(theme.type.fingerprint).monospacedDigit()
                .foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                .shellCell(columns[0])
            HStack(spacing: Space.xs + 1) {
                Text(message.topic).themeType(theme.type.data).foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1).truncationMode(.head)
                if message.retain { MultiplayerBadge(text: "Retained") }
            }
            .shellCell(columns[1])
            Text(message.preview).themeType(theme.type.mono)
                .foregroundStyle(.theme(message.encoding == .utf8 ? \.color.secondary : \.surface.softInk))
                .lineLimit(1).truncationMode(.tail)
                .shellCell(columns[2])
            ShellCellFigure(text: MQTTPayload.byteCount(message.size)).shellCell(columns[3])
        }
        .accessibilityIdentifier("mqtt-message-\(message.seq)")
    }
}

// MARK: - Organisms

/// The broker's topics as a tree. "All topics" is first and clears the filter.
struct MQTTTopicBrowser: View {
    let rows: [MQTTTopicRow]
    let total: Int
    let selectedPath: String?
    let actions: MQTTActions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellBandHeading(title: "Topics")
                .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
            ThemeRule()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    MQTTTopicTreeRow(row: MQTTTopicRow(node: MQTTTopicNode(path: "", name: "All topics", total: total, isTopic: true), depth: 0),
                                     isSelected: selectedPath == nil, select: { actions.select(nil) }, toggle: {})
                    ForEach(rows) { row in
                        MQTTTopicTreeRow(row: row, isSelected: row.node.path == selectedPath,
                                         select: { actions.select(row.node.path) }, toggle: { actions.toggle(row.node.path) })
                    }
                    if rows.isEmpty {
                        ShellNote(text: "No topic yet. Topics appear as clients publish.", lamp: .off)
                    }
                }
                .padding(Space.xs)
            }
        }
        .frame(width: MQTTLayout.treeWidth, height: MQTTLayout.listHeight, alignment: .topLeading)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Topics")
        .accessibilityIdentifier("mqtt-topic-tree")
    }
}

/// The live list: its state as a lamp and a word, the filter it follows, Pause, then the
/// messages newest first.
struct MQTTMessageList: View {
    let messages: [MQTTMessage]
    let filter: String?
    let link: MQTTBridgeFeed.Link
    let isPaused: Bool
    let heldCount: Int
    let shownSeq: Int?
    let actions: MQTTActions
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: (lamp: MultiplayerLamp.Kind, text: String, tone: Tone) {
        if link == .offline { return (.error, "Offline", .failure) }
        if link == .connecting { return (.waiting, "Connecting", .neutral) }
        if isPaused { return (.busy, heldCount > 0 ? "Paused · \(heldCount) new" : "Paused", .attention) }
        return (.on, "Live", .working)
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 0) {
            ShellBandHeading(title: "Messages", count: "\(messages.count)", note: filter ?? "every topic") {
                HStack(spacing: Space.m) {
                    MultiplayerStateLabel(lamp: state.lamp, text: state.text, tone: state.tone, pulses: link == .live && !isPaused)
                    Button { actions.setPaused(!isPaused) } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(ThemeButtonStyle(compact: true))
                    .help(isPaused ? "Show the messages that arrived while paused" : "Hold new messages so the list stands still")
                    .accessibilityIdentifier("mqtt-pause")
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
            ShellTableHeader(columns: MQTTLayout.columns)
            ThemeRule()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if messages.isEmpty {
                        ShellNote(text: filter == nil ? "No message recorded yet." : "No message recorded on \(filter ?? "").",
                                  lamp: .off)
                    }
                    ForEach(messages) { message in
                        MQTTMessageRow(message: message, isSelected: message.seq == shownSeq) { actions.show(message.seq) }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -theme.motion.travel)))
                        ThemeRule()
                    }
                }
                .animation(theme.motion.animation(theme.motion.standard), value: messages.first?.seq)
            }
        }
        .frame(minWidth: MQTTLayout.listMinimum, maxWidth: .infinity, minHeight: MQTTLayout.listHeight,
               maxHeight: MQTTLayout.listHeight, alignment: .topLeading)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Messages")
        .accessibilityIdentifier("mqtt-messages")
    }
}

/// One message read closely: where and how it was published, then its payload as indented JSON
/// when it parses, as text otherwise, and as hex or base64 for bytes.
struct MQTTPayloadInspector: View {
    let message: MQTTMessage
    /// The form the person chose. It is kept while they move between messages that offer it.
    @State private var chosen: MQTTPayload.Form?
    @Environment(\.theme) private var theme

    var body: some View {
        let payload = MQTTPayload(message)
        let form = chosen.flatMap { payload.forms.contains($0) ? $0 : nil } ?? payload.forms.first ?? .text
        NetworkInspector(title: message.topic.split(separator: "/").last.map(String.init) ?? message.topic,
                         serverName: message.topic,
                         note: "Read only. Publish from the bridge’s web UI.") {
            VStack(alignment: .leading, spacing: 0) {
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ThemeHeading(text: "Message").accessibilityAddTraits(.isHeader)
                        line("Topic", message.topic, mono: true)
                        if let time = message.time {
                            line("Time", time.formatted(date: .abbreviated, time: .omitted) + " " + message.clock, time: true)
                        }
                        line("QoS", "\(message.qos)", mono: true)
                        line("Retain", message.retain ? "Yes" : "No")
                        line("Size", message.truncated ? "\(MQTTPayload.byteCount(message.size)), cut short by the bridge" : MQTTPayload.byteCount(message.size), mono: !message.truncated)
                        line("Client", message.client.isEmpty ? "Unknown" : message.client, mono: !message.client.isEmpty)
                        line("Sequence", "\(message.seq)", mono: true)
                    }
                }
                MultiplayerBand {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            ThemeHeading(text: "Payload").accessibilityAddTraits(.isHeader)
                            Spacer(minLength: Space.s)
                            if payload.forms.count > 1 {
                                MultiplayerSegments(label: "Payload form", options: payload.forms, title: \.title,
                                                    selection: Binding(get: { form }, set: { chosen = $0 }))
                                    .frame(width: CGFloat(payload.forms.count) * 62)
                            }
                        }
                        if message.size == 0 {
                            Text("The payload is empty.").themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        } else {
                            MultiplayerOutputWell(text: payload.text(form), lines: 18)
                                .accessibilityLabel("Payload as \(form.title)")
                                .accessibilityIdentifier("mqtt-payload")
                        }
                    }
                }
            }
        } footer: {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload.text(form), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(ThemeButtonStyle())
            .disabled(message.size == 0)
            .help("Copy the payload as \(form.title)")
            .accessibilityIdentifier("mqtt-payload-copy")
        }
        .accessibilityIdentifier("mqtt-inspector")
    }

    private func line(_ label: String, _ value: String, mono: Bool = false, time: Bool = false) -> some View {
        MultiplayerSummaryLine(label: label, value: value, monospaced: mono, isTime: time)
            .textSelection(.enabled)
            .help(mono ? value : "")
    }
}

// MARK: - Page

struct MQTTPanelPage: View {
    var crumbs: [String] = ["Plugins", "Panels", "MQTT"]
    let context: MQTTContext
    @Environment(\.theme) private var theme

    private var summary: String {
        guard let status = context.status else {
            return context.isLoading ? "Reading the MQTT Bridge on this Mac…" : "What the MQTT Bridge on this Mac carries, read from \(MQTTBridge.address)."
        }
        let broker = status.mqttAddress.isEmpty ? "" : " Broker at \(status.mqttAddress)."
        let line = "MQTT Bridge \(status.version) on \(MQTTBridge.address).\(broker) \(status.messagesRecorded.formatted()) messages recorded"
        return context.link == .offline ? "\(line). The bridge stopped answering; this is what it last sent." : "\(line)."
    }

    static func readouts(_ status: MQTTStatus, link: MQTTBridgeFeed.Link) -> [ShellReadout] {
        var cells = [
            // The address is in the header's line: a figure cell is too narrow for it in a small window.
            ShellReadout(id: "broker", label: "broker", value: link == .offline ? "Offline" : "Running",
                         lamp: link == .offline ? .error : .on, tone: link == .offline ? .failure : .neutral,
                         spoken: "Broker at \(status.mqttAddress), \(link == .offline ? "not answering" : "running")"),
            ShellReadout(id: "uptime", label: "uptime", value: status.uptime),
            ShellReadout(id: "clients", label: "clients", value: status.clientsConnected.formatted()),
            ShellReadout(id: "subscriptions", label: "subscriptions", value: status.subscriptions.formatted()),
            ShellReadout(id: "received", label: "received", value: status.messagesReceived.formatted()),
            ShellReadout(id: "sent", label: "sent", value: status.messagesSent.formatted()),
            ShellReadout(id: "retained", label: "retained", value: status.retained.formatted()),
            ShellReadout(id: "topics", label: "topics", value: status.topics.formatted())
        ]
        if status.topicsDropped > 0 {
            cells.append(ShellReadout(id: "dropped", label: "topics dropped", value: status.topicsDropped.formatted(), tone: .attention))
        }
        return cells
    }

    var body: some View {
        WorkspacePage {
            PageHeader(kicker: crumbs.map { $0.uppercased() }.joined(separator: " / "), title: "MQTT", subtitle: summary) {
                Button { context.actions.openWebUI() } label: {
                    Label("Open web UI", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(ThemeButtonStyle())
                .help("Open the bridge’s own page at \(MQTTBridge.address), where messages are published")
                .accessibilityIdentifier("mqtt-open-web-ui")
            }
        } content: {
            if let status = context.status {
                ShellReadoutStrip(cells: Self.readouts(status, link: context.link), large: true)
                    .accessibilityIdentifier("mqtt-readouts")
                NetworkSplit {
                    HStack(alignment: .top, spacing: Space.l) {
                        MQTTTopicBrowser(rows: context.rows, total: context.total, selectedPath: context.selectedPath, actions: context.actions)
                        MQTTMessageList(messages: context.messages, filter: context.filter, link: context.link,
                                        isPaused: context.isPaused, heldCount: context.heldCount,
                                        shownSeq: context.shown?.seq, actions: context.actions)
                    }
                } inspector: {
                    if let message = context.shown {
                        MQTTPayloadInspector(message: message)
                    } else {
                        NetworkInspectorNote(text: "Choose a message to read its payload.")
                    }
                }
            } else if context.isLoading {
                ShellNote(text: "Reading the MQTT Bridge on this Mac…", lamp: .waiting).themePanel()
            } else {
                offline
            }
        }
        .accessibilityIdentifier("mqtt-page")
    }

    /// The bridge doesn't answer and nothing was ever read: say so calmly, and offer one way on.
    private var offline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellNote(text: "The MQTT Bridge isn’t answering at \(MQTTBridge.address). Start it with mqttbridge serve. Agent Commander keeps trying.",
                      lamp: .error)
            Button("Try again") { context.actions.retry() }
                .buttonStyle(ThemeButtonStyle())
                .padding(.horizontal, Space.m).padding(.bottom, theme.space.bandBottom)
                .accessibilityIdentifier("mqtt-retry")
        }
        .frame(maxWidth: 540, alignment: .leading)
        .themePanel()
        .accessibilityIdentifier("mqtt-offline")
    }
}
