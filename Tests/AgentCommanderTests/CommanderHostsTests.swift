import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// Headless Commander hosts: the list and event contracts of `agentctl host`, the hosts model's
// connection states, and that the selected host's socket reaches every client path. No test here
// starts agentctl, SSH or the app.

/// A connect process the test drives: it yields the events and records that it was stopped.
private final class FakeConnect: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: AsyncStream<HostConnectEvent>.Continuation] = [:]
    private var stoppedHosts: [String] = []
    private var openedHosts: [String] = []

    var stopped: [String] { lock.withLock { stoppedHosts } }
    var opened: [String] { lock.withLock { openedHosts } }

    func open(_ destination: String) -> HostConnection {
        let (events, continuation) = AsyncStream<HostConnectEvent>.makeStream()
        lock.withLock {
            continuations[destination] = continuation
            openedHosts.append(destination)
        }
        return HostConnection(events: events, stop: { [weak self] in
            self?.lock.withLock { self?.stoppedHosts.append(destination) }
            continuation.finish()
        })
    }

    func send(_ line: String, to destination: String) {
        guard let event = HostConnectEvent(line: line) else { return }
        _ = lock.withLock { continuations[destination] }?.yield(event)
    }

    func exit(_ destination: String) { lock.withLock { continuations[destination] }?.finish() }
}

/// A Unix socket that records the path of each HTTP request it is sent, then refuses it.
private final class RecordingSocket: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var seen: [String] = []

    var paths: [String] { lock.withLock { seen } }

    init() throws {
        path = NSTemporaryDirectory() + "ach-\(getpid())-\(UInt32.random(in: 0..<999_999)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        try #require(path.utf8.count < capacity)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 16) == 0)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var head = [UInt8]()
                var byte = [UInt8](repeating: 0, count: 1024)
                while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
                    let count = read(client, &byte, byte.count)
                    guard count > 0 else { break }
                    head.append(contentsOf: byte[0..<count])
                }
                let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = line.split(separator: " ")
                if parts.count > 1 { self?.lock.withLock { self?.seen.append(String(parts[1])) } }
                let reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    deinit {
        close(descriptor)
        unlink(path)
    }
}

@MainActor @Suite struct CommanderHostsTests {
    static let listJSON = """
    [{"destination":"acx-headless","options":["-F","/path"],"version":"v0.0.6-test.1","api":1,"updated":"2026-11-26T18:05:25Z"}]
    """
    static let ready = #"{"event":"ready","destination":"acx-headless","socket":"/tmp/hosts/7904df2629a0.sock","version":"v0.0.6-test.1","api":1}"#
    static let disconnected = #"{"event":"disconnected","destination":"acx-headless","detail":"ssh: connection reset"}"#
    static let failed = #"{"event":"failed","destination":"acx-headless","detail":"host API 2 is newer than this app's API 1"}"#

    /// Waits for the model's listener to take what the fake sent.
    static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    fileprivate static func model(hosts: [CommanderHost] = [CommanderHost(destination: "acx-headless", version: "v0.0.6-test.1", api: 1)])
        -> (CommanderHostsModel, FakeConnect, ServiceEndpoint) {
        let fake = FakeConnect()
        let endpoint = ServiceEndpoint(environment: ["AGENT_COMMANDER_SOCKET": "/tmp/local.sock"])
        let model = CommanderHostsModel(endpoint: endpoint,
                                        service: CommanderHostsService(list: { hosts }, connect: { fake.open($0) }))
        return (model, fake, endpoint)
    }

    // MARK: The agentctl contract

