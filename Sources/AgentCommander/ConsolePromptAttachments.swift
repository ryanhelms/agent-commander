import Observation
import SwiftUI

// PROMPT ATTACHMENTS
// The images and audio a developer's prompt carried, opened from that prompt's own entry in
// Console and in Pretty mode.
//
//   Values          PromptAttachmentReference   the worker and turn one prompt's media is read by
//                   PromptAttachmentOffer       what a user entry can offer: this prompt's media, or
//                                               the worker's source for a message without a reference
//                   PromptAttachmentItem        one record of the answer, decoded where it is media
//                   PromptAttachmentInspection  what the panel draws
//   Feature layer   PromptAttachmentModel       the one open read, its pages and its cancellation
//                   PromptAttachmentIntents     the operations the cockpit emits
//   Molecules       PromptAttachmentButton      "View attachment" on the entry, in either face
//                   PromptAttachmentRow         one item: its preview, and its fields on request
//   Organism        PromptAttachmentsPanel      provenance, items, gaps, errors, paging
//                   PromptAttachmentHost        puts the action and the panel on a user entry
//
// A prompt's media is read one of two ways, and the panel says which:
//
//   Live ACP source    a live prompt. The read names one worker and one turn, and asks the live
//                      source for that turn's prompt parts only. A record of any other turn fails
//                      the page instead of being drawn.
//   Provider history   a prompt recovered from Claude or Codex history. The read names the one
//                      provider record that owns the prompt, by its exact cursor, and the parts
//                      are decoded from that record alone; see `ProviderPromptMedia`. Any other
//                      record fails the read; no other record is tried in its place.
//
// Bytes are decoded on this Mac from the record; no URL is followed and no local file is read.
// Closing the panel, or showing another worker or prompt, abandons the read in flight and drops
// what was read.

// MARK: - Values

/// The address of one prompt's media. For a live prompt: a worker and the turn the service
/// recorded for the prompt. For a recovered prompt: a worker and the provider record that owns it.
/// It exists only for a user message whose `metadata.acp` is one of the agreed references.
struct PromptAttachmentReference: Hashable, Sendable {
    /// Where the prompt's media is read from.
    enum Origin: Hashable, Sendable {
        /// The live ACP records of the prompt's turn.
        case live
        /// The one provider history record that owns the prompt.
        case provider
    }

    static let source = ConsoleSourceKind.live
    static let kind = "acp.prompt_part"
    /// Records per page. A record carries a whole image or recording, so pages are short.
    static let pageLimit = 4

    let origin: Origin
    let workerID: String
    /// The turn of a live prompt. A recovered prompt may have none: historical Claude records
    /// often carry no turn.
    let turnID: String
    /// Live: the cursor of the first media part, as the message states it. Shown, never sent: a
    /// page is addressed by the worker, the turn and the cursor the service issues.
    /// Provider: the exact cursor of the record that owns the prompt. It is the record's address.
    let firstCursor: String
    /// Provider only: the opaque hint for the page that holds the record. Nil reads from the
    /// first page.
    let pageCursor: String?
    /// Provider only: the session the worker is bound to, when known. A record of another session
    /// is not this prompt's.
    let session: NativeSession?
    let contentType: String
    let mimeType: String
    /// How many media parts the message says the prompt carried. Nil when it does not say.
    let itemCount: Int?

