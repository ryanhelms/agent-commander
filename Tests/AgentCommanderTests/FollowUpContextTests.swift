import Foundation
import Testing
@testable import AgentCommander

// File context on the focused worker's follow-up: the prompt capabilities it depends on, the
// request's exact content, its bound, the link's checkout scope, the snapshot's encoding, and how
// a recorded file reads in the Source inspector without its contents.

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A checkout with one text file, one binary file and one file outside it.
private struct Checkout {
    let root: URL
    let text: URL
    let binary: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "followup-\(UUID().uuidString)")
        root = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        text = root.appending(path: "docs/notes.txt")
        try Data("line one\n\"quoted\" $HOME\n".utf8).write(to: text)
        binary = root.appending(path: "blob.bin")
        try Data([0, 1, 2, 255]).write(to: binary)
        outside = base.appending(path: "secret.txt")
        try Data("not in the checkout".utf8).write(to: outside)
    }

    func scope(host: String = "localhost", link: Bool = true, embed: Bool = true) -> FollowUpContextScope {
        FollowUpContextScope(workerID: "w-1", host: host, checkout: root.path(percentEncoded: false),
                             capabilities: WorkerPromptCapabilities(resourceLink: link, embeddedContext: embed))
    }
}

@Suite struct WorkerPromptCapabilityTests {
    @Test func readsTheControlRecordsCapabilities() throws {
        let control = try WorkerControl(projection: AGUIValue(json: #"{"held":true,"generation":3,"prompt_capabilities":{"image":true,"audio":false,"resourceLink":true,"embeddedContext":true}}"#))
        #expect(control.promptCapabilities == WorkerPromptCapabilities(image: true, audio: false, resourceLink: true,
                                                                       embeddedContext: true))
        let snake = try WorkerControl(projection: AGUIValue(json: #"{"held":true,"generation":3,"prompt_capabilities":{"resource_link":true}}"#))
        #expect(snake.promptCapabilities?.resourceLink == true)
        #expect(snake.promptCapabilities?.embeddedContext == false)
    }

    @Test func leavesAnOlderControlRecordWithoutThem() throws {
        let old = try WorkerControl(projection: AGUIValue(json: #"{"held":false,"generation":1}"#))
        #expect(old.promptCapabilities == nil)
        let unreadable = try WorkerControl(projection: AGUIValue(json: #"{"held":false,"generation":1,"prompt_capabilities":"yes"}"#))
        #expect(unreadable.promptCapabilities == nil)
        // Media alone offers no file context.
        #expect(!WorkerPromptCapabilities(image: true, audio: true).acceptsFileContext)
    }

    @Test func statesWhyALinkOrSnapshotIsNotOffered() {
        let remote = FollowUpContextScope(workerID: "w", host: "build-01", checkout: "/repo",
                                          capabilities: WorkerPromptCapabilities(resourceLink: true, embeddedContext: true))
        #expect(remote.linkUnavailableReason == "A file link is offered only for a worker on this Mac. Embed a snapshot instead.")
        #expect(remote.snapshotUnavailableReason == nil)
        let textOnly = FollowUpContextScope(workerID: "w", host: "", checkout: "/repo",
                                            capabilities: WorkerPromptCapabilities(resourceLink: false, embeddedContext: false))
        #expect(textOnly.linkUnavailableReason == "This session does not accept file links.")
        #expect(textOnly.snapshotUnavailableReason == "This session does not accept embedded file contents.")
    }
}

@Suite struct FollowUpContentTests {
    private let link = FollowUpContextItem(
        id: UUID(), kind: .link, name: "notes.txt", mimeType: "text/plain", byteCount: 10, path: "/repo/notes.txt",
        part: .resourceLink(uri: "file:///repo/notes.txt", name: "notes.txt", mimeType: "text/plain"))
    private let snapshot = FollowUpContextItem(
        id: UUID(), kind: .snapshot, name: "blob.bin", mimeType: "application/octet-stream", byteCount: 3,
        path: "/repo/blob.bin",
        part: .resource(uri: "urn:commander:attachment:abc", mimeType: "application/octet-stream",
                        source: .data(Data([1, 2, 3]).base64EncodedString())))

    @Test func sendsTheTextThenEachFileInOrder() throws {
        let body = try FollowUpContent.requestBody(text: "Read these $1 \"now\"\n", context: [link, snapshot], generation: 7)
        let fields = try json(body)
        #expect(fields["generation"] as? Int == 7)
        #expect(fields["text"] == nil)
        let content = try #require(fields["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "Read these $1 \"now\"\n")
        #expect(content[1]["type"] as? String == "resource_link")
        #expect(content[1]["uri"] as? String == "file:///repo/notes.txt")
        #expect(content[1]["name"] as? String == "notes.txt")
        #expect(content[1]["mimeType"] as? String == "text/plain")
        #expect(content[2]["type"] as? String == "resource")
        #expect(content[2]["uri"] as? String == "urn:commander:attachment:abc")
        #expect(content[2]["mimeType"] as? String == "application/octet-stream")
        let source = try #require(content[2]["source"] as? [String: Any])
        #expect(source["type"] as? String == "data")
        #expect(source["value"] as? String == "AQID")
        // The URI is written as it reads.
        #expect(String(decoding: body, as: UTF8.self).contains("file:///repo/notes.txt"))
    }

    @Test func leavesOutEmptyTextAndSendsATextSnapshotLiterally() throws {
        let text = FollowUpContextItem(
            id: UUID(), kind: .snapshot, name: "a.md", mimeType: "text/markdown", byteCount: 5, path: "/a.md",
            part: .resource(uri: "urn:commander:attachment:t", mimeType: "text/markdown", source: .text("# Hi\n")))
        let content = try #require(try json(FollowUpContent.requestBody(text: "", context: [text], generation: 2))["content"] as? [[String: Any]])
        #expect(content.count == 1)
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "text")
        #expect(source["value"] as? String == "# Hi\n")
    }

    @Test func refusesARequestOverTheServiceBound() {
        let big = FollowUpContextItem(
            id: UUID(), kind: .snapshot, name: "big", mimeType: "application/octet-stream", byteCount: 900_000,
            path: "/big",
            part: .resource(uri: "urn:commander:attachment:b", mimeType: "application/octet-stream",
                            source: .data(Data(count: 900_000).base64EncodedString())))
        #expect(throws: FollowUpContextError.self) {
            try FollowUpContent.requestBody(text: "x", context: [big], generation: 1)
        }
    }

    @Test func identifiesADraftByItsTextAndFiles() {
        let same = FollowUpContent.fingerprint(text: "hi", context: [link])
        #expect(same == FollowUpContent.fingerprint(text: "hi", context: [link]))
        #expect(same != FollowUpContent.fingerprint(text: "hi", context: [link, snapshot]))
        #expect(same != FollowUpContent.fingerprint(text: "hi!", context: [link]))
        // A text-only draft keeps the text request's own key material.
        #expect(FollowUpContent.fingerprint(text: "hi", context: []) == "hi")
    }
}

@Suite struct FollowUpContextReaderTests {
    @Test func linksAFileInTheWorkersCheckoutByItsCanonicalPath() throws {
        let checkout = try Checkout()
        // Reached through `..`, the file is still the checkout's.
        let roundabout = checkout.root.appending(path: "docs/../docs/notes.txt")
        let item = try FollowUpContextReader.prepare(roundabout, kind: .link, scope: checkout.scope()).get()
        let canonical = FollowUpContextReader.canonical(checkout.text.path(percentEncoded: false))
        #expect(item.kind == .link)
        #expect(item.name == "notes.txt")
        #expect(item.mimeType == "text/plain")
        #expect(item.path == canonical)
        #expect(item.part == .resourceLink(uri: URL(filePath: canonical).absoluteString, name: "notes.txt",
                                           mimeType: "text/plain"))
        #expect(URL(filePath: canonical).absoluteString.hasPrefix("file:///"))
    }

    @Test func refusesALinkOutsideTheCheckoutOrOffThisMac() throws {
        let checkout = try Checkout()
        guard case .failure(.outsideCheckout(let name, _)) =
                FollowUpContextReader.prepare(checkout.outside, kind: .link, scope: checkout.scope()) else {
            Issue.record("a file outside the checkout is not linked")
            return
        }
        #expect(name == "secret.txt")
        // A symbolic link inside the checkout that points out of it is outside too.
        let alias = checkout.root.appending(path: "alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout.outside)
        guard case .failure(.outsideCheckout) = FollowUpContextReader.prepare(alias, kind: .link, scope: checkout.scope()) else {
            Issue.record("a symbolic link out of the checkout is not linked")
            return
        }
        guard case .failure(.unavailable) =
                FollowUpContextReader.prepare(checkout.text, kind: .link, scope: checkout.scope(host: "build-01")) else {
            Issue.record("a remote worker is offered no link")
            return
        }
        guard case .failure(.notAFile) =
                FollowUpContextReader.prepare(checkout.root.appending(path: "docs"), kind: .link, scope: checkout.scope()) else {
            Issue.record("a directory is not linked")
            return
        }
    }

    @Test func embedsTextLiterallyAndBytesAsBase64() throws {
        let checkout = try Checkout()
        let text = try FollowUpContextReader.prepare(checkout.text, kind: .snapshot, scope: checkout.scope()).get()
        guard case .resource(let uri, let mime, .text(let value)) = text.part else {
            Issue.record("a UTF-8 file is a text snapshot")
            return
        }
        #expect(uri.hasPrefix("urn:commander:attachment:"))
        #expect(mime == "text/plain")
        #expect(value == "line one\n\"quoted\" $HOME\n")

        let binary = try FollowUpContextReader.prepare(checkout.binary, kind: .snapshot, scope: checkout.scope()).get()
        guard case .resource(_, _, .data(let encoded)) = binary.part else {
            Issue.record("bytes with a NUL are a data snapshot")
            return
        }
        #expect(Data(base64Encoded: encoded) == Data([0, 1, 2, 255]))
        #expect(binary.byteCount == 4)
        // A snapshot needs no checkout: a remote worker can be sent one.
        #expect((try? FollowUpContextReader.prepare(checkout.outside, kind: .snapshot,
                                                    scope: checkout.scope(host: "build-01")).get()) != nil)
    }

