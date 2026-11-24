import AppKit
import SwiftUI
import Synchronization

// CONSOLE RECORD FIELDS
// Every field behind one transcript entry, opened from that entry in Console and in Pretty mode.
//
//   Feature layer   ConsoleRecordDetail.resolve   the entry's message, tool call, results, worker, feed and run
//   Values          ConsoleRecordDetail           titled sections of JSON, each with its provenance
//                   ConsoleRecordAccess           how a console asks for one entry's fields
//   Molecules       RecordFieldRow                one field: its key, its value, and what can be done with it
//                   RecordDetailHost              the per-entry actions and the disclosure, on any entry view
//   Organism        RecordFieldsPanel             section choice, provenance, fields or JSON, copy
//
// A console asks by its own worker ID and an entry ID, and the answer is built from that worker's
// records only: the run's fields leave out other workers and the requests addressed to them.
// Nothing is fetched, opened or looked up on disk to show a field. A path or a link in a value
// stays text, to select and copy. Sections are read and written as `AGUIValue`, so a number keeps
// the literal the service wrote. Long values say how long they are and open in full; nothing is
// shortened without saying so.

// MARK: - Values

/// The fields behind one transcript entry, as sections of JSON text.
struct ConsoleRecordDetail: Equatable {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        /// Where these fields come from, as a sentence for the reader.
        let provenance: String
        /// The fields, as JSON text. Text that is not JSON is shown as written.
        let json: String
    }

    let title: String
    var sections: [Section]

    /// Every section as one JSON object keyed by section title, for the copy action. Each
    /// section is read as it is shown, so a number keeps the literal the service wrote.
    var combinedJSON: String {
        var object: [String: AGUIValue] = [:]
        for section in sections {
            object[section.title] = (try? AGUIValue(json: section.json)) ?? .string(section.json)
        }
        return AGUIValue.object(object).prettyText
    }
}

/// How a console reads the fields of one of its entries. The cockpit supplies it; a surface
/// without one shows the fields its entry holds.
struct ConsoleRecordAccess {
    /// The fields of an entry of one console, by the console's worker ID and the entry's ID.
    var detail: @MainActor (_ consoleID: String, _ entryID: String) -> ConsoleRecordDetail?
    var copy: @MainActor (String) -> Void = RecordPasteboard.copy
    /// Reads the media a user entry's prompt carried. Nil where nothing can be read.
    var attachments: PromptAttachmentIntents? = nil
    /// Opens a worker's Source inspector, for a message with media and no reference to it. Nil
    /// on a surface that hosts no inspector.
    var openSource: (@MainActor (_ workerID: String) -> Void)? = nil
}

private struct ConsoleRecordAccessKey: EnvironmentKey {
    static var defaultValue: ConsoleRecordAccess? { nil }
}

extension EnvironmentValues {
    var consoleRecordAccess: ConsoleRecordAccess? {
        get { self[ConsoleRecordAccessKey.self] }
        set { self[ConsoleRecordAccessKey.self] = newValue }
    }
}

extension View {
    /// Lets every console beneath this view read its entries' fields through the cockpit's
    /// action. Without that action the consoles show the fields their entries hold.
    func consoleRecordAccess(_ actions: CockpitActions,
                             openSource: (@MainActor (_ workerID: String) -> Void)? = nil) -> some View {
        environment(\.consoleRecordAccess, actions.recordDetail.map {
            ConsoleRecordAccess(detail: $0, attachments: actions.promptAttachments, openSource: openSource)
        })
    }
}

enum RecordPasteboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Feature layer