    /// Nil unless the message is a user message whose reference is exactly one of the contracts:
    /// source `live`, kind `acp.prompt_part`, a turn, and a cursor of that turn when one is given;
    /// or source `provider`, kind `provider_prompt_media`, the owner record's cursor and a stated
    /// content type.
    /// - Parameter session: the worker's bound session, checked against a provider record.
    init?(workerID: String, message: AGUIMessage, session: NativeSession? = nil) {
        guard !workerID.isEmpty, message.role == "user",
              let acp = message.allFields["metadata"]?["acp"] else { return nil }
        let count = acp["itemCount"]?.intValue
        if let count, count < 1 { return nil }
        let cursor = acp["cursor"]?.stringValue ?? ""
        let turn = acp["turnId"]?.stringValue ?? ""
        switch (acp["source"]?.stringValue, acp["kind"]?.stringValue) {
        case (.some(Self.source.rawValue), .some(Self.kind)):
            guard !turn.isEmpty, cursor.isEmpty || cursor.hasPrefix("prompt-\(turn)-") else { return nil }
            origin = .live
            pageCursor = nil
            self.session = nil
        case (.some(ConsoleSourceKind.provider.rawValue), .some(ProviderPromptMedia.kind)):
            guard !cursor.isEmpty, let type = acp["contentType"]?.stringValue,
                  ProviderPromptMedia.contentTypes.contains(type) else { return nil }
            origin = .provider
            pageCursor = acp["pageCursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            self.session = session.flatMap { $0.sessionID.isEmpty ? nil : $0 }
        default:
            return nil
        }
        self.workerID = workerID
        turnID = turn
        firstCursor = cursor
        contentType = acp["contentType"]?.stringValue ?? ""
        mimeType = acp["mimeType"]?.stringValue ?? ""
        itemCount = count
    }

    /// The provenance label the panel shows.
    var provenance: String {
        switch origin {
        case .live: "Live ACP source"
        case .provider: "Provider history"
        }
    }
}

/// What a user entry offers for its attachments.
enum PromptAttachmentOffer: Equatable {
    /// The prompt's own media, read by its reference.
    case prompt(PromptAttachmentReference)
    /// A message that shows media parts and carries no reference. Its worker's source inspector is
    /// the place to look; nothing is inferred about which records are its own.
    case workerSource(workerID: String, count: Int)

    var title: String {
        switch self {
        case .prompt(let reference):
            switch reference.itemCount {
            case 1?: "View attachment"
            case let count?: "View \(count) attachments"
            case nil: "View attachments"
            }
        case .workerSource(_, let count):
            count == 1 ? "View attachment in Source…" : "View \(count) attachments in Source…"
        }
    }

    /// The offer for one entry of one worker's transcript. Only that worker's messages are read,
    /// and only a user message offers anything.
    /// - Parameter session: the worker's bound session, which a recovered prompt's record must
    ///   belong to. Nil when the worker has none or it is not known.
    static func resolve(workerID: String, entryID: String, messages: [AGUIMessage],
                        hasSource: Bool, session: NativeSession? = nil) -> PromptAttachmentOffer? {
        guard let message = messages.first(where: { $0.id == entryID }), message.role == "user" else { return nil }
        if let reference = PromptAttachmentReference(workerID: workerID, message: message, session: session) {
            return .prompt(reference)
        }
        let count = mediaPartCount(message.allFields["content"])
        return hasSource && count > 0 ? .workerSource(workerID: workerID, count: count) : nil
    }

    /// Content parts that are not text, counted the way the transcript shows them as bracketed lines.
    private static func mediaPartCount(_ content: AGUIValue?) -> Int {
        func isMedia(_ part: AGUIValue) -> Bool {
            guard let type = part["type"]?.stringValue else { return false }
            return type != "text"
        }
        switch content {
        case .array(let parts)?: return parts.filter(isMedia).count
        case .object?: return isMedia(content!) ? 1 : 0
        default: return 0
        }
    }
}

/// One item of a prompt's media. A live record that is the agreed JSON part is decoded, and so is
/// each media part of a provider record; a gap or any other record keeps the source's own
/// presentation.
struct PromptAttachmentItem: Identifiable, Equatable, Sendable {
    enum Body: Equatable, Sendable {
        /// `data` is nil when the part's base64 does not decode, and empty when it carries none.
        case media(type: String, mimeType: String, data: Data?)
        /// A media part of the prompt that is not drawn here: an external link, a file on another
        /// machine or held by the provider, or a part without data. `mimeType` is empty when the
        /// part does not state one. The reason is in words; the part's fields show it as recorded.
        case unavailable(type: String, mimeType: String, reason: String)
        /// A record that is not the agreed part, with the reason in words.
        case undecodable(String)
        /// A gap, or a record of another shape. `SourceRecordRow` draws it.
        case record
    }

    /// Unique within one read. A provider record yields several items, so an item's ID is its
    /// position, and two parts with the same bytes are still two items.
    let id: String
    /// The record the item was read from.
    let observation: SourceObservation
    let body: Body
    /// The item's own JSON as recorded: the live part before its bytes are decoded, or the
    /// selected part of the provider record.
    let decoded: String?
    /// What `decoded` is, as its well's caption.
    var decodedTitle = "decoded prompt part"

    init(id: String, observation: SourceObservation, body: Body, decoded: String?, decodedTitle: String) {
        self.id = id
        self.observation = observation
        self.body = body
        self.decoded = decoded
        self.decodedTitle = decodedTitle
    }

