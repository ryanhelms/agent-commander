import Foundation
import SwiftUI
import UniformTypeIdentifiers

// FOLLOW-UP FILE CONTEXT
// A file the developer attaches to the focused worker's follow-up, as an explicit link to a file
// in the worker's own local checkout or as a snapshot of the file's contents embedded in the
// message.
//
//   Values          WorkerPromptCapabilities   what the session accepts, from control.prompt_capabilities
//                   FollowUpContextScope       the worker a context is prepared for: host, checkout, capabilities
//                   FollowUpContextItem        one prepared file: what the composer shows and the part it sends
//                   FollowUpContentPart        one element of the request's `content`, in the service's shape
//                   FollowUpContent            the request body and its 1 MiB bound
//                   PromptResourceSummary      a recorded resource part, read for display without its contents
//   Feature layer   FollowUpContextReader      reads and canonicalizes the chosen file on this Mac
//   Molecules       FollowUpContextChip        the selected file's name, kind and size, with Remove
//                   FollowUpContextMenu        the composer's paperclip: Link file… and Embed snapshot…
//
// The request is `POST /v1/workers/{worker}/messages` with the same idempotency header as text:
//
//   { "generation": 7,
//     "content": [ { "type": "text", "text": "Please read this" },
//                  { "type": "resource_link", "uri": "file:///canonical/path", "name": "notes.txt",
//                    "mimeType": "text/plain" },
//                  { "type": "resource", "uri": "urn:commander:attachment:<uuid>",
//                    "mimeType": "application/octet-stream",
//                    "source": { "type": "data", "value": "<base64>" } } ] }
//
// A text-only follow-up keeps the original `{ "text", "generation" }` request. A link is offered
// only for a worker on this Mac and only for a regular file inside that worker's checkout, after
// symbolic links are resolved. A snapshot is the file's bytes as read now; text is sent literally.

// MARK: - Values

/// The prompt content a worker's session accepts beyond text. Each member the service leaves out
/// reads as not accepted.
struct WorkerPromptCapabilities: Decodable, Equatable, Sendable {
    var image = false
    var audio = false
    /// A `resource_link` part: a link to a file the agent reads itself.
    var resourceLink = false
    /// A `resource` part: the file's contents embedded in the prompt.
    var embeddedContext = false

    init(image: Bool = false, audio: Bool = false, resourceLink: Bool = false, embeddedContext: Bool = false) {
        self.image = image
        self.audio = audio
        self.resourceLink = resourceLink
        self.embeddedContext = embeddedContext
    }

    /// Reads the service's object. Both camel-case and snake-case member names are accepted.
    /// Nil when the value is not an object.
    init?(projection value: AGUIValue) {
        guard case .object(let fields) = value else { return nil }
        func flag(_ names: String...) -> Bool {
            names.contains { name in
                if case .bool(true)? = fields[name] { return true }
                return false
            }
        }
        self.init(image: flag("image"), audio: flag("audio"),
                  resourceLink: flag("resourceLink", "resource_link"),
                  embeddedContext: flag("embeddedContext", "embedded_context"))
    }

    init(from decoder: Decoder) throws {
        guard let value = Self(projection: try AGUIValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Prompt capabilities are not an object"))
        }
        self = value
    }

    /// True when the composer has any file context to offer.
    var acceptsFileContext: Bool { resourceLink || embeddedContext }
}

/// How a file joins a follow-up.
enum FollowUpContextKind: String, Equatable, Sendable {
    /// A `resource_link` to the file in the worker's checkout.
    case link
    /// A `resource` with the file's contents as read now.
    case snapshot

    var label: String {
        switch self {
        case .link: "link"
        case .snapshot: "snapshot"
        }
    }
}

/// The worker a file context is prepared for. Read from the worker's presentation.
struct FollowUpContextScope: Equatable, Sendable {
    let workerID: String
    /// The execution host. Empty or `localhost` is this Mac.
    let host: String
    /// The worker's checkout, as the service reports it.
    let checkout: String
    let capabilities: WorkerPromptCapabilities

