import Foundation
import Observation
import SwiftUI

// REPLY ATTACHMENTS (DESIGN.md, "Pretty transcript"; spec section H, "ACP content blocks")
// An agent may send a resource link or an embedded text resource as one chunk of its reply. The
// service's message for that chunk holds only the content type, the MIME type and a marker; the
// chunk itself stays behind the message's live source cursor.
//
//   Values          ReplyAttachmentMark     what the message says: content type, cursor, turn
//                   ReplyAttachment         the link or the text the source record holds
//   Feature layer   ReplyAttachmentStore    one read of the source record per chunk
//   Boundary        ReplyAttachmentReader   the source read, as a closure
//   Molecules       ReplyLinkRow            the link: name, then title, type and size
//                   ReplyResourceQuote      the text, quoted beside the report rule
//
// Nothing is inferred. The link or the text is read only from the original ACP update at the
// message's exact cursor: an `agent_message_chunk` of this worker's session and turn whose content
// is the type the message states. The message's text, a neighbouring chunk, another record with
// the same address and another session are never read in its place. Until such a record is read,
// and when none is kept, the message keeps its place as a folded session update. Nothing is
// fetched: a link opens only on a click, through the transcript's link policy.

/// What the service's message says about one reply chunk that is a resource link or a resource.
struct ReplyAttachmentMark: Hashable, Sendable {
    enum Content: String, Sendable {
        case link = "resource_link"
        case resource
    }

    let content: Content
    /// The cursor of the chunk's source record in the worker's live source.
    let cursor: String
    /// The turn of that record, which narrows the read. Nil outside a turn.
    let turnID: String?

