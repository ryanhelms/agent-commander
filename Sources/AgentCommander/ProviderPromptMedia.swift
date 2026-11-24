import Foundation

// PROVIDER PROMPT MEDIA
// The images and audio of a prompt recovered from Claude or Codex history, read from the one
// provider record that owns the prompt. A value layer only: `PromptAttachmentModel` reads the
// record, and `PromptAttachmentsPanel` draws what this returns.
//
//   Request    the selected worker's history route with `recordCursor`, the owner's exact
//              cursor, and `cursor`, the message's page hint, when it gives one. Nothing else.
//   Answer     exactly one SDK observation at that cursor, or one gap, and no further page.
//              Anything else fails the read; no other record is used in its place. When the
//              worker's session is known, the answer must name that harness and session.
//   Record     the observation's `sourceRecord`: base64 of the provider's original JSON, typed
//                claude.history.message  {"type":"user","message":{"content":[ ...blocks ]}}
//                codex.history.item      {"type":"userMessage","content":[ ...inputs ]}
//              An owner record's `sourceCursor`, when set, is its own cursor; one that names
//              another cursor is a sibling of the owner and is refused.
//   Parts      the block types the service's provider projector counts, in order, at the top
//              level of that content list: Claude `image` and `audio`; Codex `image`, `audio`
//              and `localImage`. Repeats are kept, identical bytes included.
//
// Only bytes inside the record are decoded. A link, a file path or a provider file ID is stated
// with its fields and never followed, opened or read.

enum ProviderPromptMedia {
    static let kind = "provider_prompt_media"
    static let contentTypes: Set<String> = ["image", "audio", "mixed"]

    /// The provider record types whose prompts carry media, as the service names them.
    enum Provider: String {
        case claude = "claude.history.message"
        case codex = "codex.history.item"
    }

    /// The caption of a part's own fields.
    static let partTitle = "this part in the provider record"

    /// The items of the page that answers a one-record read of `reference`.
    /// - Throws: `PromptAttachmentError` when the page is not exactly the record asked for, or
    ///   one gap, with no further page.
    static func items(of page: SourcePage, for reference: PromptAttachmentReference) throws -> [PromptAttachmentItem] {
        guard page.observations.count == 1, var observation = page.observations.first else {
            throw PromptAttachmentError.recordCount(page.observations.count)
        }
        // The exact-record read has no next page, for a record or for a gap.
        guard page.nextCursor == nil else { throw PromptAttachmentError.furtherPage }
        observation.id = "prompt:0"
        try checkSession(observation, reference)

        if case .gap = observation.body {
            // A gap reports why this record cannot be read. One naming another record is not ours.
            guard observation.cursor.isEmpty || observation.cursor == reference.firstCursor else {
                throw PromptAttachmentError.otherRecord(observation.cursor)
            }
            return [PromptAttachmentItem(observation: observation)]
        }

        guard observation.cursor == reference.firstCursor else {
            throw PromptAttachmentError.otherRecord(observation.cursor)
        }
        let envelope = try? AGUIValue(json: observation.record)
        if let owner = envelope?["sourceCursor"]?.stringValue, !owner.isEmpty, owner != observation.cursor {
            throw PromptAttachmentError.siblingRecord(owner)
        }
        if !reference.turnID.isEmpty, !observation.turnID.isEmpty, observation.turnID != reference.turnID {
            throw PromptAttachmentError.foreignTurn(observation.turnID)
        }

        switch owner(envelope) {
        case .failure(let failure):
            return [undecodable(observation, failure.reason)]
        case .success(let (provider, blocks)):
            let items = blocks.compactMap { part($0, provider) }.enumerated().map { index, part in
                PromptAttachmentItem(id: "prompt:part:\(index)", observation: observation, body: part.body,
                                     decoded: part.block.prettyText, decodedTitle: partTitle)
            }
            return items.isEmpty
                ? [undecodable(observation, "The record has no image or audio part at the top level of its prompt.")]
                : items
        }
    }

    // MARK: Identity

    /// With a known session, the answer must name exactly that harness and session.
    private static func checkSession(_ observation: SourceObservation, _ reference: PromptAttachmentReference) throws {
        guard let expected = reference.session else { return }
        guard let found = observation.session, found == expected else {
            throw PromptAttachmentError.otherSession(observation.session.map {
                [$0.harnessInstance.isEmpty ? "no harness" : $0.harnessInstance,
                 $0.sessionID.isEmpty ? "no session" : $0.sessionID].joined(separator: " · ")
            } ?? "none stated")
        }
    }

    // MARK: Owner record

    private struct OwnerFailure: Error { let reason: String }