    var isLocal: Bool { host.isEmpty || host == "localhost" }

    /// Why a link cannot be offered, in words. Nil when it can.
    var linkUnavailableReason: String? {
        if !capabilities.resourceLink { return "This session does not accept file links." }
        if !isLocal { return "A file link is offered only for a worker on this Mac. Embed a snapshot instead." }
        if checkout.isEmpty { return "This worker has no checkout to link a file from." }
        return nil
    }

    /// Why a snapshot cannot be offered, in words. Nil when it can.
    var snapshotUnavailableReason: String? {
        capabilities.embeddedContext ? nil : "This session does not accept embedded file contents."
    }
}

/// One element of a follow-up's `content`, in the order it is sent.
enum FollowUpContentPart: Encodable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The text exactly as read.
        case text(String)
        /// The bytes, base64-encoded.
        case data(String)
    }

    case text(String)
    case resourceLink(uri: String, name: String, mimeType: String)
    case resource(uri: String, mimeType: String, source: Source)

    private enum Key: String, CodingKey { case type, text, uri, name, mimeType, source, value }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        switch self {
        case .text(let text):
            try fields.encode("text", forKey: .type)
            try fields.encode(text, forKey: .text)
        case .resourceLink(let uri, let name, let mimeType):
            try fields.encode("resource_link", forKey: .type)
            try fields.encode(uri, forKey: .uri)
            try fields.encode(name, forKey: .name)
            try fields.encode(mimeType, forKey: .mimeType)
        case .resource(let uri, let mimeType, let source):
            try fields.encode("resource", forKey: .type)
            try fields.encode(uri, forKey: .uri)
            try fields.encode(mimeType, forKey: .mimeType)
            var nested = fields.nestedContainer(keyedBy: Key.self, forKey: .source)
            switch source {
            case .text(let value):
                try nested.encode("text", forKey: .type)
                try nested.encode(value, forKey: .value)
            case .data(let value):
                try nested.encode("data", forKey: .type)
                try nested.encode(value, forKey: .value)
            }
        }
    }
}

/// One file prepared for a follow-up. The composer shows its name, kind and size; the part is
/// what is sent. Its ID is stable for the draft, so a retry of the same draft is the same request.
struct FollowUpContextItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: FollowUpContextKind
    /// The file's name, as shown.
    let name: String
    let mimeType: String
    /// The file's size on disk when it was chosen.
    let byteCount: Int
    /// The canonical path on this Mac. Shown as help, never sent for a snapshot.
    let path: String
    let part: FollowUpContentPart

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

enum FollowUpContextError: LocalizedError, Equatable {
    case unavailable(String)
    case notAFile(String)
    case outsideCheckout(name: String, checkout: String)
    case unreadable(String)
    case tooLarge(name: String, limit: Int)
    case requestTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .notAFile(let name): "“\(name)” is not a regular file."
        case .outsideCheckout(let name, let checkout):
            "“\(name)” is not inside this worker's checkout (\(checkout)). Only a file in the checkout can be linked; embed a snapshot instead."
        case .unreadable(let name): "“\(name)” could not be read."
        case .tooLarge(let name, let limit):
            "“\(name)” is too large to embed. A snapshot can hold up to \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .requestTooLarge(let bytes):
            "This follow-up would be \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), over the service's \(ByteCountFormatter.string(fromByteCount: Int64(FollowUpContent.requestLimit), countStyle: .file)) limit. Remove a snapshot or shorten the message."
        }
    }
}

/// The follow-up request with file context, and its bound.
enum FollowUpContent {
    /// The service reads at most this many bytes of a JSON request.
    static let requestLimit = 1 << 20
    /// The largest file a snapshot embeds, before base64. Leaves room for the message and the
    /// request's own fields under `requestLimit`.
    static let snapshotLimit = 640 * 1024