extension ConsoleRecordDetail {
    /// The fields behind one entry of a worker's transcript: its message, and for a tool call the
    /// call, its arguments as sent, and the result. The worker and its run follow, with every
    /// field the service sent. Only this worker's messages are searched.
    static func resolve(entryID: String, worker: Worker, run: Run) -> ConsoleRecordDetail? {
        let messages = worker.messages ?? []
        var sections: [Section] = []
        var title = "Record"
        var sources: [AGUISource] = []

        if let chunks = ConversationChunks.turn(entryID: entryID, in: messages) {
            // A turn joined from live chunks, in Console or Pretty: the turn, then each chunk's
            // own message.
            title = "Assistant turn"
            sections += turnSections(chunks)
            sources = chunks.flatMap(\.sources)
        } else if let message = messages.first(where: { $0.id == entryID }) {
            title = message.role == "tool" ? "Tool result" : "\(message.role.isEmpty ? "Message" : message.role.capitalized) message"
            sections.append(Section(id: "message", title: "Message", provenance: provenance(of: message),
                                    json: message.allFields.prettyText))
            sources = message.sources
        } else if let calling = messages.first(where: { ($0.toolCalls ?? []).contains { $0.id == entryID } }),
                  let call = calling.toolCalls?.first(where: { $0.id == entryID }) {
            title = "Tool call \(call.function.name)"
            sections.append(Section(
                id: "call", title: "Call",
                provenance: "The tool call as the service sent it, with every field. Arguments are listed as sent, and again as fields when they hold JSON.",
                json: call.allFields.prettyText))
            // Every result message that answers the call, oldest first. The entry's row shows the
            // last, which keeps the section ID `result` however many arrive before it.
            let results = messages.filter { $0.role == "tool" && $0.toolCallID == entryID }
            for (index, result) in results.enumerated() {
                let isLast = index == results.count - 1
                var origin = provenance(of: result)
                if results.count > 1 {
                    origin += isLast
                        ? " The last of \(results.count) results sent for this call, and the one its row shows."
                        : " Result \(index + 1) of \(results.count) sent for this call. A later result replaced it in the row."
                }
                sections.append(Section(
                    id: isLast ? "result" : "result:" + result.id,
                    title: results.count == 1 ? "Result" : "Result \(index + 1)",
                    provenance: origin, json: result.allFields.prettyText))
                sources += result.sources
            }
            sections.append(Section(id: "message", title: "Message", provenance: provenance(of: calling),
                                    json: calling.allFields.prettyText))
            sources = calling.sources + sources
        } else {
            return nil
        }

        if !sources.isEmpty {
            sections.append(Section(
                id: "sources", title: "Sources",
                provenance: "The provider records this entry was built from, oldest first. This console's source inspector reads the records themselves.",
                json: AGUIValue.array(sources.map(\.allFields)).prettyText))
        }
        let workerSent = !(worker.allFields.objectValue?.isEmpty ?? true)
        sections.append(Section(
            id: "worker", title: "Worker",
            provenance: workerSent
                ? "Every field of the worker as the service sent it. Its output chunks and messages are whole in the Feed section."
                : "The worker as this app holds it. It was not read from the service.",
            json: (workerSent ? worker.allFields : heldFields(worker)).prettyText))
        if let feed = feedSection(worker) { sections.append(feed) }
        let runSent = !(run.allFields.objectValue?.isEmpty ?? true)
        sections.append(Section(
            id: "run", title: "Run",
            provenance: runSent
                ? "Every field of the worker's run as the service sent it. Other workers are left out, and so are requests addressed to them."
                : "The worker's run as this app holds it. It was not read from the service.",
            json: (runSent ? scoped(run.allFields, to: worker.id) : heldFields(run, workerID: worker.id)).prettyText))
        return ConsoleRecordDetail(title: title, sections: sections)
    }

    /// The feed JSON last built for a few workers. A panel is read again on every render while
    /// it is open; a worker the feed has not touched since compares equal by its stamp and
    /// reuses its text. Nothing is built for a worker whose fields are not open.
    private static let feedCache = Mutex<[String: (worker: Worker, json: String)]>([:])
    private static let feedCacheLimit = 4

