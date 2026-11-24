import AppKit
import ImageIO
import Observation
import SwiftUI

// CONSOLE SOURCE INSPECTOR
// The provider records behind one worker's console, opened from that console and closed again.
// It is the same composition whichever display mode the console is in, and on every surface:
//
//   Feature layer   ConsoleSourceModel     one open inspection, its pages and its requests
//   Values          SourceInspection       what the inspector draws
//                   ConsoleSourceAccess    what a console needs to offer and host the inspector
//   Molecules       ConsoleSourceMenuItems the native action, inside the title bar's display menu
//                   SourceRecordRow        one record: its body, and the original record on request
//   Organism        ConsoleSourceInspector identity, source choice, provenance, records, paging
//
// A worker without a provider session has no access value, so none of this is drawn for it and
// its console shows terminal or Pretty output as before. The inspector reads; it sends nothing to
// the worker and holds no terminal input, reply field or draft.

// MARK: - Feature model

/// The open inspection: one worker, one source, and the pages read so far.
struct SourceInspection: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let workerID: String
    var source: ConsoleSourceKind
    var phase: Phase = .loading
    var observations: [SourceObservation] = []
    /// Cursor for the next page of this worker and source. Nil at the end.
    var nextCursor: String? = nil
    var isLoadingMore = false
    /// Why the last request for a further page failed. The pages already read stay in place.
    var pageError: String? = nil
    /// The cursor the service issued for the last page read, nil when that is the first page, and
    /// where that page starts in `observations`. Following an active session reads this one page
    /// again, so new records arrive without reading the earlier pages a second time.
    var tailCursor: String? = nil
    var tailStart = 0
    /// A check for new records is in flight. The records already shown stay in place.
    var isFollowing = false
}

/// Reads source pages for the one console being inspected. A request is identified by its worker,
/// its source and a generation number. Selecting another worker or source, or closing the
/// inspector, starts a new generation, so an answer that arrives late is dropped and can never be
/// drawn on another worker's console.
@Observable @MainActor
final class ConsoleSourceModel {
    typealias Loader = @Sendable (_ workerID: String, _ source: ConsoleSourceKind, _ cursor: String?) async throws -> SourcePage

    private(set) var inspection: SourceInspection?
    private let load: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The source last chosen for each worker during this launch.
    private var chosen: [String: ConsoleSourceKind] = [:]

    init(load: @escaping Loader) {
        self.load = load
    }

    /// Opens the inspector on a worker and reads the first page of its source. Nil closes it:
    /// the request in flight is abandoned, and the last page stays only until the next open.
    func inspect(_ workerID: String?) {
        guard let workerID else {
            cancel()
            return
        }
        inspection = SourceInspection(workerID: workerID, source: chosen[workerID] ?? .provider)
        fetch(more: false)
    }

    /// Switches the open inspection to another source of the same worker, from its first page.
    func select(_ source: ConsoleSourceKind) {
        guard let current = inspection, current.source != source else { return }
        chosen[current.workerID] = source
        inspection = SourceInspection(workerID: current.workerID, source: source)
        fetch(more: false)
    }

    /// Reads the next page of the selected source.
    func loadMore() {
        guard let current = inspection, current.phase == .loaded, current.nextCursor != nil,
              !current.isLoadingMore else { return }
        fetch(more: true)
    }

    /// Checks the open source for records that arrived after its last page was read. Only that
    /// last page is read again, from the cursor the service issued for it, and its records are
    /// replaced by the answer; every earlier page stays as read. It does nothing while another
    /// read is in flight or while earlier pages are still unread, so it never interrupts paging.
    func follow() {
        guard let current = inspection, current.phase == .loaded, current.nextCursor == nil,
              !current.isLoadingMore, !current.isFollowing else { return }
        fetch(more: false, tail: true)
    }