    @Test func readsTheHostList() throws {
        let hosts = try CommanderHost.list(json: Data(Self.listJSON.utf8))
        #expect(hosts == [CommanderHost(destination: "acx-headless", options: ["-F", "/path"], version: "v0.0.6-test.1",
                                        api: 1, updated: "2026-11-26T18:05:25Z")])
        #expect(try CommanderHost.list(json: Data("[]\n".utf8)).isEmpty)
        #expect(try CommanderHost.list(json: Data()).isEmpty)
        #expect(try CommanderHost.list(json: Data("null".utf8)).isEmpty)
        // A host deployed by an older agentctl has only its destination.
        #expect(try CommanderHost.list(json: Data(#"[{"destination":"lab-02"}]"#.utf8)) == [CommanderHost(destination: "lab-02")])
        #expect(throws: (any Error).self) { try CommanderHost.list(json: Data("not json".utf8)) }
    }

    @Test func readsEachConnectEvent() {
        #expect(HostConnectEvent(line: Self.ready) == .ready(destination: "acx-headless", socket: "/tmp/hosts/7904df2629a0.sock",
                                                             version: "v0.0.6-test.1", api: 1))
        #expect(HostConnectEvent(line: Self.disconnected) == .disconnected(destination: "acx-headless", detail: "ssh: connection reset"))
        #expect(HostConnectEvent(line: Self.failed)
                == .failed(destination: "acx-headless", detail: "host API 2 is newer than this app's API 1"))
        // Anything else on stdout is not an event: a blank line, prose, an event not known yet, a ready with no socket.
        for line in ["", "  ", "connecting…", #"{"event":"progress","destination":"x"}"#, #"{"event":"ready","destination":"x"}"#] {
            #expect(HostConnectEvent(line: line) == nil)
        }
    }

    // MARK: The hosts model

    @Test func thisMacIsFirstAndInUseUntilAHostAnswers() async {
        let (model, fake, endpoint) = Self.model()
        await model.refresh()
        var entries = model.entries()
        #expect(entries.map(\.name) == ["This Mac", "acx-headless"])
        #expect(entries[0].isInUse && entries[0].state == .connected)
        #expect(entries[1].state == .idle && entries[1].kind == "Headless · v0.0.6-test.1")

        var changes = 0
        model.serviceChanged = { changes += 1 }
        model.use("acx-headless")
        entries = model.entries()
        #expect(entries[1].state == .connecting && !entries[1].isInUse)
        // Nothing moves until the forwarded socket answers.
        #expect(entries[0].isInUse && endpoint.socket == "/tmp/local.sock" && changes == 0)
        #expect(fake.opened == ["acx-headless"])
    }

    @Test func followsReadyDisconnectedReady() async {
        let (model, fake, endpoint) = Self.model()
        await model.refresh()
        var changes = 0, interrupted: [String] = [], resumed = 0
        model.serviceChanged = { changes += 1 }
        model.serviceInterrupted = { interrupted.append($0) }
        model.serviceResumed = { resumed += 1 }
        model.use("acx-headless")

        fake.send(Self.ready, to: "acx-headless")
        await Self.settle { model.inUse != nil }
        // The first answer moves the endpoint. It is not a resumed connection.
        #expect(interrupted.isEmpty && resumed == 0)
        #expect(model.link == .connected(version: "v0.0.6-test.1"))
        #expect(endpoint.remote == ServiceEndpoint.Remote(destination: "acx-headless", socket: "/tmp/hosts/7904df2629a0.sock"))
        #expect(changes == 1)
        #expect(model.entries().map(\.isInUse) == [false, true])
        #expect(model.entries()[0].state == .idle)

        fake.send(Self.disconnected, to: "acx-headless")
        await Self.settle { model.link == .disconnected(detail: "ssh: connection reset") }
        let dropped = model.entries()[1]
        #expect(dropped.state == .disconnected && dropped.detail == "ssh: connection reset" && dropped.isInUse)
        // agentctl is retrying: the app stays on the host's socket and nothing restarts.
        #expect(endpoint.socket == "/tmp/hosts/7904df2629a0.sock" && changes == 1)
        // The window is told at once that the service in use is unreachable.
        #expect(interrupted == ["acx-headless"] && resumed == 0)

        fake.send(Self.ready, to: "acx-headless")
        await Self.settle { model.link == .connected(version: "v0.0.6-test.1") }
        #expect(model.entries()[1].state == .connected && model.entries()[1].detail == nil)
        #expect(changes == 1 && fake.stopped.isEmpty)
        // The same socket answers again: the window is told once, so both streams start again.
        #expect(resumed == 1)

        // Back to this Mac: the process is ended and the local socket is used again.
        model.use(nil)
        #expect(fake.stopped == ["acx-headless"])
        #expect(endpoint.remote == nil && endpoint.socket == "/tmp/local.sock" && changes == 2)
        #expect(model.entries().map(\.isInUse) == [true, false])
        #expect(model.entries()[1].state == .idle)
    }

    @Test func aFailedHostShowsItsDetailAndTheAppStaysOnThisMac() async {
        let (model, fake, endpoint) = Self.model()
        await model.refresh()
        var changes = 0
        model.serviceChanged = { changes += 1 }
        model.use("acx-headless")
        fake.send(Self.failed, to: "acx-headless")
        fake.exit("acx-headless")
        await Self.settle { model.link == .failed(detail: "host API 2 is newer than this app's API 1") }

        let entries = model.entries()
        #expect(entries[1].state == .failed && entries[1].detail == "host API 2 is newer than this app's API 1")
        #expect(entries[0].isInUse && endpoint.remote == nil && changes == 0)
        #expect(fake.stopped == ["acx-headless"])

        // Trying again clears the old failure and opens a new connection.
        model.use("acx-headless")
        #expect(model.entries()[1].state == .connecting && model.entries()[1].detail == nil)
        #expect(fake.opened == ["acx-headless", "acx-headless"])
    }

    @Test func aFailureAfterReadyReturnsToThisMac() async {
        let (model, fake, endpoint) = Self.model()
        var changes = 0
        model.serviceChanged = { changes += 1 }
        model.use("acx-headless")
        fake.send(Self.ready, to: "acx-headless")
        await Self.settle { model.inUse != nil }
        // The process exits without saying why.
        fake.exit("acx-headless")
        await Self.settle { model.inUse == nil }
        #expect(model.link == .failed(detail: "The connection to acx-headless ended."))
        #expect(endpoint.remote == nil && changes == 2)
        // The host is no longer listed, and keeps its row while it is the one chosen.
        #expect(model.entries().map(\.name) == ["This Mac", "acx-headless"])
    }

    @Test func eventsOfAConnectionThatWasLeftAreIgnored() async {
        let (model, fake, endpoint) = Self.model(hosts: [CommanderHost(destination: "a"), CommanderHost(destination: "b")])
        await model.refresh()
        model.use("a")
        model.use("b")
        #expect(fake.stopped == ["a"])
        fake.send(#"{"event":"ready","destination":"b","socket":"/tmp/b.sock"}"#, to: "b")
        await Self.settle { model.inUse == "b" }
        #expect(endpoint.socket == "/tmp/b.sock")
        #expect(model.entries().map(\.state) == [.idle, .idle, .connected])
    }

    @Test func aListThatCannotBeReadKeepsThisMac() async {
        let model = CommanderHostsModel(endpoint: ServiceEndpoint(environment: [:]),
                                        service: CommanderHostsService(list: { throw ServiceError.offline("no agentctl") },
                                                                       connect: { _ in HostConnection(events: AsyncStream { $0.finish() }, stop: {}) }))
        await model.refresh()
        #expect(model.listError == "no agentctl")
        #expect(model.entries().map(\.name) == ["This Mac"])
    }

    // MARK: The selected socket reaches every client path

    @Test func theEndpointNamesTheSocketForEveryChild() {
        let endpoint = ServiceEndpoint(environment: ["AGENT_COMMANDER_HOME": "/tmp/home"])
        #expect(endpoint.socket == "/tmp/home/service.sock")
        #expect(endpoint.agentctlEnvironment(from: ["AC_SOCKET": "/tmp/alias.sock"]) == ["AC_SOCKET": "/tmp/alias.sock"])

        let host = ServiceEndpoint.Remote(destination: "acx-headless", socket: "/tmp/hosts/x.sock")
        let moved = endpoint.select(host), movedAgain = endpoint.select(host)
        #expect(moved && !movedAgain)
        #expect(endpoint.socket == "/tmp/hosts/x.sock")
        // agentctl reads only the full name, and the host's socket replaces any local setting.
        #expect(endpoint.agentctlEnvironment(from: ["AC_SOCKET": "/tmp/alias.sock", "AGENT_COMMANDER_SOCKET": "/tmp/local.sock"])
                == ["AGENT_COMMANDER_SOCKET": "/tmp/hosts/x.sock"])
        // The native terminal's agentctl attaches to the selected host's worker.
        let terminal = NativeTerminalLaunch.environment(from: ["AGENT_COMMANDER_SOCKET": "/tmp/local.sock"], endpoint: endpoint)
        #expect(terminal.contains("AGENT_COMMANDER_SOCKET=/tmp/hosts/x.sock"))
        #expect(!terminal.contains("AGENT_COMMANDER_SOCKET=/tmp/local.sock"))

        let back = endpoint.select(nil)
        #expect(back)
        #expect(NativeTerminalLaunch.environment(from: ["AGENT_COMMANDER_SOCKET": "/tmp/local.sock"], endpoint: endpoint)
            .contains("AGENT_COMMANDER_SOCKET=/tmp/local.sock"))
    }

    @Test func everyRequestAndStreamGoesToTheSelectedSocket() async throws {
        let local = try RecordingSocket(), remote = try RecordingSocket()
        let endpoint = ServiceEndpoint(environment: ["AGENT_COMMANDER_SOCKET": local.path])
        let client = ServiceClient(environment: ["AGENT_COMMANDER_CLI": "/usr/bin/false"], endpoint: endpoint)

        func exercise() async {
            _ = try? await client.runs()
            _ = try? await client.workerHistory("w-1", source: .live)
            _ = try? await client.elicitations("w-1")
            _ = try? await client.stop(runID: "r-1")
            do { for try await _ in await client.watchRuns() {} } catch {}
            do { for try await _ in client.watchAdapterUpdates() {} } catch {}
        }
        func kinds(_ socket: RecordingSocket) -> Set<String> {
            Set(socket.paths.map { String($0.split(separator: "?").first ?? "") })
        }
        let all: Set<String> = ["/v1/runs", "/v1/workers/w-1/history", "/v1/workers/w-1/elicitations", "/v1/runs/r-1/stop",
                                "/v1/ag-ui/events", "/v1/catalog/notices/events"]

        await exercise()
        #expect(kinds(local) == all)
        #expect(remote.paths.isEmpty)

        let before = local.paths.count
        endpoint.select(.init(destination: "acx-headless", socket: remote.path))
        #expect(client.currentSocket == remote.path)
        await exercise()
        #expect(kinds(remote) == all)
        #expect(local.paths.count == before)
        // A host's service is never started from this Mac.
        await #expect(throws: ServiceError.self) { try await client.startService() }
    }

    // MARK: A dropped connection and the event streams

    /// A script standing in for `agentctl host connect`: it says `ready`, then stays quiet.
    private static func quietAgentctl() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ach-quiet-\(getpid())-\(UInt32.random(in: 0..<999_999)).sh")
        try "#!/bin/sh\necho '\(ready)'\nexec sleep 30\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The defect: the connect child was read with `FileHandle.bytes`, which reads every handle in
    /// the process through one shared actor. While agentctl was quiet after `ready`, nothing
    /// reached any other reader, so the event streams of the reconnected host never delivered.
    @Test func aQuietConnectChildHoldsUpNoOtherReader() async throws {
        let script = try Self.quietAgentctl()
        defer { try? FileManager.default.removeItem(at: script) }
        let connection = CommanderHostsService.live(agentctl: script, environment: [:]).connect("acx-headless")
        defer { connection.stop() }
        var events = connection.events.makeAsyncIterator()
        let first = await events.next()
        #expect(first == HostConnectEvent(line: Self.ready))

        // agentctl now waits, with its output open. Another handle read the system's way, as the
        // event streams were, and one read the app's way must both still deliver.
        let system = Pipe(), own = Pipe()
        let arrived = Task.detached { () -> [UInt8] in
            var got: [UInt8] = []
            for try await byte in system.fileHandleForReading.bytes { got.append(byte) }
            for await chunk in own.fileHandleForReading.ownChunks { got.append(contentsOf: chunk) }
            return got
        }
        // Give the connect child's reader time to be waiting on its quiet handle.
        try await Task.sleep(for: .milliseconds(200))
        try system.fileHandleForWriting.write(contentsOf: Data("a".utf8))
        try system.fileHandleForWriting.close()
        try own.fileHandleForWriting.write(contentsOf: Data("b".utf8))
        try own.fileHandleForWriting.close()
        let deadline = Task.detached { () -> [UInt8]? in
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        let result = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask { try? await arrived.value }
            group.addTask { await deadline.value }
            let winner = await group.next() ?? nil
            arrived.cancel()
            deadline.cancel()
            return winner
        }
        #expect(result == Array("ab".utf8), "a quiet connect child must not hold up another reader")
    }

    @Test func linesAreReadAcrossChunksAndAtTheEnd() async {
        var buffer = LineBuffer()
        #expect(buffer.take(Data("{\"event\":\"rea".utf8)).isEmpty)
        #expect(buffer.take(Data("dy\"}\n{\"event\":\"failed\"}\nrest".utf8)) == [#"{"event":"ready"}"#, #"{"event":"failed"}"#])
        #expect(buffer.rest() == "rest" && buffer.rest() == nil)

        let pipe = Pipe()
        let lines = pipe.fileHandleForReading.ownLines
        try? pipe.fileHandleForWriting.write(contentsOf: Data("one\ntwo\nthree".utf8))
        try? pipe.fileHandleForWriting.close()
        var read: [String] = []
        for await line in lines { read.append(line) }
        #expect(read == ["one", "two", "three"])
    }

    @Test func aDropTakesTheServiceOfflineAndAnAnswerStartsTheStreamsAgain() {
        let model = CockpitModel(endpoint: ServiceEndpoint(environment: ["AGENT_COMMANDER_SOCKET": "/tmp/local.sock"]))
        model.connection = .online
        let generation = model.serviceGeneration

        model.serviceInterrupted(host: "acx-headless")
        #expect(model.connection == .offline("The connection to acx-headless dropped. Reconnecting."))
        // The streams are not restarted while the host is away, and the runs stay.
        #expect(model.serviceGeneration == generation)

        model.serviceResumed()
        // The window restarts both subscriptions on a new generation, and the next answer shows.
        #expect(model.serviceGeneration == generation + 1)
        #expect(model.connection == .connecting)
    }

    // MARK: Where the choice sits

    @Test func hostsIsAPlaceOfTheWorkspaceGroup() {
        let network = ShellNetwork()
        let without = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: LiveShell.hosts,
                                           needsYou: 0, network: network)
        #expect(without.place(LiveShell.hosts) == nil)

        let navigation = LiveShell.navigation(runs: [], openRunPath: nil, composing: false, place: LiveShell.hosts,
                                              needsYou: 0, network: network, showsHosts: true, serviceHost: "acx-headless")
        #expect(navigation.selection == LiveShell.hosts)
        #expect(navigation.crumbs == ["Agents", "Workspace", "Hosts"])
        #expect(navigation.place(LiveShell.hosts)?.badge == "acx-headless")
        #expect(navigation.modes.first?.sections.first?.placeIDs == [LiveShell.needsYou, LiveShell.wall, LiveShell.newRun, LiveShell.hosts])
        #expect(!LiveShell.showsWall(LiveShell.hosts))
    }

    @Test func theToolbarNamesAHostOnlyWhileOneIsInUse() {
        let mac = CommanderHostEntry(id: CommanderHostEntry.localID, destination: nil, name: "This Mac", kind: "Local service",
                                     typeLabel: "Local service", symbol: "desktopcomputer", state: .connected, isInUse: true)
        #expect(CommanderHostsContext(entries: [mac]).serviceName == nil)
        #expect(CommanderHostEntry.State(.offline("gone")) == .disconnected)
        #expect(CommanderHostDetail.deployed("not a time") == "not a time")
        #expect(CommanderHostDetail.deployed(nil) == "Unknown")
    }

    @Test func theInspectorsWordsFitTheirPlace() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_US")
        let now = try Date("2026-11-26T19:00:00Z", strategy: .iso8601)
        // This year: the day and the time, no year ("Nov 26 at 1:05 PM"). An earlier year: the day and the year.
        #expect(CommanderHostDetail.deployed("2026-11-26T18:05:25Z", now: now, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ") == "Nov 26 at 1:05 PM")
        #expect(CommanderHostDetail.deployed("2025-03-02T18:05:25Z", now: now, calendar: calendar, locale: locale) == "Mar 2, 2025")

        func host(_ state: CommanderHostEntry.State, inUse: Bool) -> CommanderHostEntry {
            CommanderHostEntry(id: "h", destination: "h", name: "h", kind: "Headless host", typeLabel: "Headless host",
                               symbol: "server.rack", state: state, isInUse: inUse)
        }
        // Every footer line sits beside its action on one line; the rest is the tooltip's.
        for entry in [host(.disconnected, inUse: true), host(.connecting, inUse: false), host(.connected, inUse: true),
                      host(.idle, inUse: false), host(.failed, inUse: false)] {
            #expect(CommanderHostDetail.note(for: entry).count <= 56)
        }
        #expect(CommanderHostDetail.note(for: host(.disconnected, inUse: true)) == "Waiting for SSH. The host keeps its workers running.")
        #expect(CommanderHostDetail.noteHelp(for: host(.disconnected, inUse: true))?.contains("holds their questions") == true)
        #expect(CommanderHostDetail.noteHelp(for: host(.connected, inUse: true)) == nil)

        // The Hosts row's figure is a name and gives way; a tally never does.
        #expect(CommanderPlace(id: "hosts", title: "Hosts", mark: .symbol("desktopcomputer"), figure: "acx-headless").figureIsName)
        #expect(!CommanderPlace(id: "servers", title: "Servers", mark: .symbol("server.rack"), figure: "2/3").figureIsName)
        #expect(!CommanderPlace(id: "runs", title: "Runs", mark: .symbol("plus"), count: 3).figureIsName)
    }

    // MARK: Pictures

    /// HOSTS_RENDER_DIR=<folder> swift test --filter CommanderHosts draws the page in both themes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTS_RENDER_DIR"] != nil)) func drawsTheHostsPage() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HOSTS_RENDER_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let mac = CommanderHostEntry(id: CommanderHostEntry.localID, destination: nil, name: "This Mac", kind: "Local service",
                                     typeLabel: "Local service", symbol: "desktopcomputer", state: .idle, isInUse: false)
        func host(_ name: String, _ state: CommanderHostEntry.State, inUse: Bool = false, detail: String? = nil) -> CommanderHostEntry {
            CommanderHostEntry(id: name, destination: name, name: name, kind: "Headless · v0.0.6-test.1",
                               typeLabel: "Headless host", symbol: "server.rack", state: state, isInUse: inUse,
                               version: "v0.0.6-test.1", api: 1, updated: "2026-11-26T18:05:25Z", detail: detail)
        }
        let connected = [mac, host("acx-headless", .connected, inUse: true), host("lab-02", .idle)]
        let failed = [CommanderHostEntry(id: CommanderHostEntry.localID, destination: nil, name: "This Mac", kind: "Local service",
                                         typeLabel: "Local service", symbol: "desktopcomputer", state: .connected, isInUse: true),
                      host("acx-headless", .failed, detail: "The host's API 2 is newer than this app's API 1. Update Agent Commander.")]
        for id in ThemeID.allCases {
            let theme = Theme.named(id)
            try await ThemeRenderTests.write(CommanderHostsPage(hosts: CommanderHostsContext(entries: connected)),
                                             "commander-hosts-connected", theme: theme, to: folder)
            try await ThemeRenderTests.write(
                HStack(alignment: .top, spacing: 20) {
                    CommanderHostList(entries: failed, shown: "acx-headless") { _ in }.frame(width: 382)
                    CommanderHostDetail(entry: failed[1]) { _ in }
                }.padding(32).frame(maxHeight: .infinity, alignment: .top),
                "commander-hosts-failed", theme: theme, to: folder)
            // The states the inspector and the Hosts row must fit: a dropped host beside
            // Disconnect, and the row with a short and a long host in use.
            func row(_ figure: String) -> some View {
                ShellPlaceRow(item: .init(place: CommanderPlace(id: "hosts", title: "Hosts", mark: .symbol("desktopcomputer"),
                                                                figure: figure), isSelected: true, shortcut: nil)) { _ in }
                    .frame(width: 180)
            }
            try await ThemeRenderTests.write(
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        row("acx-headless")
                        row("ops@build-server-01.example.com")
                    }
                    CommanderHostDetail(entry: host("acx-headless", .disconnected, inUse: true,
                                                    detail: "ssh: exit status 255: Connection to 127.0.0.1 closed by remote host.")) { _ in }
                        .frame(width: 585)
                }.padding(32).frame(maxHeight: .infinity, alignment: .top),
                "commander-hosts-dropped", theme: theme, to: folder)
        }
    }
}
