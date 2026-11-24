import Foundation
import Observation
import SwiftUI

// Staged adapter updates in the cockpit title bar.
//
// An explicit catalog refresh, run from any local process, verifies a newer version of a pinned
// adapter and stages it. The cockpit only reports it: activation is a separate step the developer
// takes elsewhere. The attention queue stays reserved for agent decisions.
//
//   AdapterUpdate            value: one staged version, as the service reports it.
//   AdapterUpdateSnapshot    reads one `{"updates":[...]}` frame into an ordered, de-duplicated set.
//   AdapterUpdateStream      one connection to GET /v1/catalog/notices/events on the owner socket.
//   AdapterUpdateFeed        feature model: the one cancellable subscription, with reconnect backoff.
//
// ATOMIC LEVEL: Molecule and its popover content.
//
//   AdapterUpdateNotice      compact toolbar button. Opens AdapterUpdateList in a popover.
//   AdapterUpdateList        the staged updates, each an AdapterUpdateRow.
//   AdapterUpdateToolbarItem binds the feed to the notice in the window toolbar. It reads the feed
//                            itself, so a change of the set never re-projects the conversations.

/// One staged adapter version. The service sends the whole set on every change.
struct AdapterUpdate: Identifiable, Equatable, Sendable {
    let adapterID: String
    /// The pinned version in use. Empty when the service names none.
    let currentVersion: String
    /// The verified version that is staged and not yet active.
    let availableVersion: String
    /// Hex digest of the staged manifest. Empty when the service names none.
    let manifestSHA256: String

    var id: String { adapterID }

    /// The manifest digest shortened for display. The full value stays in help and selection.
    var shortManifest: String { String(manifestSHA256.prefix(12)) }

    var currentLabel: String { currentVersion.isEmpty ? "none" : currentVersion }
}

enum AdapterUpdateSnapshot {
    /// Every verified update is kept. The frame size is bounded by `AdapterUpdateStream.eventLimit`.
    private struct Envelope: Decodable { let updates: [Entry]? }

    private struct Entry: Decodable {
        let adapterId: String?
        let currentVersion: String?
        let availableVersion: String?
        let manifestSHA256: String?
    }

    /// Reads one frame. The result has one entry per adapter, ordered by adapter ID, so a repeated
    /// identical refresh produces an equal value and never a second row. An entry without an
    /// adapter or an available version is left out. A missing or null list is empty.
    static func decode(_ frame: some Sequence<UInt8>) throws -> [AdapterUpdate] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(frame))
        var byAdapter: [String: AdapterUpdate] = [:]
        for entry in envelope.updates ?? [] {
            guard let adapter = entry.adapterId?.trimmingCharacters(in: .whitespacesAndNewlines), !adapter.isEmpty,
                  let available = entry.availableVersion, !available.isEmpty else { continue }
            byAdapter[adapter] = AdapterUpdate(adapterID: adapter, currentVersion: entry.currentVersion ?? "",
                                               availableVersion: available,
                                               manifestSHA256: entry.manifestSHA256 ?? "")
        }
        return byAdapter.values.sorted { $0.adapterID < $1.adapterID }
    }
}

enum AdapterUpdateStream {
    static let path = "/v1/catalog/notices/events"
    /// A notice frame is small. These bounds keep a misbehaving service from growing the buffer.
    static let lineLimit = 1 << 20
    static let eventLimit = 1 << 20

    enum Failure: Error, Equatable {
        /// The service predates catalog notices (404). Conversations are unaffected.
        case unsupported
        /// The feed ended. The feed model reconnects.
        case disconnected
    }

    /// Turns the transport's bytes into snapshots. Heartbeat comments are skipped by the parser.
    struct Reader {
        enum Output: Equatable {
            case updates([AdapterUpdate])
            case unsupported
        }

        private var parser = AGUIEventStreamParser(lineLimit: AdapterUpdateStream.lineLimit,
                                                   eventLimit: AdapterUpdateStream.eventLimit)

        /// A frame that cannot be read is skipped and the last set stays in place. An oversized
        /// line or event throws, which ends the connection.
        mutating func consume(_ byte: UInt8) throws -> Output? {
            switch try parser.consume(byte) {
            case nil: nil
            case .status(404)?: .unsupported
            case .status?: nil
            case .event(let frame)?: (try? AdapterUpdateSnapshot.decode(frame)).map(Output.updates)
            }
        }
    }

    /// One connection. Each element is the complete current set. It always ends by throwing:
    /// `unsupported`, `disconnected`, or a transport or framing error.
    static func connect(socket: String) -> AsyncThrowingStream<[AdapterUpdate], Error> {
        // Only the newest set matters, so an unread one is replaced and nothing accumulates.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { output in
            let producer = Task.detached(priority: .utility) {
                do {
                    try await read(socket: socket) { output.yield($0) }
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in producer.cancel() }
        }
    }