    @Test func refusesWhatTheSessionDoesNotAccept() throws {
        let checkout = try Checkout()
        guard case .failure(.unavailable) = FollowUpContextReader.prepare(
            checkout.text, kind: .snapshot, scope: checkout.scope(embed: false)) else {
            Issue.record("no snapshot without embedded context")
            return
        }
        guard case .failure(.unavailable) = FollowUpContextReader.prepare(
            checkout.text, kind: .link, scope: checkout.scope(link: false)) else {
            Issue.record("no link without resource links")
            return
        }
    }

    @Test func refusesASnapshotOverItsLimit() throws {
        let checkout = try Checkout()
        let large = checkout.root.appending(path: "large.bin")
        try Data(count: FollowUpContent.snapshotLimit + 1).write(to: large)
        guard case .failure(.tooLarge) = FollowUpContextReader.prepare(large, kind: .snapshot, scope: checkout.scope()) else {
            Issue.record("a file over the snapshot limit is not embedded")
            return
        }
    }
}

@Suite struct PromptResourceSummaryTests {
    @Test func readsALinkAndASnapshotWithoutTheirContents() throws {
        let link = try #require(PromptResourceSummary(part: AGUIValue(json: #"{"type":"resource_link","uri":"file:///repo/notes.txt","name":"notes.txt","mimeType":"text/plain"}"#)))
        #expect(link.kind == .link)
        #expect(link.title == "file link")
        #expect(link.name == "notes.txt")
        #expect(link.statement.contains("file:///repo/notes.txt"))

        let request = try #require(PromptResourceSummary(part: AGUIValue(json: #"{"type":"resource","uri":"urn:commander:attachment:1","mimeType":"text/plain","source":{"type":"text","value":"TOP SECRET"}}"#)))
        #expect(request.kind == .snapshot)
        #expect(request.contentBytes == 10)
        #expect(!request.redactedJSON.contains("TOP SECRET"))
        #expect(!request.statement.contains("TOP SECRET"))

        // ACP's own shape nests the resource.
        let acp = try #require(PromptResourceSummary(part: AGUIValue(json: #"{"type":"resource","resource":{"uri":"file:///repo/a.swift","mimeType":"text/x-swift","text":"let secret = 1"}}"#)))
        #expect(acp.name == "a.swift")
        #expect(acp.mimeType == "text/x-swift")
        #expect(!acp.redactedJSON.contains("secret = 1"))

        #expect(try PromptResourceSummary(part: AGUIValue(json: #"{"type":"image","mimeType":"image/png"}"#)) == nil)
    }

    @Test func showsARecordedFileAsAStatementNotItsContents() throws {
        let part = #"{"type":"resource","uri":"urn:commander:attachment:1","mimeType":"text/plain","source":{"type":"text","value":"TOP SECRET"}}"#
        let observation: [String: Any] = [
            "turnId": "op-7", "cursor": "prompt-op-7-1",
            "extension": ["type": "acp.prompt_part", "mediaType": "application/json",
                          "data": Data(part.utf8).base64EncodedString()]]
        let page = try SourcePage(envelope: JSONSerialization.data(withJSONObject: ["observations": [observation]]))
        let item = PromptAttachmentItem(observation: try #require(page.observations.first))
        guard case .unavailable(let type, let mimeType, let reason) = item.body else {
            Issue.record("a recorded file is stated, not decoded as media")
            return
        }
        #expect(type == "file snapshot")
        #expect(mimeType == "text/plain")
        #expect(!reason.contains("TOP SECRET"))
        #expect(item.decoded.map { !$0.contains("TOP SECRET") } == true)
        #expect(item.decodedTitle == PromptResourceSummary.fieldsTitle)
        #expect(item.isPart)
    }
}