    init(observation: SourceObservation) {
        id = observation.id
        self.observation = observation
        guard case .attachment(_, let mediaType, let data) = observation.body else {
            body = .record
            decoded = nil
            return
        }
        guard SourceAttachment.baseType(mediaType) == "application/json" else {
            body = .undecodable("Its extension is \(mediaType.isEmpty ? "of no stated type" : mediaType), not a JSON prompt part.")
            decoded = nil
            return
        }
        guard let data, !data.isEmpty else {
            body = .undecodable(data == nil ? "Its extension data is not valid base64." : "Its extension carries no data.")
            decoded = nil
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        // A file the prompt linked or embedded: named and typed. Its contents stay out of the
        // decoded fields; the original record holds them.
        if let resource = (try? AGUIValue(json: text)).flatMap(PromptResourceSummary.init(part:)) {
            decoded = resource.redactedJSON
            decodedTitle = PromptResourceSummary.fieldsTitle
            body = .unavailable(type: resource.title, mimeType: resource.mimeType, reason: resource.statement)
            return
        }
        decoded = text
        guard let part = try? AGUIValue(json: text),
              let type = part["type"]?.stringValue, type == "image" || type == "audio",
              let mimeType = part["mimeType"]?.stringValue, !mimeType.isEmpty else {
            body = .undecodable("Its extension is JSON, but not an image or audio part with a media type.")
            return
        }
        let encoded = part["data"]?.stringValue ?? ""
        body = .media(type: type, mimeType: mimeType,
                      data: encoded.isEmpty ? Data() : Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    var isMedia: Bool {
        if case .media = body { return true }
        return false
    }

    /// A media part of the prompt, drawn or not. Counted against the message's stated count.
    var isPart: Bool {
        switch body {
        case .media, .unavailable: true
        case .undecodable, .record: false
        }
    }
}

/// The open read of one prompt's media, and the pages read so far.
struct PromptAttachmentInspection: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let reference: PromptAttachmentReference
    var phase: Phase = .loading
    var items: [PromptAttachmentItem] = []
    /// Cursor for the next page of this worker and turn. Nil at the end.
    var nextCursor: String? = nil
    var isLoadingMore = false
    /// Why the last request for a further page failed. The pages already read stay in place.
    var pageError: String? = nil

    var mediaCount: Int { items.filter(\.isMedia).count }
    /// Media parts read, including those that are not drawn here.
    var partCount: Int { items.filter(\.isPart).count }
}

enum PromptAttachmentError: LocalizedError, Equatable {
    case foreignTurn(String)
    /// A one-record read answered with no record, or with more than one.
    case recordCount(Int)
    /// A one-record read answered with a record at another cursor.
    case otherRecord(String)
    /// The answer does not name the worker's harness and session. The value is what it names.
    case otherSession(String)
    /// The record's `sourceCursor` names another owner: it is a sibling, not the prompt's record.
    case siblingRecord(String)
    /// A one-record read answered with a further page. The exact-record read has none.
    case furtherPage

    var errorDescription: String? {
        switch self {
        case .foreignTurn(let turn):
            "The service answered with a record of turn \(turn), which is not this prompt's turn. Nothing from that page is shown."
        case .recordCount(0):
            "The service answered with no record for this prompt."
        case .recordCount(let count):
            "The service answered with \(count) records. This prompt's media is read from its one record, so nothing is shown."
        case .otherRecord(let cursor):
            "The service answered with \(cursor.isEmpty ? "a record without a cursor" : "the record at \(cursor)"), which is not this prompt's record. Nothing from it is shown."
        case .otherSession(let session):
            "The service answered with a record of \(session), which is not this worker's harness and session. Nothing from it is shown."
        case .siblingRecord(let owner):
            "The service answered with a record that belongs to \(owner), not to this prompt's record. Nothing from it is shown."
        case .furtherPage:
            "The service answered a one-record read with a further page. Nothing is shown."
        }
    }
}

// MARK: - Feature model

/// Reads the media of the one prompt being viewed. A request is identified by its reference and a
/// generation number. Opening another prompt or closing starts a new generation and cancels the
/// request in flight, so a late answer is dropped and is never drawn on another worker or turn.
@Observable @MainActor
final class PromptAttachmentModel {
    typealias Loader = @Sendable (_ reference: PromptAttachmentReference, _ cursor: String?) async throws -> SourcePage

    private(set) var inspection: PromptAttachmentInspection?
    /// The request in flight. Read by tests; views read `inspection`.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let load: Loader
    @ObservationIgnored private var generation = 0

    init(load: @escaping Loader) {
        self.load = load
    }

    /// Opens a prompt's media and reads its first page. Opening the prompt that is already open
    /// keeps what was read.
    func open(_ reference: PromptAttachmentReference) {
        guard inspection?.reference != reference else { return }
        inspection = PromptAttachmentInspection(reference: reference)
        fetch(more: false)
    }

    /// Closes the open read and drops its records. With a reference, only that prompt's read is
    /// closed, so a surface that goes away cannot close a read another surface opened since.
    func close(_ reference: PromptAttachmentReference? = nil) {
        guard let current = inspection, reference == nil || current.reference == reference else { return }
        task?.cancel()
        task = nil
        generation += 1
        inspection = nil
    }

    /// Reads the next page of the open prompt. After a failed page it asks for that page again.
    func loadMore() {
        guard let current = inspection, current.phase == .loaded, current.nextCursor != nil,
              !current.isLoadingMore else { return }
        fetch(more: true)
    }

    /// Reads the open prompt again from its first page.
    func retry() {
        guard let current = inspection, current.phase != .loading, !current.isLoadingMore else { return }
        inspection = PromptAttachmentInspection(reference: current.reference)
        fetch(more: false)
    }

    private func fetch(more: Bool) {
        guard var current = inspection else { return }
        task?.cancel()
        generation += 1
        let token = generation
        let reference = current.reference
        let cursor = more ? current.nextCursor : nil
        if more {
            current.isLoadingMore = true
            current.pageError = nil
            inspection = current
        }
        task = Task { [load] in
            let result: Result<SourcePage, Error>
            do {
                let page = try await load(reference, cursor)
                // The request names one turn. A record that names another is not this prompt's.
                if reference.origin == .live,
                   let foreign = page.observations.first(where: { !$0.turnID.isEmpty && $0.turnID != reference.turnID }) {
                    throw PromptAttachmentError.foreignTurn(foreign.turnID)
                }
                result = .success(page)
            } catch {
                result = .failure(error)
            }
            // Only the request the panel is still waiting for may change what it shows.
            guard !Task.isCancelled, token == self.generation, var latest = self.inspection,
                  latest.reference == reference else { return }
            latest.isLoadingMore = false
            switch result {
            case .success(let page) where reference.origin == .provider:
                // One record, decoded whole. A read of one record has no further pages to follow.
                do {
                    latest.items = try ProviderPromptMedia.items(of: page, for: reference)
                    latest.nextCursor = nil
                    latest.phase = .loaded
                } catch {
                    latest.items = []
                    latest.phase = .failed(error.localizedDescription)
                }
            case .success(var page):
                let offset = more ? latest.items.count : 0
                for index in page.observations.indices {
                    page.observations[index].id = "prompt:\(offset + index)"
                }
                latest.items = Array(latest.items.prefix(offset)) + page.observations.map { PromptAttachmentItem(observation: $0) }
                // A repeated cursor would page forever.
                let next = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
                latest.nextCursor = next == cursor ? nil : next
                latest.phase = .loaded
            case .failure(let error):
                if more {
                    latest.pageError = error.localizedDescription
                } else {
                    latest.phase = .failed(error.localizedDescription)
                }
            }
            self.inspection = latest
        }
    }
}

/// The feature layer's attachment operations, as the cockpit emits them.
struct PromptAttachmentIntents {
    /// What one entry of one worker offers. Nil for an entry with nothing to view.
    var offer: @MainActor (_ workerID: String, _ entryID: String) -> PromptAttachmentOffer?
    /// The open read, if any. A surface draws it only when it is its own prompt's.
    var inspection: @MainActor () -> PromptAttachmentInspection?
    var open: @MainActor (PromptAttachmentReference) -> Void
    var close: @MainActor (PromptAttachmentReference) -> Void
    var loadMore: @MainActor () -> Void
    var retry: @MainActor () -> Void
}

extension PromptAttachmentModel {
    /// The reader the live cockpit uses. A live prompt reads the worker's live source, narrowed to
    /// the prompt's turn and to prompt parts. A recovered prompt reads the one provider record
    /// that owns it, by that record's cursor and the message's page hint only.
    static func live(reader: ServiceClient) -> PromptAttachmentModel {
        PromptAttachmentModel { reference, cursor in
            switch reference.origin {
            case .live:
                try await reader.workerHistory(reference.workerID, source: PromptAttachmentReference.source,
                                               cursor: cursor, limit: PromptAttachmentReference.pageLimit,
                                               turnID: reference.turnID, kind: PromptAttachmentReference.kind)
            case .provider:
                try await reader.workerRecord(reference.workerID, recordCursor: reference.firstCursor,
                                              pageCursor: reference.pageCursor)
            }
        }
    }
}

extension CockpitModel {
    /// The attachment operations over the state the app holds and this model's one open read.
    var promptAttachmentIntents: PromptAttachmentIntents {
        PromptAttachmentIntents(
            offer: { [self] workerID, entryID in
                for run in runs {
                    if let worker = run.workers?.first(where: { $0.id == workerID }) {
                        return PromptAttachmentOffer.resolve(workerID: workerID, entryID: entryID,
                                                             messages: worker.messages ?? [],
                                                             hasSource: worker.nativeSession != nil,
                                                             session: worker.nativeSession)
                    }
                }
                return nil
            },
            inspection: { [self] in attachments.inspection },
            open: { [self] reference in attachments.open(reference) },
            close: { [self] reference in attachments.close(reference) },
            loadMore: { [self] in attachments.loadMore() },
            retry: { [self] in attachments.retry() })
    }
}

// MARK: - Molecules

/// The action on a user entry. It is always drawn, in the entry's own face, so it reads as part
/// of the prompt: a bracketed terminal action in Console, a native bordered button in Pretty.
struct PromptAttachmentButton: View {
    let title: String
    let isOpen: Bool
    let face: RecordDetailHost.Face
    let density: PrettyDensity
    let help: String
    let action: () -> Void

    var body: some View {
        Group {
            switch face {
            case .terminal:
                Button(isOpen ? "hide attachments" : title.lowercased(), action: action)
                    .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.5))
            case .pretty:
                Button(action: action) {
                    Label(isOpen ? "Hide attachments" : title, systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .controlSize(density == .regular ? .small : .mini)
            }
        }
        .help(help)
        .accessibilityLabel(isOpen ? "Hide this prompt's attachments" : "\(title) of this prompt")
    }
}

/// One item of a prompt's media. An image of a trusted raster type is decoded from the record's
/// bytes; audio and other types are named and offered as data. The decoded part and the original
/// record open beneath as fields.
struct PromptAttachmentRow: View {
    let item: PromptAttachmentItem
    /// Position among the media items read so far, from 1. Nil for a record that is not media.
    let ordinal: Int?
    let total: Int?
    let isExpanded: Bool
    let toggle: () -> Void
    let copy: (String) -> Void

    private let size: CGFloat = 11.5

    var body: some View {
        switch item.body {
        case .record:
            // A gap and any other record keep the source inspector's own presentation.
            SourceRecordRow(observation: item.observation,
                            workerSession: item.observation.session ?? NativeSession(harnessInstance: "", sessionID: ""),
                            isExpanded: isExpanded, toggle: toggle, copy: copy)
        case .media(let type, let mimeType, let data):
            VStack(alignment: .leading, spacing: 5) {
                heading(glyph: "◆", ink: Term.violet, title: title(type),
                        detail: [mimeType, data.map(SourceAttachment.size) ?? "unreadable data"].joined(separator: " · "))
                VStack(alignment: .leading, spacing: 5) {
                    if type == "audio" {
                        note("Audio is not played here. Its type and size are stated, and its bytes can be copied.")
                    } else if !SourceAttachment.isTrustedRaster(mimeType) {
                        note("\(mimeType) is not a raster image type this app decodes.")
                    }
                    SourceAttachmentView(mediaType: mimeType, data: data, size: size, copy: copy)
                }
                .padding(.leading, size * 1.2)
                if isExpanded { fields }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        case .unavailable(let type, let mimeType, let reason):
            // A part the prompt carried that is not drawn here. It is stated, not an error.
            VStack(alignment: .leading, spacing: 5) {
                heading(glyph: "◇", ink: Term.amber, title: title(type),
                        detail: [mimeType.isEmpty ? "type not stated" : mimeType, "not shown"].joined(separator: " · "))
                Text(verbatim: reason + (item.decodedTitle == PromptResourceSummary.fieldsTitle
                                         ? " Its fields name the file without its contents."
                                         : " Its fields show the part as recorded."))
                    .font(Term.font(size - 0.5)).foregroundStyle(.inkTermDim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, size * 1.2)
                if isExpanded { fields }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(title(type)), not shown: \(reason)")
        case .undecodable(let reason):
            VStack(alignment: .leading, spacing: 5) {
                heading(glyph: "✗", ink: Term.red, title: "attachment not decoded", detail: "")
                Text(verbatim: reason + " Its fields show the record as sent.")
                    .font(Term.font(size)).foregroundStyle(Term.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, size * 1.2)
                if isExpanded { fields }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// The part's type and its place in the prompt, such as "image 2 of 3".
    private func title(_ type: String) -> String {
        (type.isEmpty ? "attachment" : type) + (ordinal.map { " \($0)" + (total.map { " of \($0)" } ?? "") } ?? "")
    }

    private func heading(glyph: String, ink: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(glyph + " ").foregroundStyle(ink).accessibilityHidden(true)
                Text(verbatim: title).fontWeight(.semibold).foregroundStyle(ink)
                if !detail.isEmpty {
                    Text(verbatim: "  " + detail).foregroundStyle(.inkTermDim).textSelection(.enabled)
                }
            }
            .font(Term.font(size)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(isExpanded ? "hide fields" : "fields", action: toggle)
                .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                .help("The decoded prompt part and the original record, field by field")
                .accessibilityLabel(isExpanded ? "Hide this attachment's fields" : "Show all fields of this attachment")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let decoded = item.decoded {
                PromptAttachmentFields(title: item.decodedTitle, json: decoded, size: size - 0.5, copy: copy)
            }
            // An attached file's record carries its contents, so it stays in the Source inspector.
            if item.decodedTitle != PromptResourceSummary.fieldsTitle {
                PromptAttachmentFields(title: recordCaption, json: item.observation.record, size: size - 0.5, copy: copy)
            }
        }
        .padding(.top, 2)
    }

    private var recordCaption: String {
        var parts = ["original record"]
        if !item.observation.cursor.isEmpty { parts.append("cursor \(item.observation.cursor)") }
        if !item.observation.turnID.isEmpty { parts.append("turn \(item.observation.turnID)") }
        return parts.joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(Term.font(size - 1)).foregroundStyle(.inkTermDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled well of one JSON value as field rows, whole and copyable. The rows are the shared
/// record rows, read once when the well opens.
private struct PromptAttachmentFields: View {
    let title: String
    let json: String
    let size: CGFloat
    let copy: (String) -> Void

    @State private var rows: [RecordField]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title)
                    .font(Term.font(10)).foregroundStyle(.inkTermDim)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button("copy json") { copy(json) }
                    .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10))
                    .help("Copy all of the \(title) as JSON")
                    .accessibilityLabel("Copy the \(title) as JSON")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Term.bar)
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(rows ?? []) { field in
                    RecordFieldRow(field: field, size: size, copy: copy)
                }
            }
            .padding(8)
        }
        .background(Palette.well)
        .overlay { Rectangle().strokeBorder(Term.rule, lineWidth: 1) }
        .task(id: json) { rows = RecordField.rows(json: json) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Organism

/// The media of one prompt: where it is read from, each item in the prompt's order, and paging
/// within the turn. Loading, a failure, an empty answer, a gap and a count that differs from the
/// message's are each stated in words.
struct PromptAttachmentsPanel: View {
    let inspection: PromptAttachmentInspection
    var layout: RecordFieldsPanel.Layout = .inline
    let copy: (String) -> Void
    let loadMore: () -> Void
    let retry: () -> Void
    let close: () -> Void

    /// Items whose fields are open, by item ID.
    @State private var expanded = Set<String>()

    private var reference: PromptAttachmentReference { inspection.reference }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Term.rule).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: layout == .inline ? 460 : .infinity, alignment: .topLeading)
                .background(Term.background)
            footer
        }
        .frame(width: layout == .popover ? 480 : nil, height: layout == .popover ? 480 : nil)
        .frame(maxWidth: layout == .inline ? 760 : nil, alignment: .leading)
        .background(Palette.well)
        .overlay {
            if layout == .inline { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.inkHairline, lineWidth: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: layout == .inline ? 8 : 0, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments of this prompt")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Attachments").font(TypeRole.label).foregroundStyle(Palette.foreground)
                Kicker(text: reference.provenance)
                    .accessibilityLabel("Read from \(reference.provenance)")
                Spacer(minLength: 6)
                SymbolButton(symbol: "xmark", label: "Close attachments", size: 9, action: close)
                    .foregroundStyle(.inkSecondary)
            }
            Text(verbatim: provenanceNote)
                .font(TypeRole.caption).foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: referenceLine)
                .font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(referenceLine)
        }
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 8)
        .background(Term.bar)
    }

    private var provenanceNote: String {
        switch reference.origin {
        case .live:
            "The image and audio parts of this prompt, from the live ACP records Commander holds for this worker and this turn. Decoded on this Mac from the record; no link is followed."
        case .provider:
            "The image and audio parts of this prompt, from the one record of the provider's history that holds it. Decoded on this Mac from that record; no link is followed and no file is opened."
        }
    }

    private var referenceLine: String {
        var parts: [String] = []
        switch reference.origin {
        case .live:
            parts.append("turn " + reference.turnID)
            if !reference.firstCursor.isEmpty { parts.append("cursor " + reference.firstCursor) }
        case .provider:
            parts.append("record " + reference.firstCursor)
            if !reference.turnID.isEmpty { parts.append("turn " + reference.turnID) }
        }
        if !reference.mimeType.isEmpty { parts.append(reference.mimeType) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        switch inspection.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("reading this prompt's attachments…").font(Term.font(11.5)).foregroundStyle(.inkTermDim)
            }
            .padding(12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading this prompt's attachments")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("✗ ").accessibilityHidden(true)
                    Text(verbatim: "could not read the attachments: \(message)").textSelection(.enabled)
                }
                .font(Term.font(11.5)).foregroundStyle(Term.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Could not read the attachments: \(message)")
                Button("retry", action: retry)
                    .buttonStyle(TermButtonStyle(ink: Term.bright))
                    .accessibilityLabel("Read the attachments again")
            }
            .padding(12)
        case .loaded:
            if inspection.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("○ ").accessibilityHidden(true)
                        Text(verbatim: emptyLine)
                    }
                    if inspection.nextCursor == nil, reference.origin == .live {
                        Text("Live records are a bounded, recent window. The worker's Source inspector shows what the provider kept.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(Term.font(11.5)).foregroundStyle(.inkTermDim)
                .padding(12)
            } else {
                list
            }
        }
    }

    private var list: some View {
        let ordinals = Self.ordinals(inspection.items)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(inspection.items) { item in
                    PromptAttachmentRow(item: item, ordinal: ordinals[item.id], total: reference.itemCount,
                                        isExpanded: expanded.contains(item.id),
                                        toggle: { toggle(item.id) }, copy: copy)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func ordinals(_ items: [PromptAttachmentItem]) -> [String: Int] {
        var result: [String: Int] = [:]
        for item in items where item.isPart { result[item.id] = result.count + 1 }
        return result
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: summary).font(Term.font(10.75)).foregroundStyle(.inkTermDim)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if inspection.phase == .loaded {
                if let error = inspection.pageError {
                    Text(verbatim: "! " + error).font(Term.font(10.75)).foregroundStyle(Term.amber)
                        .lineLimit(1).truncationMode(.tail)
                        .help(error)
                        .accessibilityLabel("The next page could not be read: \(error)")
                }
                if inspection.isLoadingMore {
                    Text("reading…").font(Term.font(10.75)).foregroundStyle(Term.cyan)
                        .accessibilityLabel("Reading the next page")
                } else if inspection.nextCursor != nil {
                    Button(inspection.pageError == nil ? "load more" : "retry", action: loadMore)
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.75))
                        .help("Read the next page of this prompt's attachments")
                        .accessibilityLabel("Load more of this prompt's attachments")
                } else {
                    if let shortfall {
                        Text(verbatim: shortfall).font(Term.font(10.75)).foregroundStyle(Term.amber)
                            .lineLimit(1).truncationMode(.tail)
                            .help(shortfall)
                    } else if !inspection.items.isEmpty {
                        Text("end of attachments").font(Term.font(10.75)).foregroundStyle(.inkTermDim)
                    }
                    Button("read again", action: retry)
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.75))
                        .help("Read this prompt's attachments again from the first page")
                        .accessibilityLabel("Read this prompt's attachments again")
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 27)
        .background(Term.bar)
        .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
    }

    private var emptyLine: String {
        switch reference.origin {
        case .live:
            inspection.nextCursor == nil ? "the live records hold no attachments for this turn" : "no attachments on this page"
        case .provider:
            "the provider record holds no attachments for this prompt"
        }
    }

    private var summary: String {
        guard inspection.phase == .loaded else { return "attachments" }
        let read = inspection.partCount
        if let total = reference.itemCount { return "\(read) of \(total) read" }
        return read == 1 ? "1 attachment read" : "\(read) attachments read"
    }

    /// At the end of the read, a count that differs from what the message states.
    private var shortfall: String? {
        guard let total = reference.itemCount, inspection.partCount != total else { return nil }
        // A gap or an undecodable record already says why the parts are not there.
        if reference.origin == .provider, !inspection.items.allSatisfy(\.isPart) { return nil }
        let source = reference.origin == .live ? "the live records returned" : "its provider record holds"
        return "the message states \(total); \(source) \(inspection.partCount)"
    }
}