    /// The worker's two structural feed members under their wire names: `outputChunks` as the
    /// exact pieces in the order sent, unjoined, and `messages` with every field of each. Only
    /// this worker's. Nil when the worker has neither.
    private static func feedSection(_ worker: Worker) -> Section? {
        guard worker.outputChunks != nil || worker.messages != nil else { return nil }
        let json = feedCache.withLock { cache -> String in
            if let hit = cache[worker.id], hit.worker == worker { return hit.json }
            var members: [String: AGUIValue] = [:]
            if let chunks = worker.outputChunks { members["outputChunks"] = .array(chunks.map(AGUIValue.string)) }
            if let messages = worker.messages { members["messages"] = .array(messages.map(\.allFields)) }
            let json = AGUIValue.object(members).prettyText
            if cache.count >= feedCacheLimit, cache[worker.id] == nil { cache.removeAll() }
            cache[worker.id] = (worker, json)
            return json
        }
        return Section(
            id: "feed", title: "Feed",
            provenance: "This worker's console output as the chunks the feed sent, in order and unjoined, and its "
                + "messages with every field. The console joins the chunks with nothing between them. "
                + "No other worker's output or messages are here.",
            json: json)
    }

    /// A run's retained fields without what belongs to other workers. `allFields` already omits
    /// the workers themselves. `requests` holds every worker's questions and answers, so only
    /// those addressed to this worker stay, each whole.
    private static func scoped(_ runFields: AGUIValue, to workerID: String) -> AGUIValue {
        guard case .object(var members) = runFields, case .array(let requests)? = members["requests"] else {
            return runFields
        }
        members["requests"] = .array(requests.filter { $0["worker_id"]?.stringValue == workerID })
        return .object(members)
    }

    /// The fields an entry itself holds, for a surface with no record access.
    init(entry: TranscriptEntry) {
        var object: [String: AGUIValue] = ["id": .string(entry.id)]
        if entry.sourceIDs.count > 1 { object["messageIds"] = .array(entry.sourceIDs.map(AGUIValue.string)) }
        switch entry.kind {
        case .prose(let text, let fromUser):
            object["role"] = fromUser ? "user" : "assistant"
            object["content"] = .string(text)
        case .other(let role, let text):
            object["role"] = .string(role)
            object["content"] = .string(text)
        case .tool(let name, let detail, let result):
            object["tool"] = .string(name)
            if let detail { object["detail"] = .string(detail) }
            if let result {
                object["result"] = ["output": .string(result.output), "error": result.error.map(AGUIValue.string) ?? .null]
            }
        case .output(let result):
            object["role"] = "tool"
            object["content"] = .string(result.output)
            if let error = result.error { object["error"] = .string(error) }
        }
        self.init(title: "Entry", sections: [Section(
            id: "entry", title: "Entry",
            provenance: "The fields this view holds for the entry. The service's record is not available on this surface.",
            json: AGUIValue.object(object).prettyText)])
    }

    private static func provenance(of message: AGUIMessage) -> String {
        let base = "Commander's AG-UI message for this worker's console, with every field the service sent"
        guard let origin = message.sources.last else { return base + "." }
        var parts: [String] = []
        if !origin.source.isEmpty { parts.append("from the \(origin.source) source") }
        if !origin.kind.isEmpty { parts.append("kind \(origin.kind)") }
        if !origin.cursor.isEmpty { parts.append("cursor \(origin.cursor)") }
        return base + (parts.isEmpty ? "." : ". Projected " + parts.joined(separator: ", ") + ".")
    }