    private static func read(socket: String, yield: ([AdapterUpdate]) -> Void) async throws {
        let client = Process()
        let pipe = Pipe()
        client.executableURL = URL(filePath: "/usr/bin/curl")
        // No bearer credential: the owner socket is the boundary. The service heartbeats with
        // comments; a feed silent for a minute is treated as gone and reopened.
        client.arguments = [
            "--disable", "--silent", "--fail", "--no-buffer", "--noproxy", "*",
            "--connect-timeout", "3", "--speed-limit", "1", "--speed-time", "60",
            "--unix-socket", socket, "--header", "Accept: text/event-stream",
            "--write-out", "\ncommander-http-status: %{http_code}\n",
            "http://localhost\(path)"
        ]
        client.standardOutput = pipe
        client.standardError = FileHandle.nullDevice
        try client.run()
        let transfer = Transfer(client)
        defer { transfer.end() }
        _ = try? pipe.fileHandleForWriting.close()
        try await withTaskCancellationHandler {
            var reader = Reader()
            for try await byte in pipe.fileHandleForReading.bytes {
                guard let output = try reader.consume(byte) else { continue }
                try Task.checkCancellation()
                switch output {
                case .unsupported: throw Failure.unsupported
                case .updates(let updates): yield(updates)
                }
            }
            try Task.checkCancellation()
            throw Failure.disconnected
        } onCancel: {
            transfer.end()
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let process: Process

        init(_ process: Process) { self.process = process }

        func end() {
            if process.isRunning { process.terminate() }
        }
    }
}

/// The staged updates the service reports, kept by one subscription. A disconnect keeps the last
/// set on screen; the snapshot that opens the next connection replaces it whole, so an update that
/// was activated or withdrawn meanwhile disappears.
@Observable @MainActor
final class AdapterUpdateFeed {
    enum Link: Equatable {
        case connecting
        case live
        /// The connection dropped after a snapshot. The last set is still shown.
        case reconnecting
        /// The service has no catalog notices. Nothing is shown.
        case unsupported
    }

    typealias Connect = @Sendable () -> AsyncThrowingStream<[AdapterUpdate], Error>
    typealias Pause = @Sendable (_ failures: Int) async throws -> Void

    private(set) var updates: [AdapterUpdate] = []
    private(set) var link: Link = .connecting

    @ObservationIgnored private let connect: Connect?
    @ObservationIgnored private let pause: Pause
    /// The call that holds the one subscription, and the calls waiting to take it over, in order.
    @ObservationIgnored private var owner: Int?
    @ObservationIgnored private var standby: [(call: Int, wake: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var lastCall = 0

    /// Failures in a row after which an old service is asked again only at the longest interval.
    static let unsupportedFailures = 6

    init(connect: @escaping Connect, pause: @escaping Pause = AdapterUpdateFeed.sleep) {
        self.connect = connect
        self.pause = pause
    }

    /// A fixed set for previews and fixtures. It never connects.
    init(fixture updates: [AdapterUpdate]) {
        connect = nil
        pause = { _ in }
        self.updates = updates
        link = .live
    }

    /// 1, 2, 4, 8, 16 and then 30 seconds between attempts.
    nonisolated static func delay(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(max(failures - 1, 0), 5)))
    }

    nonisolated static let sleep: Pause = { failures in
        try await Task.sleep(for: delay(afterFailures: failures))
    }

    /// Replaces the set. An equal set changes nothing, so views are not invalidated.
    func apply(_ snapshot: [AdapterUpdate]) {
        if updates != snapshot { updates = snapshot }
    }

    /// Follows the notices until the calling task is cancelled. There is only ever one
    /// subscription: a call made while another holds it waits, without connecting, and takes over
    /// when that call returns. Closing and reopening the window cancels the old view task and
    /// starts a new one in either order; the new call either connects at once or waits for the
    /// cancelled one to unwind, so the feed is never left without a subscription.
    func follow() async {
        guard let connect else { return }
        lastCall += 1
        let call = lastCall
        guard await acquire(call) else { return }
        defer { release(call) }
        var failures = 0
        while !Task.isCancelled {
            do {
                for try await snapshot in connect() {
                    failures = 0
                    link = .live
                    apply(snapshot)
                }
            } catch AdapterUpdateStream.Failure.unsupported {
                apply([])
                link = .unsupported
                failures = max(failures, Self.unsupportedFailures - 1)
            } catch {
                // Any other end is a lost connection. The next snapshot reconciles.
            }
            guard !Task.isCancelled else { return }
            if link == .live { link = .reconnecting }
            failures += 1
            do { try await pause(failures) } catch { return }
        }
    }