// MARK: - Per-entry host

/// Puts the attachments action on a user entry, and the panel it opens: beneath the entry in a
/// roomy console, in a popover on a wall tile and the PiP. Console and Pretty both get it through
/// `recordDetail`, so the action and the panel are the same in either mode.
struct PromptAttachmentHost: ViewModifier {
    @Environment(\.consoleRecordAccess) private var access

    let consoleID: String
    let entry: TranscriptEntry
    let face: RecordDetailHost.Face
    let density: PrettyDensity

    /// Pretty draws a prompt's bubble at the trailing edge; an entry with no text keeps its row's
    /// leading place.
    private var trailing: Bool { if case .pretty = face { return entry.isFromUser }; return false }

    /// A developer's prompt, including one that carried only media and so has no text.
    private var isPrompt: Bool {
        if entry.isFromUser { return true }
        if case .other(let role, _) = entry.kind { return role == "user" }
        return false
    }

    func body(content: Content) -> some View {
        if isPrompt, let intents = access?.attachments, let offer = intents.offer(consoleID, entry.id) {
            switch offer {
            case .prompt(let reference):
                PromptAttachmentEntry(entry: content, offer: offer, reference: reference, intents: intents,
                                      copy: access?.copy ?? RecordPasteboard.copy, face: face, density: density,
                                      trailing: trailing)
            case .workerSource(let workerID, _):
                if let openSource = access?.openSource {
                    VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
                        content
                        PromptAttachmentButton(
                            title: offer.title, isOpen: false, face: face, density: density,
                            help: "This message has no attachment reference. Opens this worker's Source inspector, where its records can be read.",
                            action: { openSource(workerID) })
                    }
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                } else {
                    content
                }
            }
        } else {
            content
        }
    }
}