    /// Reads the first page again after a failure.
    func retry() {
        guard let current = inspection else { return }
        inspection = SourceInspection(workerID: current.workerID, source: current.source)
        fetch(more: false)
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if inspection?.phase == .loading { inspection = nil }
        inspection?.isLoadingMore = false
        inspection?.isFollowing = false
    }

    private func fetch(more: Bool, tail: Bool = false) {
        guard var current = inspection else { return }
        task?.cancel()
        generation += 1
        let token = generation
        let workerID = current.workerID
        let source = current.source
        let cursor = tail ? current.tailCursor : more ? current.nextCursor : nil
        if more {
            current.isLoadingMore = true
            current.pageError = nil
            inspection = current
        } else if tail {
            current.isFollowing = true
            inspection = current
        }
        task = Task { [load] in
            let result: Result<SourcePage, Error>
            do {
                result = .success(try await load(workerID, source, cursor))
            } catch {
                result = .failure(error)
            }
            // Only the request the inspector is still waiting for may change what it shows.
            guard !Task.isCancelled, token == self.generation, var latest = self.inspection,
                  latest.workerID == workerID, latest.source == source else { return }
            latest.isLoadingMore = false
            latest.isFollowing = false
            switch result {
            case .success(var page):
                // A record's ID is its position in the source, so a record keeps its ID, and its
                // open state, when the last page is read again.
                let offset = tail ? min(latest.tailStart, latest.observations.count)
                    : more ? latest.observations.count : 0
                for index in page.observations.indices {
                    page.observations[index].id = "\(source.rawValue):\(offset + index)"
                }
                // A re-read that returns fewer records than are shown is not applied: the window
                // moved, and the records on screen are still what the source sent.
                if tail, offset + page.observations.count < latest.observations.count {
                    self.inspection = latest
                    return
                }
                latest.observations = Array(latest.observations.prefix(offset)) + page.observations
                latest.tailCursor = cursor
                latest.tailStart = offset
                // A page may hold no observations and still advance: the journal reads bounded
                // byte ranges, and a range can hold only operational records. Its cursor is kept
                // so the data after it stays reachable. A repeated cursor would page forever.
                let next = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
                latest.nextCursor = next == cursor ? nil : next
                latest.phase = .loaded
            case .failure(let error):
                if more || tail {
                    latest.pageError = error.localizedDescription
                } else {
                    latest.phase = .failed(error.localizedDescription)
                }
            }
            self.inspection = latest
            // The last page filled up while following: read on, so the newest records are shown.
            if tail, latest.phase == .loaded, latest.nextCursor != nil, latest.pageError == nil {
                self.fetch(more: true)
            }
        }
    }
}

/// The feature layer's source operations, as the cockpit emits them.
struct ConsoleSourceIntents {
    /// Opens the inspector on a worker by ID, or closes it with nil.
    var inspect: @MainActor (_ workerID: String?) -> Void
    var select: @MainActor (ConsoleSourceKind) -> Void
    var loadMore: @MainActor () -> Void
    var retry: @MainActor () -> Void
    /// Checks the open source for records newer than its last page. Nil where a source cannot grow.
    var follow: (@MainActor () -> Void)? = nil
}

// MARK: - Component values

/// What one console needs to offer its worker's source. A console that hosts the inspector (a
/// wall tile, the focused worker, the coordinator) carries `panel`. A compact surface (the PiP)
/// carries none, and its action opens the inspector on the worker's own console.
struct ConsoleSourceAccess {
    struct Panel {
        let isPresented: Binding<Bool>
        /// This worker's inspection. Nil until its first request starts.
        let inspection: SourceInspection?
        let select: (ConsoleSourceKind) -> Void
        let loadMore: () -> Void
        let retry: () -> Void
        let copy: (String) -> Void
        /// Checks for records newer than the last page read.
        var follow: () -> Void = {}
        /// A value that changes when the worker gains a transcript entry or changes state. The
        /// open inspector checks for new records when it changes, and not on each streamed token.
        var revision = ""
    }

    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let open: () -> Void
    var panel: Panel? = nil
}