    /// The typed properties of a worker that was not read from the service, such as a sample.
    /// A worker from the service shows `allFields`.
    private static func heldFields(_ worker: Worker) -> AGUIValue {
        var fields: [String: AGUIValue] = [
            "id": .string(worker.id), "name": .string(worker.name), "role": .string(worker.role),
            "parent_id": .string(worker.parentID), "run_id": .string(worker.runID), "state": .string(worker.state),
            "host": .string(worker.host), "worktree": .string(worker.worktree), "task": .string(worker.task),
            "output": .string(worker.output), "message_count": .number(AGUINumber(worker.messages?.count ?? 0))
        ]
        if let error = worker.error { fields["error"] = .string(error) }
        if let client = worker.client { fields["client"] = .string(client) }
        if let branch = worker.branch { fields["branch"] = .string(branch) }
        if let createdAt = worker.createdAt { fields["created_at"] = .string(createdAt) }
        if let connection = worker.connection { fields["connection"] = .string(connection) }
        if let session = worker.nativeSession {
            fields["native_session"] = [
                "harness_instance": .string(session.harnessInstance), "session_id": .string(session.sessionID)
            ]
        }
        if let control = worker.control {
            var held: [String: AGUIValue] = [
                "held": .bool(control.held), "generation": .number(AGUINumber(control.generation))
            ]
            if let interrupt = control.interruptRequested { held["interrupt_requested"] = .bool(interrupt) }
            if let messages = control.messages {
                held["messages"] = .array(messages.map { ["id": .string($0.id), "status": .string($0.status)] })
            }
            if let capabilities = control.sessionCapabilities {
                var session: [String: AGUIValue] = [:]
                if let canInterrupt = capabilities.canInterrupt { session["can_interrupt"] = .bool(canInterrupt) }
                held["session_capabilities"] = .object(session)
            }
            fields["control"] = .object(held)
        }
        return .object(fields)
    }

    /// The typed properties of a run that was not read from the service, with the requests
    /// addressed to one worker. A run from the service shows `allFields`.
    private static func heldFields(_ run: Run, workerID: String) -> AGUIValue {
        var fields: [String: AGUIValue] = [
            "id": .string(run.id), "project": .string(run.project), "path": .string(run.path),
            "task": .string(run.task), "client": .string(run.client),
            "coordinator_id": .string(run.coordinatorID), "status": .string(run.status)
        ]
        if let title = run.givenTitle { fields["title"] = .string(title) }
        if let createdAt = run.createdAt { fields["created_at"] = .string(createdAt) }
        if let branch = run.branch { fields["branch"] = .string(branch) }
        if let requests = run.requests {
            fields["requests"] = .array(requests.filter { $0.workerID == workerID }.map { request in
                var item: [String: AGUIValue] = [
                    "id": .string(request.id), "worker_id": .string(request.workerID),
                    "question": .string(request.question), "status": .string(request.status),
                    "answer": .string(request.answer)
                ]
                if let delivery = request.delivery { item["delivery"] = .string(delivery) }
                return .object(item)
            })
        }
        return .object(fields)
    }
}

extension CockpitModel {
    /// The fields behind one transcript entry of one worker, from the state the app already holds.
    func recordDetail(workerID: String, entryID: String) -> ConsoleRecordDetail? {
        for run in runs {
            if let worker = run.workers?.first(where: { $0.id == workerID }) {
                return ConsoleRecordDetail.resolve(entryID: entryID, worker: worker, run: run)
            }
        }
        return nil
    }
}