/// A user entry with a referenced prompt: the entry, its action, and the panel while it is open.
/// The panel is drawn only while the model's open read is this entry's own reference.
private struct PromptAttachmentEntry<Entry: View>: View {
    let entry: Entry
    let offer: PromptAttachmentOffer
    let reference: PromptAttachmentReference
    let intents: PromptAttachmentIntents
    let copy: (String) -> Void
    let face: RecordDetailHost.Face
    let density: PrettyDensity
    let trailing: Bool

    /// This surface asked for the panel. Another surface showing the same prompt stays closed.
    @State private var requested = false

    private var inline: Bool { density == .regular }

    private var inspection: PromptAttachmentInspection? {
        guard requested, let open = intents.inspection(), open.reference == reference else { return nil }
        return open
    }

    var body: some View {
        let inspection = inspection
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            entry
            PromptAttachmentButton(
                title: offer.title, isOpen: inspection != nil, face: face, density: density,
                help: reference.origin == .live
                    ? "The images and audio this prompt carried, read for this worker and turn only"
                    : "The images and audio this prompt carried, read from its own record in provider history",
                action: { inspection == nil ? open() : close() })
                .popover(isPresented: Binding(get: { !inline && inspection != nil },
                                              set: { if !$0 { close() } }),
                         arrowEdge: .trailing) {
                    if let inspection { panel(inspection, layout: .popover) }
                }
            if inline, let inspection {
                panel(inspection, layout: .inline)
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        // The entry now shows another worker or turn: the read for the old one ends.
        .onChange(of: reference) { old, _ in
            if requested { intents.close(old) }
            requested = false
        }
        // Another prompt was opened elsewhere, or the read was closed: this surface lets go.
        .onChange(of: inspection == nil) { _, gone in
            if gone { requested = false }
        }
        .onDisappear {
            if requested { intents.close(reference) }
            requested = false
        }
    }

    private func open() {
        requested = true
        intents.open(reference)
    }

    private func close() {
        requested = false
        intents.close(reference)
    }

    private func panel(_ inspection: PromptAttachmentInspection, layout: RecordFieldsPanel.Layout) -> some View {
        PromptAttachmentsPanel(inspection: inspection, layout: layout, copy: copy,
                               loadMore: intents.loadMore, retry: intents.retry, close: close)
    }
}