    /// The parts in the order they are sent: the message text when there is any, then each file
    /// in the order it was attached. The text is exactly as written.
    static func parts(text: String, context: [FollowUpContextItem]) -> [FollowUpContentPart] {
        (text.isEmpty ? [] : [.text(text)]) + context.map(\.part)
    }

    /// The whole JSON request. Slashes are not escaped, so a file URI reads as written.
    /// - Throws: `FollowUpContextError.requestTooLarge` when it is over `requestLimit`.
    static func requestBody(text: String, context: [FollowUpContextItem], generation: Int) throws -> Data {
        struct Request: Encodable {
            let generation: Int
            let content: [FollowUpContentPart]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(Request(generation: generation, content: parts(text: text, context: context)))
        guard body.count <= requestLimit else { throw FollowUpContextError.requestTooLarge(body.count) }
        return body
    }

    /// Identifies one draft: its text and its files. The same draft retried has the same value.
    static func fingerprint(text: String, context: [FollowUpContextItem]) -> String {
        ([text] + context.map(\.id.uuidString)).joined(separator: "\u{0}")
    }
}

// MARK: - Feature layer

/// Prepares a chosen file for a follow-up. The only file access of the feature: it resolves the
/// path, checks it against the worker's checkout and reads a snapshot's bytes.
enum FollowUpContextReader {
    static func prepare(_ url: URL, kind: FollowUpContextKind, scope: FollowUpContextScope) -> Result<FollowUpContextItem, FollowUpContextError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            switch kind {
            case .link: return .success(try link(url, scope: scope))
            case .snapshot: return .success(try snapshot(url, scope: scope))
            }
        } catch let error as FollowUpContextError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(url.lastPathComponent))
        }
    }

    /// The path with symbolic links resolved and `.`/`..` removed.
    static func canonical(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    /// True when `path` is `checkout` itself or inside it. Both are canonical.
    static func isInside(_ path: String, checkout: String) -> Bool {
        let root = checkout.hasSuffix("/") ? String(checkout.dropLast()) : checkout
        return !root.isEmpty && path.hasPrefix(root + "/")
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func link(_ url: URL, scope: FollowUpContextScope) throws -> FollowUpContextItem {
        if let reason = scope.linkUnavailableReason { throw FollowUpContextError.unavailable(reason) }
        let path = canonical(url.path(percentEncoded: false))
        let name = URL(filePath: path).lastPathComponent
        let size = try regularFileSize(path, name: name)
        let checkout = canonical(scope.checkout)
        guard isInside(path, checkout: checkout) else {
            throw FollowUpContextError.outsideCheckout(name: name, checkout: checkout)
        }
        let file = URL(filePath: path)
        return FollowUpContextItem(id: UUID(), kind: .link, name: name, mimeType: mimeType(for: file),
                                   byteCount: size, path: path,
                                   part: .resourceLink(uri: file.absoluteString, name: name,
                                                       mimeType: mimeType(for: file)))
    }

    private static func snapshot(_ url: URL, scope: FollowUpContextScope) throws -> FollowUpContextItem {
        if let reason = scope.snapshotUnavailableReason { throw FollowUpContextError.unavailable(reason) }
        let path = canonical(url.path(percentEncoded: false))
        let file = URL(filePath: path)
        let name = file.lastPathComponent
        let size = try regularFileSize(path, name: name)
        guard size <= FollowUpContent.snapshotLimit else {
            throw FollowUpContextError.tooLarge(name: name, limit: FollowUpContent.snapshotLimit)
        }
        guard let data = try? Data(contentsOf: file), data.count <= FollowUpContent.snapshotLimit else {
            throw FollowUpContextError.unreadable(name)
        }
        let id = UUID()
        let uri = "urn:commander:attachment:\(id.uuidString.lowercased())"
        let declared = UTType(filenameExtension: file.pathExtension)
        // Text is sent literally when the file is UTF-8 without NUL bytes; anything else as data.
        let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        let mimeType: String
        let source: FollowUpContentPart.Source
        if let text {
            mimeType = declared?.preferredMIMEType ?? "text/plain"
            source = .text(text)
        } else {
            mimeType = declared?.preferredMIMEType ?? "application/octet-stream"
            source = .data(data.base64EncodedString())
        }
        return FollowUpContextItem(id: id, kind: .snapshot, name: name, mimeType: mimeType, byteCount: data.count,
                                   path: path, part: .resource(uri: uri, mimeType: mimeType, source: source))
    }

    private static func regularFileSize(_ path: String, name: String) throws -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw FollowUpContextError.unreadable(name)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FollowUpContextError.notAFile(name)
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Recorded resources

/// A resource part as a prompt recorded it, read for display: its kind, name, address, type and
/// size. The embedded contents are never part of it, so a reader shows what was attached without
/// printing the file. Accepts the request's shape (`uri`, `mimeType`, `source`) and ACP's
/// (`resource: { uri, mimeType, text | blob }`).
struct PromptResourceSummary: Equatable, Sendable {
    /// The caption of the redacted fields well.
    static let fieldsTitle = "attached file · contents not shown"

    let kind: FollowUpContextKind
    /// The file name, from `name` or the last component of the URI. Empty when neither has one.
    let name: String
    let uri: String
    let mimeType: String
    /// Bytes of embedded content, when there is any.
    let contentBytes: Int?

    init?(part value: AGUIValue) {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "resource_link":
            kind = .link
            uri = value["uri"]?.stringValue ?? ""
            mimeType = value["mimeType"]?.stringValue ?? ""
            name = Self.name(value["name"]?.stringValue, uri: uri)
            contentBytes = value["size"]?.intValue
        case "resource":
            kind = .snapshot
            // ACP nests the resource; the request keeps it flat with a source.
            let resource = value["resource"]?.objectValue.map(AGUIValue.object) ?? value
            uri = resource["uri"]?.stringValue ?? ""
            mimeType = resource["mimeType"]?.stringValue ?? ""
            name = Self.name(resource["name"]?.stringValue ?? value["name"]?.stringValue, uri: uri)
            if let text = resource["text"]?.stringValue {
                contentBytes = text.utf8.count
            } else if let blob = resource["blob"]?.stringValue {
                contentBytes = Data(base64Encoded: blob, options: .ignoreUnknownCharacters)?.count
            } else if let source = resource["source"], let sourceValue = source["value"]?.stringValue {
                contentBytes = source["type"]?.stringValue == "data"
                    ? Data(base64Encoded: sourceValue, options: .ignoreUnknownCharacters)?.count
                    : sourceValue.utf8.count
            } else {
                contentBytes = nil
            }
        default:
            return nil
        }
    }

    /// Reads a recorded extension whose data is one JSON resource part. Nil for anything else.
    init?(mediaType: String, data: Data?) {
        guard SourceAttachment.baseType(mediaType) == "application/json", let data, !data.isEmpty,
              let value = try? AGUIValue(json: data) else { return nil }
        self.init(part: value)
    }

    private static func name(_ given: String?, uri: String) -> String {
        if let given = given?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return given }
        guard uri.hasPrefix("file:"), let url = URL(string: uri) else { return "" }
        return url.lastPathComponent
    }

    /// "file link" or "file snapshot", as a heading.
    var title: String { kind == .link ? "file link" : "file snapshot" }

    /// One line: the type and, for a snapshot, its size.
    var detail: String {
        var parts = [mimeType.isEmpty ? "type not stated" : mimeType]
        if let contentBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(contentBytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    /// What the part says, without its contents, as JSON for a fields well.
    var redactedJSON: String {
        var fields: [String: AGUIValue] = ["type": .string(kind == .link ? "resource_link" : "resource"),
                                           "uri": .string(uri)]
        if !name.isEmpty { fields["name"] = .string(name) }
        if !mimeType.isEmpty { fields["mimeType"] = .string(mimeType) }
        if kind == .snapshot {
            fields["contents"] = .string(contentBytes.map { "\($0) bytes, not shown" } ?? "not shown")
        }
        return AGUIValue.object(fields).prettyText
    }

    /// The reason a reader gives for not drawing the file.
    var statement: String {
        switch kind {
        case .link:
            "A link to \(name.isEmpty ? "a file" : "“\(name)”")\(uri.isEmpty ? "" : " at \(uri)"). The file is not opened here."
        case .snapshot:
            "A snapshot of \(name.isEmpty ? "a file" : "“\(name)”") embedded in the prompt. Its contents are not shown here."
        }
    }
}

// MARK: - Component values

/// What the focused worker's composer needs to offer file context. Present only when the session
/// accepts a link or a snapshot.
struct FollowUpContextAccess {
    /// Why each kind is not offered, in words. Nil when it is.
    let linkUnavailable: String?
    let snapshotUnavailable: String?
    /// Prepares a chosen file. The feature layer reads it.
    let prepare: @MainActor (_ url: URL, _ kind: FollowUpContextKind) -> Result<FollowUpContextItem, FollowUpContextError>
    /// Sends the draft with its files. Returns true once the service accepts it.
    let send: @MainActor (_ text: String, _ context: [FollowUpContextItem]) async -> Bool
}

// MARK: - Molecules

/// One selected file in the composer: its kind, name and size, and Remove. In the terminal face.
struct FollowUpContextChip: View {
    let item: FollowUpContextItem
    var isEnabled = true
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.kind == .link ? "link" : "doc.text")
                .font(.system(size: 10)).foregroundStyle(Term.cyan)
                .accessibilityHidden(true)
            Text(verbatim: item.name).foregroundStyle(Term.bright)
                .lineLimit(1).truncationMode(.middle)
            Text(verbatim: "\(item.kind.label) · \(item.sizeLabel)").foregroundStyle(.inkTermDim)
                .lineLimit(1).fixedSize()
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold))
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.inkTermDim)
            .disabled(!isEnabled)
            .help("Remove \(item.name)")
            .accessibilityLabel("Remove \(item.name) from this follow-up")
        }
        .font(Term.font(11))
        .padding(.leading, 7).padding(.trailing, 3).padding(.vertical, 2)
        .background(Term.bar)
        .overlay { Rectangle().strokeBorder(Term.rule, lineWidth: 1) }
        .help(item.kind == .link ? "Link to \(item.path)" : "Snapshot of \(item.path), \(item.mimeType)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.kind == .link ? "Linked file" : "File snapshot") \(item.name), \(item.sizeLabel)")
    }
}

/// The composer's file-context action: a paperclip that offers a link to a file in the worker's
/// checkout and a snapshot of a file's contents. A kind the session does not accept is shown
/// disabled with its reason.
struct FollowUpContextMenu: View {
    let linkUnavailable: String?
    let snapshotUnavailable: String?
    var isEnabled = true
    let choose: (FollowUpContextKind) -> Void

    var body: some View {
        Menu {
            Button { choose(.link) } label: {
                Label("Link File in Checkout…", systemImage: "link")
            }
            .disabled(linkUnavailable != nil)
            .help(linkUnavailable ?? "Send a link to a file in this worker's checkout. The worker reads the file itself.")
            Button { choose(.snapshot) } label: {
                Label("Embed File Snapshot…", systemImage: "doc.text")
            }
            .disabled(snapshotUnavailable != nil)
            .help(snapshotUnavailable ?? "Send the file's contents as they are now, inside the message.")
            if let reason = linkUnavailable ?? snapshotUnavailable {
                Divider()
                Text(reason)
            }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(Term.cyan) : AnyShapeStyle(.inkTermDim))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .help("Attach file context")
        .accessibilityLabel("Attach file context")
    }
}