    /// Makes `call` the owner, at once or when every earlier call has returned. False when the
    /// calling task is cancelled first; that call then never connects.
    private func acquire(_ call: Int) async -> Bool {
        if owner == nil {
            owner = call
            return true
        }
        guard !Task.isCancelled else { return false }
        // The waiter is queued on the main actor before this task suspends, and a withdrawal runs
        // on the main actor after that, so a cancellation arriving at any point finds and wakes it.
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake in standby.append((call, wake)) }
        } onCancel: {
            Task { @MainActor in self.withdraw(call) }
        }
        return owner == call
    }

    /// Hands the subscription to the next waiting call, if any.
    private func release(_ call: Int) {
        guard owner == call else { return }
        guard !standby.isEmpty else {
            owner = nil
            return
        }
        let next = standby.removeFirst()
        owner = next.call
        next.wake.resume()
    }

    /// Wakes a waiting call whose task was cancelled. A call already handed the subscription is no
    /// longer waiting; it sees the cancellation, returns and hands the subscription on.
    private func withdraw(_ call: Int) {
        guard let index = standby.firstIndex(where: { $0.call == call }) else { return }
        standby.remove(at: index).wake.resume()
    }
}

// MARK: - Views

/// Compact title-bar notice. One update reads “Adapter update”; several read “N adapter updates”.
/// Either opens the list. The control is neutral, not amber: it is advice, not a pending decision.
struct AdapterUpdateNotice: View {
    let updates: [AdapterUpdate]
    var isReconnecting = false
    @State private var showingList = false

    static func title(count: Int) -> String {
        count == 1 ? "Adapter update" : "\(count) adapter updates"
    }

    /// What VoiceOver reads after the title, and the help tag: every adapter with both versions.
    static func summary(_ updates: [AdapterUpdate]) -> String {
        updates.map { "\($0.adapterID) \($0.currentLabel) to \($0.availableVersion)" }.joined(separator: "; ")
    }

    var body: some View {
        Button { showingList.toggle() } label: {
            Label(Self.title(count: updates.count), systemImage: "shippingbox")
                .labelStyle(.titleAndIcon)
        }
        .help("Staged, not active: \(Self.summary(updates))")
        .accessibilityLabel(Self.title(count: updates.count))
        .accessibilityValue(Self.summary(updates))
        .accessibilityHint("Shows the staged versions. Activation is a separate step.")
        .popover(isPresented: $showingList, arrowEdge: .bottom) {
            AdapterUpdateList(updates: updates, isReconnecting: isReconnecting)
        }
    }
}

/// The staged updates. Semantic inks keep it legible in either appearance and with Increase Contrast.
struct AdapterUpdateList: View {
    let updates: [AdapterUpdate]
    var isReconnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(updates.count == 1 ? "Adapter update staged" : "\(updates.count) adapter updates staged")
                    .font(TypeRole.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("A catalog refresh verified and staged these versions. Nothing changes until an update is activated.")
                    .font(TypeRole.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A short list sizes the popover to its rows; a long one scrolls inside a fixed height.
            if updates.count > Self.rowsWithoutScrolling {
                ScrollView { rows }.frame(height: 300)
            } else {
                rows
            }
            if isReconnecting {
                Label("Reconnecting to the local service. This is the last list it sent.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(TypeRole.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.l)
        .frame(width: 340, alignment: .leading)
    }

    static let rowsWithoutScrolling = 4

    /// Lazy so a long list only builds the rows in view.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(updates) { update in
                AdapterUpdateRow(update: update)
                    .padding(.vertical, Space.s)
                if update.id != updates.last?.id { Divider() }
            }
        }
    }
}

/// One adapter: its ID, the current and the staged version, and the manifest digest.
struct AdapterUpdateRow: View {
    let update: AdapterUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(update.adapterID)
                .font(TypeRole.label)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(update.currentLabel).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(update.availableVersion).fontWeight(.semibold)
                Text("staged").font(TypeRole.caption).foregroundStyle(.secondary)
            }
            .font(TypeRole.monoID)
            .lineLimit(1)
            if !update.manifestSHA256.isEmpty {
                Text("manifest \(update.shortManifest)…")
                    .font(TypeRole.monoMeta)
                    .foregroundStyle(.secondary)
                    .help("Manifest SHA-256 \(update.manifestSHA256)")
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(update.adapterID)
        .accessibilityValue("current \(update.currentLabel), staged \(update.availableVersion), not active")
    }
}

/// Title-bar slot for the notice. It is absent while there is nothing staged.
struct AdapterUpdateToolbarItem: ToolbarContent {
    let feed: AdapterUpdateFeed

    var body: some ToolbarContent {
        if !feed.updates.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                AdapterUpdateNotice(updates: feed.updates, isReconnecting: feed.link == .reconnecting)
            }
        }
    }
}