    /// The provider and the top-level content list of its original prompt record, or why it
    /// cannot be read.
    private static func owner(_ envelope: AGUIValue?) -> Result<(Provider, [AGUIValue]), OwnerFailure> {
        func fail(_ reason: String) -> Result<(Provider, [AGUIValue]), OwnerFailure> { .failure(OwnerFailure(reason: reason)) }
        guard let source = envelope?["sourceRecord"]?.objectValue else {
            return fail("The record carries no original provider record to decode.")
        }
        let type = source["type"]?.stringValue ?? ""
        guard let provider = Provider(rawValue: type) else {
            return fail("Its original record is \(type.isEmpty ? "of no stated type" : "of type \(type)"), not a Claude or Codex history record.")
        }
        if let mediaType = source["mediaType"]?.stringValue, !mediaType.isEmpty,
           SourceAttachment.baseType(mediaType) != "application/json" {
            return fail("Its original record is \(mediaType), not JSON.")
        }
        guard let encoded = source["data"]?.stringValue, !encoded.isEmpty else {
            return fail("Its original record carries no data.")
        }
        guard let data = base64(encoded) else {
            return fail("Its original record is not valid base64.")
        }
        guard let root = try? AGUIValue(json: data), root.objectValue != nil else {
            return fail("Its original record is not a JSON object.")
        }
        switch provider {
        case .claude:
            guard root["type"]?.stringValue == "user" else {
                return fail("Its Claude record is not a user message.")
            }
            switch root["message"]?["content"] {
            case .array(let blocks)?: return .success((provider, blocks))
            case .string?: return .success((provider, []))
            default: return fail("Its Claude user message has no content.")
            }
        case .codex:
            guard root["type"]?.stringValue == "userMessage" else {
                return fail("Its Codex record is not a user message.")
            }
            guard let inputs = root["content"]?.arrayValue else {
                return fail("Its Codex user message has no content list.")
            }
            return .success((provider, inputs))
        }
    }

    private static func undecodable(_ observation: SourceObservation, _ reason: String) -> PromptAttachmentItem {
        PromptAttachmentItem(id: "prompt:0", observation: observation, body: .undecodable(reason),
                             decoded: nil, decodedTitle: partTitle)
    }

    // MARK: Parts

    /// The media part one top-level block is, with the block as recorded. Nil for text and for
    /// every block type the provider projector does not count as media.
    private static func part(_ block: AGUIValue, _ provider: Provider) -> (body: PromptAttachmentItem.Body, block: AGUIValue)? {
        guard block.objectValue != nil, let type = block["type"]?.stringValue else { return nil }
        switch (provider, type) {
        case (.claude, "image"), (.claude, "audio"):
            return (claude(block, type: type), block)
        case (.codex, "image"), (.codex, "audio"):
            return (codexURL(block, type: type), block)
        case (.codex, "localImage"):
            let body: PromptAttachmentItem.Body = block["path"]?.stringValue == nil
                ? .unavailable(type: "image", mimeType: "", reason: "It is a local image that states no path.")
                : .unavailable(type: "image", mimeType: "",
                               reason: "It is a file on the worker's machine. Commander does not open local files for this view.")
            return (body, block)
        default:
            return nil
        }
    }

    /// A Claude block: its `source` says how the bytes are held.
    private static func claude(_ block: AGUIValue, type: String) -> PromptAttachmentItem.Body {
        guard let source = block["source"]?.objectValue else {
            return .unavailable(type: type, mimeType: "", reason: "It carries no source.")
        }
        let mime = source["media_type"]?.stringValue ?? ""
        switch source["type"]?.stringValue {
        case "base64":
            guard let encoded = source["data"]?.stringValue else {
                return .unavailable(type: type, mimeType: mime,
                                    reason: "It declares inline base64 data but carries none.")
            }
            return inline(type: type, mimeType: mime, encoded: encoded)
        case "url":
            return .unavailable(type: type, mimeType: mime, reason: externalLink)
        case "file":
            return .unavailable(type: type, mimeType: mime,
                                reason: "It refers to a file the provider stores by ID. The file is not in this record.")
        case let kind?:
            return .unavailable(type: type, mimeType: mime, reason: "Its source is of type \(kind), which is not decoded here.")
        case nil:
            return .unavailable(type: type, mimeType: mime, reason: "Its source states no type.")
        }
    }

    /// A Codex image or audio input: a `data:` URL is decoded; any other URL is a link.
    private static func codexURL(_ block: AGUIValue, type: String) -> PromptAttachmentItem.Body {
        guard let url = block["url"]?.stringValue else {
            return .unavailable(type: type, mimeType: "", reason: "It states no URL.")
        }
        guard url.lowercased().hasPrefix("data:") else {
            return .unavailable(type: type, mimeType: "", reason: externalLink)
        }
        guard let comma = url.firstIndex(of: ",") else {
            return .unavailable(type: type, mimeType: "", reason: "Its data URL is malformed: it has no data section.")
        }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let parameters = header.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let mime = parameters.first ?? ""
        guard parameters.dropFirst().contains(where: { $0.lowercased() == "base64" }) else {
            return .unavailable(type: type, mimeType: mime, reason: "Its data URL is not base64, so it is not decoded.")
        }
        return inline(type: type, mimeType: mime, encoded: String(url[url.index(after: comma)...]))
    }

    private static let externalLink = "It is a link to media held elsewhere. Commander does not follow links."

    /// Bytes stated inline. An explicitly empty payload stays distinguishable: it decodes to
    /// empty data, which the renderer states as carrying no data.
    private static func inline(type: String, mimeType: String, encoded: String) -> PromptAttachmentItem.Body {
        guard !mimeType.isEmpty else {
            return .unavailable(type: type, mimeType: "", reason: "It states no media type, so it is not decoded.")
        }
        return .media(type: type, mimeType: mimeType, data: encoded.isEmpty ? Data() : base64(encoded))
    }

    /// Strict base64: line breaks and spaces are allowed, any other character outside the
    /// alphabet makes the data unreadable rather than silently shorter.
    private static func base64(_ encoded: String) -> Data? {
        Data(base64Encoded: encoded.filter { !$0.isWhitespace })
    }
}