    /// Nil unless the message is one live reply chunk of one of the two content types: source
    /// `live`, kind `agent_message_chunk`, a cursor, and no tool call. A developer's message, a
    /// tool result, a chunk of another content type and a message that names several source
    /// records are not marked.
    init?(message: AGUIMessage, acp: [String: AGUIValue]) {
        guard message.role != "user", message.role != "tool", message.toolCallID == nil,
              message.toolCalls?.isEmpty ?? true,
              acp["source"]?.stringValue == ConversationChunks.liveSource,
              acp["kind"]?.stringValue == ConversationChunks.chunkKind,
              let content = acp["contentType"]?.stringValue.flatMap(Content.init(rawValue:)),
              let cursor = acp["cursor"]?.stringValue, !cursor.isEmpty,
              (message.metadata?["acpSources"]?.arrayValue?.count ?? 0) <= 1 else { return nil }
        self.content = content
        self.cursor = cursor
        turnID = acp["turnId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What the source record of one reply chunk holds.
enum ReplyAttachment: Equatable, Sendable {
    struct Link: Equatable, Sendable {
        /// The provider's name for the resource, exactly as sent.
        let name: String
        let uri: String
        var title: String? = nil
        var mimeType: String? = nil
        /// The size in bytes the provider states. Nil when it states none.
        var size: Int64? = nil
    }

    struct Resource: Equatable, Sendable {
        let uri: String
        var mimeType: String? = nil
        /// The embedded text, exactly as sent.
        let text: String
    }

    case link(Link)
    case resource(Resource)

    /// The SDK's type for an original `session/update` params object, and for an update alone.
    static let paramsType = "acp.session_update_params"
    static let updateType = "acp.session_update"
    /// Characters of embedded text drawn. A longer text keeps the fallback.
    static let textLimit = 512 << 10

    /// The attachment of the chunk `mark` names, from the pages read for it. Nil unless exactly
    /// one record sits at the mark's cursor and it is that chunk's original update.
    static func find(_ mark: ReplyAttachmentMark, in observations: [SourceObservation]) -> ReplyAttachment? {
        let matches = observations.filter { $0.cursor == mark.cursor }
        guard matches.count == 1, let observation = matches.first else { return nil }
        return ReplyAttachment(observation: observation, mark: mark)
    }

    /// Reads one source record. Nil unless it states its session, sits at the mark's cursor and
    /// turn, and carries the original update of an `agent_message_chunk` whose content is the
    /// marked type with the members that type requires.
    init?(observation: SourceObservation, mark: ReplyAttachmentMark) {
        guard observation.cursor == mark.cursor, let session = observation.session, !session.sessionID.isEmpty,
              observation.turnID == (mark.turnID ?? ""),
              let envelope = try? AGUIValue(json: observation.record) else { return nil }
        // A record that names another record as its original is not this chunk's.
        if let owner = envelope["sourceCursor"]?.stringValue, !owner.isEmpty, owner != mark.cursor { return nil }
        guard let source = (envelope["sourceRecord"] ?? envelope["extension"])?.objectValue,
              SourceAttachment.baseType(source["mediaType"]?.stringValue ?? "") == "application/json",
              let encoded = source["data"]?.stringValue, !encoded.isEmpty,
              let data = RecordBase64.decode(encoded[...].utf8),
              let original = try? AGUIValue(json: data) else { return nil }
        let update: AGUIValue
        switch source["type"]?.stringValue {
        case Self.paramsType?:
            // The provider's notification names its session: it must be this worker's.
            guard original["sessionId"]?.stringValue == session.sessionID, let inner = original["update"] else { return nil }
            update = inner
        case Self.updateType?:
            update = original
        default:
            return nil
        }
        guard update["sessionUpdate"]?.stringValue == ConversationChunks.chunkKind,
              let content = update["content"], content["type"]?.stringValue == mark.content.rawValue else { return nil }
        func optional(_ value: AGUIValue?) -> String? {
            value?.stringValue.flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil }
        }
        switch mark.content {
        case .link:
            guard let uri = optional(content["uri"]), let name = optional(content["name"]) else { return nil }
            let size = content["size"]?.numberValue?.int64Value.flatMap { $0 >= 0 ? $0 : nil }
            self = .link(Link(name: name, uri: uri, title: optional(content["title"]),
                              mimeType: optional(content["mimeType"]), size: size))
        case .resource:
            // A text resource only: a blob has no `text` and keeps the fallback.
            guard let resource = content["resource"], let uri = optional(resource["uri"]),
                  let text = resource["text"]?.stringValue, text.contains(where: { !$0.isWhitespace }),
                  text.utf8.count <= Self.textLimit else { return nil }
            self = .resource(Resource(uri: uri, mimeType: optional(resource["mimeType"]), text: text))
        }
    }
}

extension ReplyAttachment.Link {
    /// The address a click may open, under the transcript's link policy: a web link, or a file
    /// link, which is shown in Finder. Nil for every other scheme; the name is then plain text.
    var openable: URL? {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    /// The size the provider states, such as "72 bytes". It stays beside the name.
    var sizeText: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// The line under the name: the title when it says more than the name, then the type.
    func caption(hidesSecrets: Bool = false) -> String {
        var parts: [String] = []
        if let title, title != name { parts.append(ReplyAttachment.shown(title, hidesSecrets: hidesSecrets)) }
        if let mimeType { parts.append(mimeType) }
        return parts.joined(separator: ", ")
    }
}

extension ReplyAttachment.Resource {
    /// The line above the quoted text: where it is from, and its type.
    func caption(hidesSecrets: Bool = false) -> String {
        [ReplyAttachment.shown(uri, hidesSecrets: hidesSecrets), mimeType].compactMap { $0 }.joined(separator: ", ")
    }
}

extension ReplyAttachment {
    /// A provider's name, title or address as it is drawn, said by VoiceOver and shown as help:
    /// with the values that look like secrets hidden when the saved setting hides them. One text
    /// for all three, so help and VoiceOver never hold a value the row hides.
    static func shown(_ text: String, hidesSecrets: Bool) -> String {
        hidesSecrets ? SecretValues.masked(prose: text).text : text
    }
}

extension TranscriptEntry {
    /// The mark of a reply chunk that is a resource link or a resource. Nil for every other entry.
    var replyAttachment: ReplyAttachmentMark? {
        guard case .other = kind else { return nil }
        return origin?.replyAttachment
    }
}

/// One page of a worker's live source, narrowed to the mark's turn. `pageCursor` is the
/// `nextCursor` of the page before it, nil for the first.
typealias ReplyAttachmentReader = @Sendable (_ workerID: String, _ mark: ReplyAttachmentMark,
                                             _ pageCursor: String?) async throws -> SourcePage

/// The attachment of each marked reply chunk, read once from the chunk's own source record. It
/// follows `CompactionSummaryStore`: every surface that draws the chunk shares one read, the store
/// owns that read's task, and a change of service drops what the last service held.
@MainActor @Observable
final class ReplyAttachmentStore {
    private struct Key: Hashable {
        let worker: String
        let mark: ReplyAttachmentMark
    }

    private struct Read {
        let id: Int
        let task: Task<Void, Never>
    }

    /// What one read of a chunk's turn found at its cursor.
    enum Lookup: Equatable, Sendable {
        case found(ReplyAttachment)
        /// A record sits at the cursor and is not the chunk's original, or several do.
        case rejected
        /// No record sits at the cursor.
        case absent
    }

    /// The wait before the one further read of a chunk whose record was not there. The runner
    /// sends a chunk's message and its source record on separate requests, so the message may be
    /// drawn first.
    typealias Pause = @Sendable () async throws -> Void
    nonisolated static let rereadDelay = Duration.milliseconds(900)

    private var found: [Key: ReplyAttachment] = [:]
    /// Chunks with no usable record: rejected, or absent on both reads. Not asked for again.
    @ObservationIgnored private var missing: Set<Key> = []
    @ObservationIgnored private var reading: [Key: Read] = [:]
    @ObservationIgnored private var lastRead = 0
    @ObservationIgnored private let read: ReplyAttachmentReader
    @ObservationIgnored private let pause: Pause

    init(read: @escaping ReplyAttachmentReader,
         pause: @escaping Pause = { try await Task.sleep(for: ReplyAttachmentStore.rereadDelay) }) {
        self.read = read
        self.pause = pause
    }

    /// A store holding fixed values, for previews and renders. It reads nothing.
    init(fixed: [String: [ReplyAttachmentMark: ReplyAttachment]]) {
        pause = {}
        read = { _, _, _ in SourcePage(observations: [], nextCursor: nil) }
        for (worker, marks) in fixed {
            for (mark, attachment) in marks { found[Key(worker: worker, mark: mark)] = attachment }
        }
    }

    /// What the read of this chunk's record found. Nil until a read has found it.
    func attachment(worker: String, mark: ReplyAttachmentMark) -> ReplyAttachment? {
        found[Key(worker: worker, mark: mark)]
    }

    /// Reads the chunk's source record. Once found, or once known to be unusable, it is not read
    /// again. A record that is not there yet is read for once more after `pause`, and only then
    /// counted as missing. A failed or cancelled read is forgotten, so the chunk asks again when
    /// it is next drawn.
    ///
    /// Every surface that draws the chunk shares one read. The store runs it in its own task, so
    /// a surface that closes ends only its own wait.
    func load(worker: String, mark: ReplyAttachmentMark) async {
        let key = Key(worker: worker, mark: mark)
        guard !worker.isEmpty, found[key] == nil, !missing.contains(key) else { return }
        if let shared = reading[key] { return await shared.task.value }
        lastRead += 1
        let id = lastRead
        let task = Task { [weak self, read, pause] in
            let result: Result<Lookup, Error>
            do {
                var lookup = try await ReplyAttachmentStore.find(worker: worker, mark: mark, read: read)
                if lookup == .absent {
                    try await pause()
                    try Task.checkCancellation()
                    lookup = try await ReplyAttachmentStore.find(worker: worker, mark: mark, read: read)
                }
                result = .success(lookup)
            } catch {
                result = .failure(error)
            }
            // Only the read the store still holds for this chunk may finish it. One started
            // against the last service finds another read here, or none, and is dropped.
            guard let self, self.reading[key]?.id == id else { return }
            self.reading[key] = nil
            switch result {
            case .success(.found(let attachment)): self.found[key] = attachment
            case .success(.rejected), .success(.absent): self.missing.insert(key)
            case .failure: break
            }
        }
        reading[key] = Read(id: id, task: task)
        await task.value
    }

    /// Pages the mark's turn of the live source and reads the one record at its cursor.
    private nonisolated static func find(worker: String, mark: ReplyAttachmentMark,
                                         read: ReplyAttachmentReader) async throws -> Lookup {
        // Only the records at the cursor are kept from each page; every page is still read, so a
        // second record at the same cursor is seen.
        var matches: [SourceObservation] = []
        var cursor: String?
        for _ in 0..<CompactionSummaryStore.pageLimit {
            let page = try await read(worker, mark, cursor)
            try Task.checkCancellation()
            matches += page.observations.filter { $0.cursor == mark.cursor }
            guard let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        guard !matches.isEmpty else { return .absent }
        return ReplyAttachment.find(mark, in: matches).map(Lookup.found) ?? .rejected
    }

    /// Chunks read at once for one console.
    nonisolated static let concurrentReads = 2

    /// Reads every chunk of one console, latest first, `concurrentReads` at a time. `marks` are
    /// in the order sent. Each chunk keeps its own place in the conversation whenever it is read.
    func load(worker: String, marks: [ReplyAttachmentMark]) async {
        var pending = marks.reversed().makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.concurrentReads {
                guard let mark = pending.next() else { break }
                group.addTask { await self.load(worker: worker, mark: mark) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let mark = pending.next() else { continue }
                group.addTask { await self.load(worker: worker, mark: mark) }
            }
        }
    }

    /// The selected service changed: what the last one held is dropped and its reads in flight
    /// are cancelled and let go, so a chunk may be read from the new service at once.
    func serviceChanged() {
        for shared in reading.values { shared.task.cancel() }
        reading = [:]
        found = [:]
        missing = []
    }
}

extension ReplyAttachmentStore {
    /// The reader the live cockpit uses: the worker's live source, narrowed to the chunk's turn.
    static func live(reader: ServiceClient) -> ReplyAttachmentStore {
        ReplyAttachmentStore { workerID, mark, pageCursor in
            try await reader.workerHistory(workerID, source: .live, cursor: pageCursor, limit: 128, turnID: mark.turnID)
        }
    }
}

// MARK: - Molecules

/// A resource link in a reply: the provider's name as the transcript's link with its size
/// beside it, then its title and type beneath in secondary ink. The name and the size stay
/// whole in a narrow column: the size moves under the name before either is cut, and the title
/// and type wrap. A link of a scheme the link policy does not open is its name as text. The
/// address is the row's help, and it is never followed without a click. With "Hide values that
/// look like secrets" on, the name, title and address are drawn, said and shown as help with
/// those values hidden; a click still opens the address the provider sent.
struct ReplyLinkRow: View {
    @Environment(\.openURL) private var openURL

    let link: ReplyAttachment.Link
    let metrics: PrettyMetrics
    var hidesSecrets = false

    var body: some View {
        let name = ReplyAttachment.shown(link.name, hidesSecrets: hidesSecrets)
        let caption = link.caption(hidesSecrets: hidesSecrets)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "link").font(.system(size: metrics.detailSize - 1.5, weight: .medium))
                .foregroundStyle(.inkSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { title(name, wraps: false); size }
                    // A name wider than the column wraps, whole, with the size under it.
                    VStack(alignment: .leading, spacing: 2) { title(name, wraps: true); size }
                }
                if !caption.isEmpty {
                    Text(verbatim: caption).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .help(ReplyAttachment.shown(link.uri, hidesSecrets: hidesSecrets))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linked resource")
    }

    /// The name: the link, which is the row's one Tab stop, or text for a scheme that is not opened.
    @ViewBuilder private func title(_ name: String, wraps: Bool) -> some View {
        if let url = link.openable {
            PrettyLinkButton(title: name, size: metrics.bodySize, wraps: wraps) { openURL(url) }
                .accessibilityLabel(name)
                .accessibilityHint(url.isFileURL ? "Shows the file in Finder" : "Opens the link in the browser")
        } else {
            Text(verbatim: name).font(metrics.body).foregroundStyle(Palette.foreground)
                .fixedSize(horizontal: !wraps, vertical: true)
        }
    }

    @ViewBuilder private var size: some View {
        if let text = link.sizeText {
            Text(verbatim: text).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                .lineLimit(1).fixedSize()
        }
    }
}

/// An embedded text resource in a reply: where it is from, then its text exactly as sent,
/// quoted beside the report rule (`ResultQuote`). With "Hide values that look like secrets" on,
/// the quoted text has those values hidden and says how many.
struct ReplyResourceQuote: View {
    let resource: ReplyAttachment.Resource
    let metrics: PrettyMetrics
    var hidesSecrets = false

    var body: some View {
        let masked = hidesSecrets ? SecretValues.masked(prose: resource.text) : (resource.text, 0)
        let caption = resource.caption(hidesSecrets: hidesSecrets)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: caption)
                .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
            ResultQuote(text: masked.0, metrics: metrics, lines: metrics.density == .pip ? metrics.clampLines : 6)
            if masked.1 > 0 {
                Text(masked.1 == 1 ? "1 value hidden" : "\(masked.1) values hidden")
                    .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Embedded resource, " + caption)
    }
}