extension TranscriptEntry {
    /// The entry as plain text, for the copy action.
    var plainText: String {
        switch kind {
        case .prose(let text, _), .other(_, let text):
            return text
        case .tool(let name, let detail, let result):
            return ([name + (detail.map { " " + $0 } ?? "")] + [result?.error, result?.output].compactMap { $0 }.filter { !$0.isEmpty })
                .joined(separator: "\n")
        case .output(let result):
            return [result.error, result.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

// MARK: - Field rows

/// One line of a record's fields: a key at its depth, and a value or the size of a container.
struct RecordField: Identifiable {
    enum Value {
        /// An object or array, with its summary such as `{4}` or `[2]`.
        case container(String)
        /// A number, a boolean or null, as JSON writes it.
        case literal(String)
        case string(String, length: Int)
        /// Data carried in the record, with its media type. Nil data is unreadable base64.
        case attachment(mediaType: String, data: Data?)
    }

    let id: Int
    let depth: Int
    let key: String
    /// The key path from the section root, such as `metadata.acp.cursor`.
    let path: String
    let value: Value

    /// Flattens JSON text into rows: every field as sent, and beneath a string that carries JSON,
    /// base64 beside a media type or a data URL, what it decodes to under the path segment
    /// `decoded`. `RecordFieldRows` does the reading.
    static func rows(json: String) -> [RecordField] {
        RecordFieldRows.rows(json: json)
    }
}

/// Parsed rows are kept while a panel is open, so a streaming transcript does not re-parse them.
@MainActor
private final class RecordFieldCache {
    static let shared = RecordFieldCache()

    private final class Box {
        let rows: [RecordField]
        init(_ rows: [RecordField]) { self.rows = rows }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 48
        return cache
    }()

    func rows(for json: String) -> [RecordField] {
        let key = json as NSString
        if let hit = cache.object(forKey: key) { return hit.rows }
        let rows = RecordField.rows(json: json)
        cache.setObject(Box(rows), forKey: key)
        return rows
    }
}

/// One field. The key and value are selectable text. A long string states its length and opens in
/// full. A path or a link is text like any other value: drawing a row reads nothing from disk and
/// opens nothing.
struct RecordFieldRow: View {
    let field: RecordField
    let size: CGFloat
    let copy: (String) -> Void

    /// Strings longer than this start shortened, and say so.
    private static let foldLength = 1_200
    private static let chunkLength = 4_000
    @State private var showsAll = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: field.key)
                .foregroundStyle(Term.cyan.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .help(field.path.isEmpty ? field.key : field.path)
            value
        }
        .font(Term.font(size))
        .padding(.leading, CGFloat(field.depth) * size)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let text = copyText {
                Button("Copy Value") { copy(text) }
            }
            if !field.path.isEmpty {
                Button("Copy Field Path") { copy(field.path) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var value: some View {
        switch field.value {
        case .container(let summary):
            Text(verbatim: summary).foregroundStyle(.inkTermDim)
        case .literal(let text):
            Text(verbatim: text).foregroundStyle(Term.amber).textSelection(.enabled)
        case .string(let text, let length):
            VStack(alignment: .leading, spacing: 3) {
                if length == 0 {
                    Text("empty text").foregroundStyle(.inkTermDim)
                } else if length <= Self.foldLength {
                    piece(text)
                } else if showsAll {
                    // Whole, in bounded pieces so one very long value still lays out.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.chunks(text), id: \.offset) { chunk in piece(chunk.text) }
                    }
                } else {
                    piece(String(text.prefix(Self.foldLength)))
                }
                if length > Self.foldLength {
                    HStack(spacing: 8) {
                        Text(verbatim: showsAll ? "\(length.formatted()) characters"
                             : "first \(Self.foldLength.formatted()) of \(length.formatted()) characters")
                            .foregroundStyle(.inkTermDim)
                        Button(showsAll ? "show less" : "show all") { showsAll.toggle() }
                            .buttonStyle(TermButtonStyle(ink: Term.cyan, size: size - 1))
                            .accessibilityLabel(showsAll ? "Show less of \(field.key)" : "Show all \(length) characters of \(field.key)")
                        Button("copy") { copy(text) }
                            .buttonStyle(TermButtonStyle(ink: Term.cyan, size: size - 1))
                            .accessibilityLabel("Copy all of \(field.key)")
                    }
                    .font(Term.font(size - 1))
                }
            }
        case .attachment(let mediaType, let data):
            SourceAttachmentView(mediaType: mediaType, data: data, size: size, copy: copy)
        }
    }

    private func piece(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(Term.text)
            .lineSpacing(size * 0.25)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyText: String? {
        switch field.value {
        case .string(let text, _), .literal(let text): text
        case .attachment(_, let data): data?.base64EncodedString()
        case .container: nil
        }
    }

    private static func chunks(_ text: String) -> [(offset: Int, text: String)] {
        var result: [(offset: Int, text: String)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkLength, limitedBy: text.endIndex) ?? text.endIndex
            result.append((result.count, String(text[start..<end])))
            start = end
        }
        return result
    }
}

// MARK: - Panel

/// The fields of one record: a choice of section, where the section comes from, and its fields as
/// rows or as the JSON itself. Everything is selectable and each section can be copied whole.
struct RecordFieldsPanel: View {
    enum Layout {
        /// Beneath its entry, with a bounded scroll area.
        case inline
        /// In a popover, at a fixed size.
        case popover
    }

    let detail: ConsoleRecordDetail
    var layout: Layout = .inline
    let copy: (String) -> Void
    let close: () -> Void

    @State private var selectedID: String?
    @State private var showsJSON = false

    private var section: ConsoleRecordDetail.Section? {
        detail.sections.first { $0.id == selectedID } ?? detail.sections.first
    }

    private var size: CGFloat { layout == .inline ? 11.5 : 11 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Term.rule).frame(height: 1)
            ScrollView(.vertical) {
                Group {
                    if let section {
                        if showsJSON {
                            RecordJSONText(json: section.json, size: size)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(RecordFieldCache.shared.rows(for: section.json)) { field in
                                    RecordFieldRow(field: field, size: size, copy: copy)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: layout == .inline ? 300 : .infinity)
            .id(section?.id)
        }
        .frame(width: layout == .popover ? 460 : nil, height: layout == .popover ? 400 : nil)
        .frame(maxWidth: layout == .inline ? 760 : nil, alignment: .leading)
        .background(Palette.well)
        .overlay {
            if layout == .inline { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.inkHairline, lineWidth: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: layout == .inline ? 8 : 0, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fields, \(detail.title)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: detail.title)
                    .font(TypeRole.label).foregroundStyle(Palette.foreground)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Button(showsJSON ? "fields" : "json") { showsJSON.toggle() }
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                    .help(showsJSON ? "Show these fields as rows" : "Show these fields as JSON")
                    .accessibilityLabel(showsJSON ? "Show as field rows" : "Show as JSON")
                if let section {
                    Button("copy") { copy(section.json) }
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10))
                        .help("Copy the whole \(section.title.lowercased()) section as JSON")
                        .accessibilityLabel("Copy the \(section.title) section as JSON")
                }
                if detail.sections.count > 1 {
                    Button("copy all") { copy(detail.combinedJSON) }
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10))
                        .help("Copy every section as one JSON object")
                        .accessibilityLabel("Copy every section as JSON")
                }
                SymbolButton(symbol: "xmark", label: "Close fields", size: 9, action: close)
                    .foregroundStyle(.inkSecondary)
            }
            if detail.sections.count > 1 {
                Picker("Section", selection: Binding(get: { section?.id ?? "" }, set: { selectedID = $0 })) {
                    ForEach(detail.sections) { section in
                        Text(section.title).tag(section.id)
                    }
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden()
                .accessibilityLabel("Section of \(detail.title)")
            }
            if let section {
                Text(verbatim: section.provenance)
                    .font(TypeRole.caption).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.disabled)
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 8)
        .background(Term.bar)
    }
}

/// JSON text in full, in bounded pieces of whole lines.
private struct RecordJSONText: View {
    let json: String
    let size: CGFloat

    var body: some View {
        let lines = json.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let step = 60
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stride(from: 0, to: lines.count, by: step)), id: \.self) { start in
                Text(verbatim: lines[start..<min(start + step, lines.count)].joined(separator: "\n"))
                    .font(Term.font(size)).lineSpacing(2)
                    .foregroundStyle(Term.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Per-entry host

/// Gives a transcript entry its actions and its fields. Console and Pretty both apply it, so an
/// entry offers the same copy action and the same fields in either mode. A roomy console opens the
/// fields beneath the entry; a wall tile and the PiP open them in a popover.
struct RecordDetailHost: ViewModifier {
    enum Face {
        /// Terminal transcript: a bracketed action at the entry's trailing edge.
        case terminal
        /// Pretty conversation: symbol actions. `below` keeps them on a line under the entry.
        case pretty(below: Bool)
    }

    @Environment(ConsoleModeStore.self) private var modes: ConsoleModeStore?
    @Environment(\.consoleRecordAccess) private var access
    @State private var localOpen = false
    @State private var hovered = false
    @FocusState private var actionsFocused: Bool

    let consoleID: String
    let entry: TranscriptEntry
    let face: Face
    let density: PrettyDensity

    private var inline: Bool { density == .regular }
    private var trailing: Bool { if case .pretty = face { return entry.isFromUser }; return false }

    private var isOpen: Bool {
        if inline, let modes { return modes.isDetailExpanded(console: consoleID, entry: entry.id) }
        return localOpen
    }

    private func setOpen(_ open: Bool) {
        if inline, let modes {
            modes.setDetailExpanded(open, console: consoleID, entry: entry.id)
        } else {
            localOpen = open
        }
    }

    private var copy: (String) -> Void { access?.copy ?? RecordPasteboard.copy }

    /// Read when the fields are shown, so an open panel follows the record as it changes.
    private var detail: ConsoleRecordDetail {
        access?.detail(consoleID, entry.id) ?? ConsoleRecordDetail(entry: entry)
    }

    func body(content: Content) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            switch face {
            case .pretty(below: true):
                content
                actions.opacity(isOpen || hovered || actionsFocused ? 1 : 0.62)
            case .pretty(below: false), .terminal:
                content.overlay(alignment: trailing ? .topLeading : .topTrailing) {
                    actions
                        .background(Term.background.opacity(0.92))
                        .opacity(isOpen || hovered || actionsFocused ? 1 : 0)
                }
            }
            if inline, isOpen {
                RecordFieldsPanel(detail: detail, layout: .inline, copy: copy, close: { setOpen(false) })
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy Text") { copy(entry.plainText) }
            Button(isOpen ? "Hide Fields" : "Show All Fields") { setOpen(!isOpen) }
        }
        .popover(isPresented: Binding(get: { !inline && localOpen }, set: { localOpen = $0 }), arrowEdge: .trailing) {
            RecordFieldsPanel(detail: detail, layout: .popover, copy: copy, close: { localOpen = false })
        }
    }

    @ViewBuilder private var actions: some View {
        switch face {
        case .terminal:
            Button(isOpen ? "hide fields" : "fields") { setOpen(!isOpen) }
                .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                .focused($actionsFocused)
                .help("Every field of this entry: the message, tool arguments and result, worker and run")
                .accessibilityLabel(isOpen ? "Hide this entry's fields" : "Show all fields of this entry")
        case .pretty:
            HStack(spacing: 2) {
                action("square.on.square", "Copy text") { copy(entry.plainText) }
                action(isOpen ? "curlybraces.square.fill" : "curlybraces.square",
                       isOpen ? "Hide fields" : "Show all fields") { setOpen(!isOpen) }
            }
            .focused($actionsFocused)
        }
    }

    private func action(_ symbol: String, _ label: String, perform: @escaping () -> Void) -> some View {
        let side: CGFloat = density == .regular ? 22 : 18
        return Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: density == .regular ? 12 : 10.5, weight: .medium))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.inkSecondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Adds the copy action and the fields disclosure of one transcript entry.
    func recordDetail(consoleID: String, entry: TranscriptEntry, face: RecordDetailHost.Face,
                      density: PrettyDensity) -> some View {
        // A user entry's attachments action sits on the entry itself, inside its other actions.
        modifier(PromptAttachmentHost(consoleID: consoleID, entry: entry, face: face, density: density))
            .modifier(RecordDetailHost(consoleID: consoleID, entry: entry, face: face, density: density))
    }
}