extension ConsoleSourceKind {
    var title: String {
        switch self {
        case .provider: "Provider"
        case .live: "Live"
        case .journal: "Journal"
        }
    }

    /// The source as a phrase in a sentence or a status line.
    var phrase: String {
        switch self {
        case .provider: "provider history"
        case .live: "live updates"
        case .journal: "local journal"
        }
    }

    /// Where the records of this source come from, stated for the reader.
    func provenance(client: AgentClient) -> String {
        switch self {
        case .provider:
            "History that \(client.displayName) keeps for this session, read through its harness."
        case .live:
            "The original ACP updates Commander holds for this session. A bounded, recent window."
        case .journal:
            "Supplemental records retained by the local Claude or Codex installation, read with a version-tested reader."
        }
    }
}

/// Inline rendering of extension data. Only raster images of a known type are decoded, from the
/// bytes in the record and on this Mac. Nothing is fetched, and vector or document types are not
/// rendered.
enum SourceAttachment {
    static let rasterTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/gif", "image/tiff", "image/bmp", "image/webp", "image/heic"
    ]
    static let maximumImageBytes = 12 * 1024 * 1024
    static let textPreviewBytes = 2_000

    static func baseType(_ mediaType: String) -> String {
        (mediaType.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isTrustedRaster(_ mediaType: String) -> Bool {
        rasterTypes.contains(baseType(mediaType))
    }

    static func isText(_ mediaType: String) -> Bool {
        let type = baseType(mediaType)
        return type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml")
            || ["application/json", "application/x-ndjson", "application/xml", "application/yaml",
                "application/x-yaml", "application/toml"].contains(type)
    }

    /// A reduced image of the data, or nil when it is not a readable raster image.
    @MainActor static func thumbnail(of data: Data, maxPixel: Int = 720) -> NSImage? {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func textPreview(of data: Data) -> (text: String, isWhole: Bool) {
        (String(decoding: data.prefix(textPreviewBytes), as: UTF8.self), data.count <= textPreviewBytes)
    }

    static func size(_ data: Data) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

// MARK: - Molecules

/// The native action that opens a console's source. It sits in the title bar's display menu,
/// which every console already has, so the title bar itself is unchanged.
struct ConsoleSourceMenuItems: View {
    let source: ConsoleSourceAccess

    var body: some View {
        Section("Source — This Console") {
            Button(action: source.open) {
                Label(source.panel == nil ? "Inspect Source in Worker…" : "Inspect Source…",
                      systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

/// Presents the inspector from the control that offers it, on a console that hosts one.
struct ConsoleSourcePresentation: ViewModifier {
    let source: ConsoleSourceAccess?

    func body(content: Content) -> some View {
        if let source, let panel = source.panel {
            content.popover(isPresented: panel.isPresented, arrowEdge: .bottom) {
                ConsoleSourceInspector(workerName: source.workerName, client: source.client,
                                       session: source.session, panel: panel)
            }
        } else {
            content
        }
    }
}

/// One source record in the terminal face. Text, tool names, summaries and file names are
/// selectable and never become links. The original record opens beneath it as navigable fields.
struct SourceRecordRow: View {
    let observation: SourceObservation
    /// The worker's own session. A record from another session says so.
    let workerSession: NativeSession
    let isExpanded: Bool
    let toggle: () -> Void
    let copy: (String) -> Void

    /// How much of one text or summary is drawn before the record is the place to read the rest.
    private static let textLimit = 4_000
    private let size: CGFloat = 11.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                heading
                Spacer(minLength: 4)
                Button(isExpanded ? "hide record" : "record", action: toggle)
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                    .accessibilityLabel(isExpanded ? "Hide the original record" : "Show the original record")
            }
            content
            if isExpanded { record }
        }
        .padding(.vertical, isGap ? 6 : 0)
        .padding(.horizontal, isGap ? 9 : 0)
        .background(isGap ? Term.amberWash : .clear)
        .overlay(alignment: .leading) {
            if isGap { Rectangle().fill(Term.amber).frame(width: 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isGap: Bool {
        if case .gap = observation.body { return true }
        return false
    }

    // MARK: Heading

    @ViewBuilder private var heading: some View {
        switch observation.body {
        case .text(let speaker, _):
            let fromUser = ["user", "human", "you", "developer"].contains(speaker.lowercased())
            line(fromUser ? "❯" : "●", speaker.isEmpty ? "text" : speaker.lowercased(),
                 ink: fromUser ? Term.bright : Term.cyan, label: "Text from \(speaker.isEmpty ? "an unnamed speaker" : speaker)")
        case .tool(let callID, let name, let phase, _):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("▸ ").foregroundStyle(.inkTermDim).accessibilityHidden(true)
                Text(verbatim: name.isEmpty ? "tool" : name).fontWeight(.semibold).foregroundStyle(Term.violet)
                    .textSelection(.enabled)
                if !phase.isEmpty {
                    Text(verbatim: "  " + Self.phaseMark(phase) + " " + phase.lowercased())
                        .foregroundStyle(Self.phaseInk(phase)).fixedSize()
                }
                meta
            }
            .font(Term.font(size)).lineLimit(1)
            .help(callID.isEmpty ? "Tool call" : "Tool call \(callID)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tool \(name)" + (phase.isEmpty ? "" : ", \(phase)"))
        case .input:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("? ").foregroundStyle(Term.amber).accessibilityHidden(true)
                Text("input requested").fontWeight(.semibold).foregroundStyle(Term.amber)
                Text("  historical · display only").foregroundStyle(.inkTermDim)
                meta
            }
            .font(Term.font(size)).lineLimit(1)
            .help("A request recorded in this source. It is shown as it was asked and cannot be answered here.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input requested, historical. It cannot be answered here.")
        case .turnEnded(let reason):
            line("■", "turn ended" + (reason.isEmpty ? "" : " · \(reason)"), ink: Term.dim,
                 label: "Turn ended" + (reason.isEmpty ? "" : ", \(reason)"))
        case .gap(let reason):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("! ").accessibilityHidden(true)
                Text("gap").fontWeight(.semibold)
                Text(verbatim: " · " + (reason.isEmpty ? "reason not reported" : reason))
                    .textSelection(.enabled)
            }
            .font(Term.font(size)).foregroundStyle(Term.amber)
            .fixedSize(horizontal: false, vertical: true)
            .help("The source reports that records are missing at this point.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gap in this source: \(reason.isEmpty ? "reason not reported" : reason)")
        case .attachment(let type, let mediaType, let data):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("◆ ").foregroundStyle(Term.violet).accessibilityHidden(true)
                Text(verbatim: type.isEmpty ? "extension" : type).fontWeight(.semibold).foregroundStyle(Term.violet)
                    .textSelection(.enabled)
                Text(verbatim: "  " + [mediaType.isEmpty ? "type not reported" : mediaType,
                                       data.map(SourceAttachment.size) ?? "unreadable data"].joined(separator: " · "))
                    .foregroundStyle(.inkTermDim)
                meta
            }
            .font(Term.font(size)).lineLimit(1)
            .accessibilityElement(children: .combine)
        case .unrecognized:
            line("·", "record", ink: Term.dim, label: "Record with no recognized content")
        }
    }

    private func line(_ glyph: String, _ title: String, ink: Color, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(glyph + " ").foregroundStyle(ink).accessibilityHidden(true)
            Text(verbatim: title).fontWeight(.semibold).foregroundStyle(ink)
            meta
        }
        .font(Term.font(size)).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The turn the record belongs to, and its session when that is not the worker's own.
    @ViewBuilder private var meta: some View {
        let foreign = observation.session.flatMap { $0 == workerSession || $0.sessionID.isEmpty ? nil : $0 }
        if !observation.turnID.isEmpty {
            Text(verbatim: "  turn " + Identifier.short(observation.turnID)).foregroundStyle(.inkTermDim)
                .help("Turn \(observation.turnID)")
        }
        if let foreign {
            Text(verbatim: "  session " + Identifier.short(foreign.sessionID)).foregroundStyle(Term.amber)
                .help("Recorded in session \(foreign.sessionID) of \(foreign.harnessInstance), not this worker's bound session.")
        }
    }

    private static func phaseMark(_ phase: String) -> String {
        switch phase.lowercased() {
        case "completed", "complete", "done", "succeeded", "success", "ok", "finished": "✓"
        case "failed", "error", "errored", "cancelled", "canceled", "denied": "✗"
        default: "…"
        }
    }

    private static func phaseInk(_ phase: String) -> Color {
        switch phaseMark(phase) {
        case "✓": Term.green
        case "✗": Term.red
        default: Term.amber
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch observation.body {
        case .text(let speaker, let text):
            let fromUser = ["user", "human", "you", "developer"].contains(speaker.lowercased())
            prose(text, ink: fromUser ? Term.bright : Term.text)
        case .tool(_, _, _, let summary):
            if !summary.isEmpty {
                prose(summary, ink: Term.text)
                    .padding(.leading, size * 0.9)
                    .overlay(alignment: .leading) { Rectangle().fill(Term.dim).frame(width: 1) }
                    .padding(.leading, size * 0.3)
            }
        case .input(let prompt, let choices):
            VStack(alignment: .leading, spacing: 3) {
                if !prompt.isEmpty { prose(prompt, ink: Term.bright) }
                // Choices are text. A historical request has nothing to press.
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Text(verbatim: "\(index + 1). \(choice)")
                        .font(Term.font(size)).foregroundStyle(Term.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, size * 1.2)
        case .attachment(_, let mediaType, let data):
            SourceAttachmentView(mediaType: mediaType, data: data, size: size, copy: copy)
                .padding(.leading, size * 1.2)
        case .unrecognized:
            Text("No recognized content. The original record has everything the source sent.")
                .font(Term.font(size - 0.5)).foregroundStyle(.inkTermDim)
                .padding(.leading, size * 1.2)
        case .turnEnded, .gap:
            EmptyView()
        }
    }

    /// Verbatim, selectable text. A URL or a path in it stays text: nothing here is a link.
    @ViewBuilder private func prose(_ text: String, ink: Color) -> some View {
        let cut = text.index(text.startIndex, offsetBy: Self.textLimit, limitedBy: text.endIndex)
        let isWhole = cut == nil || cut == text.endIndex
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: isWhole ? text : String(text[..<cut!]))
                .font(Term.font(size)).lineSpacing(size * 0.3)
                .foregroundStyle(ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isWhole {
                Text("… shortened here. The record has the whole text.")
                    .font(Term.font(size - 1)).foregroundStyle(.inkTermDim)
            }
        }
    }

    // MARK: Original record

    /// The whole record in the shared fields panel: every field as a row at its key path, what a
    /// field's text decodes to beneath it, and the JSON itself on request. The panel scrolls
    /// inside its own bounds, so a large record stays within the inspector.
    private var record: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: recordCaption)
                    .font(Term.font(10)).foregroundStyle(.inkTermDim)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button("copy record") { copy(observation.record) }
                    .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10))
                    .help("Copy the whole original record as JSON")
                    .accessibilityLabel("Copy the original record")
            }
            RecordFieldsPanel(detail: recordDetail, layout: .inline, copy: copy, close: toggle)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Original record")
    }

    private var recordDetail: ConsoleRecordDetail {
        ConsoleRecordDetail(title: "Original record", sections: [ConsoleRecordDetail.Section(
            id: "record", title: "Original record",
            provenance: "Every field of this record as the source sent it. Text that carries JSON or data lists what it decodes to beneath it, under “decoded”.",
            json: observation.record)])
    }

    private var recordCaption: String {
        var parts = ["original record"]
        if !observation.cursor.isEmpty { parts.append("cursor \(observation.cursor)") }
        if !observation.turnID.isEmpty { parts.append("turn \(observation.turnID)") }
        return parts.joined(separator: " · ")
    }
}

/// Extension data inside a record: a locally decoded image for a trusted raster type, a short
/// text preview for a text type, and otherwise a statement that it is not rendered. The bytes
/// stay available as base64 from here and in the original record.
struct SourceAttachmentView: View {
    let mediaType: String
    let data: Data?
    let size: CGFloat
    let copy: (String) -> Void

    @State private var image: NSImage?
    @State private var decoded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let data, !data.isEmpty {
                if SourceAttachment.isTrustedRaster(mediaType) {
                    if let image {
                        Image(nsImage: image)
                            .resizable().interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: min(image.size.width, 440), maxHeight: min(image.size.height, 190), alignment: .leading)
                            .overlay { Rectangle().strokeBorder(Term.rule, lineWidth: 1) }
                            .accessibilityLabel("Inline image, \(mediaType)")
                    } else if decoded {
                        note("This image could not be decoded. Its data is in the record.")
                    }
                } else if SourceAttachment.isText(mediaType) {
                    let preview = SourceAttachment.textPreview(of: data)
                    Text(verbatim: preview.text)
                        .font(Term.font(size - 0.5)).lineSpacing(2)
                        .foregroundStyle(Term.text)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !preview.isWhole { note("… preview. Copy the data for all of it.") }
                } else {
                    note("Not rendered inline. Only known raster image types and text are shown.")
                }
                Button("copy data") { copy(data.base64EncodedString()) }
                    .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10))
                    .help("Copy the original data as base64")
                    .accessibilityLabel("Copy the original data as base64")
            } else if data == nil {
                note("The data is not valid base64. The record shows it as sent.")
            } else {
                note("This extension carries no data.")
            }
        }
        .task(id: data) {
            guard let data, SourceAttachment.isTrustedRaster(mediaType) else { return }
            image = SourceAttachment.thumbnail(of: data)
            decoded = true
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Term.font(size - 1)).foregroundStyle(.inkTermDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Organism

/// The source inspector of one worker's console. It names the worker and the session the service
/// bound it to, lets the reader choose a source and says where that source comes from, then shows
/// its records with paging inside that source. Loading, an empty source, a failure and a reported
/// gap are each stated in words.
struct ConsoleSourceInspector: View {
    let workerName: String
    let client: AgentClient
    let session: NativeSession
    let panel: ConsoleSourceAccess.Panel

    /// Records whose original is open, by record ID.
    @State private var expanded = Set<String>()

    private var inspection: SourceInspection? { panel.inspection }
    private var source: ConsoleSourceKind { inspection?.source ?? .provider }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Term.rule).frame(height: 1)
            records
            footer
        }
        .frame(width: 520, height: 540)
        // An active session keeps producing records. When the worker's console gains an entry,
        // and once that has settled, the last page is read again. Text streaming into an entry
        // does not change the revision, so tokens never cause a read.
        .task(id: panel.revision) {
            guard (try? await Task.sleep(for: .milliseconds(700))) != nil else { return }
            panel.follow()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source inspector, \(workerName)")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentAvatar(client: client, size: 18)
                Text(workerName).font(TypeRole.sectionTitle).foregroundStyle(Palette.foreground)
                    .lineLimit(1).truncationMode(.tail)
                Kicker(text: "Source")
                Spacer(minLength: 8)
                SymbolButton(symbol: "xmark", label: "Close source inspector", size: 10) {
                    panel.isPresented.wrappedValue = false
                }
                .foregroundStyle(.inkSecondary)
                .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: sessionLine)
                    .font(TypeRole.monoID).foregroundStyle(.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Harness \(session.harnessInstance.isEmpty ? "not reported" : session.harnessInstance), session \(session.sessionID)")
                Spacer(minLength: 4)
                Button("copy session") { panel.copy(session.sessionID) }
                    .buttonStyle(TermButtonStyle(ink: Term.text, size: 10))
                    .accessibilityLabel("Copy session ID \(session.sessionID)")
            }
            Picker("Source", selection: Binding(get: { source }, set: { panel.select($0) })) {
                ForEach(ConsoleSourceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Source for \(workerName)")
            Text(source.provenance(client: client))
                .font(TypeRole.caption).foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 11)
    }

    private var sessionLine: String {
        ((session.harnessInstance.isEmpty ? [] : [session.harnessInstance])
            + ["session " + session.sessionID]).joined(separator: " · ")
    }

    // MARK: Records

    private var records: some View {
        ZStack(alignment: .topLeading) {
            Term.background
            switch inspection?.phase {
            case nil, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("reading \(source.phrase) for \(workerName.lowercased())…")
                        .font(Term.font(11.5)).foregroundStyle(.inkTermDim)
                }
                .padding(14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reading \(source.phrase) for \(workerName)")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("✗ ").accessibilityHidden(true)
                        Text(verbatim: "could not read \(source.phrase): \(message)").textSelection(.enabled)
                    }
                    .font(Term.font(11.5)).foregroundStyle(Term.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Could not read \(source.phrase) for \(workerName): \(message)")
                    Button("retry", action: panel.retry)
                        .buttonStyle(TermButtonStyle(ink: Term.bright))
                        .accessibilityLabel("Read \(source.phrase) again")
                }
                .padding(14)
            case .loaded:
                if let inspection, !inspection.observations.isEmpty {
                    list(inspection)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("○ ").accessibilityHidden(true)
                        Text("no records in \(source.phrase) for \(workerName.lowercased())")
                    }
                    .font(Term.font(11.5)).foregroundStyle(.inkTermDim)
                    .padding(14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("No records in \(source.phrase) for \(workerName)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(_ inspection: SourceInspection) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 11) {
                ForEach(inspection.observations) { observation in
                    SourceRecordRow(observation: observation, workerSession: session,
                                    isExpanded: expanded.contains(observation.id),
                                    toggle: { toggle(observation.id) }, copy: panel.copy)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A new source starts at its first record.
        .id(inspection.source)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.phrase.capitalized), \(workerName)")
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Paging

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: summary).font(Term.font(10.75)).foregroundStyle(.inkTermDim)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if let inspection, inspection.phase == .loaded {
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
                    Button(inspection.pageError == nil ? "load more" : "retry", action: panel.loadMore)
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.75))
                        .help("Read the next page of \(source.phrase) for \(workerName)")
                        .accessibilityLabel("Load more \(source.phrase) for \(workerName)")
                } else if inspection.isFollowing {
                    Text("checking for new…").font(Term.font(10.75)).foregroundStyle(Term.cyan)
                        .accessibilityLabel("Checking for new records")
                } else {
                    if !inspection.observations.isEmpty {
                        Text("end of source").font(Term.font(10.75)).foregroundStyle(.inkTermDim)
                    }
                    Button("check for new", action: panel.follow)
                        .buttonStyle(TermButtonStyle(ink: Term.cyan, size: 10.75))
                        .help("Read the last page of \(source.phrase) again for records that arrived since. "
                              + "This also happens when \(workerName) adds to its console.")
                        .accessibilityLabel("Check \(source.phrase) for new records")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 27)
        .background(Term.bar)
        .overlay(alignment: .top) { Rectangle().fill(Term.rule).frame(height: 1) }
    }

    private var summary: String {
        guard let inspection, inspection.phase == .loaded else { return source.phrase }
        let count = inspection.observations.count
        return (count == 1 ? "1 record" : "\(count) records") + " · " + source.phrase
    }
}
