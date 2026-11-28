import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// "Open at line N" on an opened Pretty line: the service's exact `location` member, the checks
// between a reported path and a file on this Mac, the command's arguments, and the opener, which
// checks again at the press and runs nothing for a location it refuses.

/// A worker's checkout on disk, with what lies beside it.
private struct Checkout {
    let base: URL
    let root: URL
    let file: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "tool-location-\(UUID().uuidString)")
        root = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        file = root.appending(path: "src/compact-1.txt")
        try Data("one\ntwo\n".utf8).write(to: file)
        outside = base.appending(path: "secret.txt")
        try Data("not in the checkout".utf8).write(to: outside)
    }

    var rootPath: String { root.path(percentEncoded: false) }

    func scope(serviceIsLocal: Bool = true, host: String = "localhost", checkout: String? = nil) -> ToolLocationScope {
        ToolLocationScope(serviceIsLocal: serviceIsLocal, host: host, checkout: checkout ?? rootPath)
    }

    func location(_ url: URL, line: Int = 7) throws -> ToolLocation {
        try #require(ToolLocation(path: url.path(percentEncoded: false), line: line))
    }

    func canonical(_ url: URL) throws -> String {
        try #require(ToolLocationPaths.canonical(url.path(percentEncoded: false)))
    }

    func link(_ name: String, to destination: URL) throws -> URL {
        let link = root.appending(path: name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        return link
    }
}

/// What an opener was asked to run.
private final class Runs: Sendable {
    private let log = Mutex<[[String]]>([])
    var all: [[String]] { log.withLock { $0 } }

    func opener(result: ToolLocationOpener.Run = .exited(0), installed: Bool = true) -> ToolLocationOpener {
        ToolLocationOpener(isInstalled: { installed }, run: { executable, arguments in
            self.log.withLock { $0.append([executable] + arguments) }
            return result
        })
    }
}

private func summary(location json: String?, kind: String = "tool") throws -> ToolDetailSummary {
    let member = json.map { #","location":\#($0)"# } ?? ""
    let text = #"{"key":"toolu_01","kind":"\#(kind)","name":"Read","title":"Read compact-1.txt","revision":4\#(member)}"#
    return try JSONDecoder().decode(ToolDetailSummary.self, from: Data(text.utf8))
}

@Suite struct ToolLocationContractTests {
    @Test func readsTheOwnersExactLocation() throws {
        let record = try summary(location: #"{"path":"/private/tmp/acp/compact-1.txt","line":1}"#)
        #expect(record.location?.value == ToolLocation(path: "/private/tmp/acp/compact-1.txt", line: 1))
        #expect(record.openableLocation?.path == "/private/tmp/acp/compact-1.txt")
        #expect(record.openableLocation?.line == 1)
        // The record's other members are read as before.
        #expect(record.name == "Read")
        #expect(record.revision == 4)
    }

    @Test func readsTheLargestLineTheWireCarries() throws {
        let record = try summary(location: #"{"path":"/repo/a.txt","line":4294967295}"#)
        #expect(record.openableLocation == ToolLocation(path: "/repo/a.txt", line: 4_294_967_295))
        let command = ToolLocationCommand(ToolLocationTarget(path: "/repo/a.txt", line: 4_294_967_295))
        #expect(command.arguments == ["--line", "4294967295", "/repo/a.txt"])
    }

    @Test func aRecordWithoutALocationOffersNone() throws {
        let record = try summary(location: nil)
        #expect(record.location == nil)
        #expect(record.openableLocation == nil)
    }

    @Test(arguments: [
        #"{"path":"","line":0}"#,                              // the service's explicit clearing
        #"{"path":"/repo/a.txt","line":0}"#,
        #"{"path":"/repo/a.txt","line":-3}"#,
        #"{"path":"/repo/a.txt","line":7.5}"#,
        #"{"path":"/repo/a.txt","line":"7"}"#,
        #"{"path":"/repo/a.txt","line":4294967296}"#,          // one past the unsigned 32-bit maximum
        #"{"path":"/repo/a.txt"}"#,
        #"{"line":7}"#,
        #"{"path":"src/a.txt","line":7}"#,                      // relative
        #"{"path":"~/a.txt","line":7}"#,
        #"{"path":"file:///repo/a.txt","line":7}"#,             // an address, not a path
        #"{"path":"/repo/a\nb.txt","line":7}"#,                 // a control character
        #"{"path":"/repo/a\u0000.txt","line":7}"#,
        #"{"path":7,"line":7}"#,
        #"[{"path":"/repo/a.txt","line":7}]"#,                  // several locations
        #"[{"path":"/repo/a.txt","line":7},{"path":"/repo/b.txt","line":9}]"#,
        #""/repo/a.txt:7""#,
        "null", "7", "true", "{}",
    ])
    func anyOtherShapeHoldsNoLocationAndKeepsItsRecord(json: String) throws {
        let record = try summary(location: json)
        #expect(record.location?.value == nil)
        #expect(record.openableLocation == nil)
        #expect(record.key == "toolu_01")
        #expect(record.name == "Read")
    }

    @Test func onlyAToolCallsRecordOffersItsLocation() throws {
        let location = #"{"path":"/repo/a.txt","line":7}"#
        #expect(try summary(location: location, kind: "tool").openableLocation != nil)
        for kind in ["thought", "plan", "job", "turn_end"] {
            #expect(try summary(location: location, kind: kind).openableLocation == nil)
        }
    }

    @Test func aLocationIsValidByConstruction() {
        #expect(ToolLocation(path: "/repo/a.txt", line: 1) != nil)
        // ACP's line is a 1-based unsigned 32-bit number: its exact maximum, and one past it.
        #expect(ToolLocation(path: "/repo/a.txt", line: 4_294_967_295)?.line == Int(UInt32.max))
        #expect(ToolLocation(path: "/repo/a.txt", line: 4_294_967_296) == nil)
        #expect(ToolLocation(path: "/repo/a.txt", line: 2_147_483_648) != nil)
        #expect(ToolLocation(path: "/repo/a.txt", line: -1) == nil)
        #expect(ToolLocation(path: "/repo/a.txt", line: 0) == nil)
        #expect(ToolLocation(path: "repo/a.txt", line: 1) == nil)
        #expect(ToolLocation(path: "", line: 1) == nil)
        #expect(ToolLocation(path: "/repo/\u{1B}[2J.txt", line: 1) == nil)
        #expect(ToolLocation(path: "/" + String(repeating: "a", count: ToolLocation.pathLimit), line: 1) == nil)
    }

    /// The action is read from the latest summary: a location the service clears later is gone.
    @MainActor @Test func aLaterClearingRemovesTheLocation() async throws {
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, after in
                let location = after == 0 ? #"{"path":"/repo/a.txt","line":7}"# : #"{"path":"","line":0}"#
                let text = #"{"revision":\#(after + 1),"records":[{"key":"toolu_01","kind":"tool","name":"Read","location":\#(location)}]}"#
                return try JSONDecoder().decode(ToolDetailPage.self, from: Data(text.utf8))
            },
            record: { _, key in ToolDetailRecord(key: key, kind: "tool") },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
        await store.refresh(worker: "w-1")
        #expect(store.summary(worker: "w-1", key: "w-1:toolu_01")?.openableLocation == ToolLocation(path: "/repo/a.txt", line: 7))
        // Another worker's console never reads this worker's record.
        #expect(store.summary(worker: "w-2", key: "toolu_01") == nil)
        await store.refresh(worker: "w-1")
        #expect(store.summary(worker: "w-1", key: "w-1:toolu_01")?.openableLocation == nil)
    }
}

@Suite struct ToolLocationPathTests {
    @Test func containmentComparesWholeComponents() {
        #expect(ToolLocationPaths.contains(root: "/repo", file: "/repo/a.txt"))
        #expect(ToolLocationPaths.contains(root: "/Users/me/repo", file: "/Users/me/repo/src/deep/a.txt"))
        #expect(!ToolLocationPaths.contains(root: "/repo", file: "/repo-other/a.txt"))
        #expect(!ToolLocationPaths.contains(root: "/repo", file: "/repository/a.txt"))
        #expect(!ToolLocationPaths.contains(root: "/repo", file: "/repo"))
        #expect(!ToolLocationPaths.contains(root: "/repo/src", file: "/repo/a.txt"))
        // The root directory is never a checkout.
        #expect(!ToolLocationPaths.contains(root: "/", file: "/etc/passwd"))
        #expect(!ToolLocationPaths.contains(root: "", file: "/etc/passwd"))
    }

    @Test func opensARegularFileInsideTheCheckout() throws {
        let checkout = try Checkout()
        let target = try ToolLocationResolver.resolve(checkout.location(checkout.file, line: 2), scope: checkout.scope()).get()
        #expect(target == ToolLocationTarget(path: try checkout.canonical(checkout.file), line: 2))
        // The temporary folder is itself behind a link: the target is the resolved path.
        #expect(target.path.hasPrefix("/private/"))
    }

    @Test func aPathIsCanonicalBeforeItIsCompared() throws {
        let checkout = try Checkout()
        let inside = try #require(ToolLocation(path: checkout.rootPath + "/src/../src/./compact-1.txt", line: 1))
        #expect(try ToolLocationResolver.resolve(inside, scope: checkout.scope()).get().path == checkout.canonical(checkout.file))
        // Text that starts with the checkout and climbs out of it.
        let climbing = try #require(ToolLocation(path: checkout.rootPath + "/src/../../secret.txt", line: 1))
        #expect(ToolLocationResolver.resolve(climbing, scope: checkout.scope()) == .failure(.outsideCheckout))
    }

    @Test func refusesWhatIsNotARegularFileInTheCheckout() throws {
        let checkout = try Checkout()
        let scope = checkout.scope()
        #expect(ToolLocationResolver.resolve(try checkout.location(checkout.root.appending(path: "gone.txt")), scope: scope) == .failure(.missing))
        #expect(ToolLocationResolver.resolve(try checkout.location(checkout.root.appending(path: "src")), scope: scope) == .failure(.notAFile))
        #expect(ToolLocationResolver.resolve(try checkout.location(checkout.root), scope: scope) == .failure(.outsideCheckout))
        #expect(ToolLocationResolver.resolve(try checkout.location(checkout.outside), scope: scope) == .failure(.outsideCheckout))
        // A folder beside the checkout whose name starts with the checkout's.
        let sibling = checkout.base.appending(path: "repo-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sibling.appending(path: "a.txt"))
        #expect(ToolLocationResolver.resolve(try checkout.location(sibling.appending(path: "a.txt")), scope: scope) == .failure(.outsideCheckout))
    }

    @Test func aLinkIsFollowedBeforeTheCheckoutIsChecked() throws {
        let checkout = try Checkout()
        let scope = checkout.scope()
        // A link in the checkout to a file outside it, and a linked folder that leads out.
        let escape = try checkout.link("notes.txt", to: checkout.outside)
        #expect(ToolLocationResolver.resolve(try checkout.location(escape), scope: scope) == .failure(.outsideCheckout))
        let folder = try checkout.link("up", to: checkout.base)
        #expect(ToolLocationResolver.resolve(try checkout.location(folder.appending(path: "secret.txt")), scope: scope) == .failure(.outsideCheckout))
        // A link that stays inside opens the file it names.
        let alias = try checkout.link("alias.txt", to: checkout.file)
        #expect(try ToolLocationResolver.resolve(checkout.location(alias), scope: scope).get().path == checkout.canonical(checkout.file))
        // A link that leads nowhere.
        let dangling = try checkout.link("dangling.txt", to: checkout.root.appending(path: "gone.txt"))
        #expect(ToolLocationResolver.resolve(try checkout.location(dangling), scope: scope) == .failure(.missing))
    }

    @Test func theCheckoutMustBeAFolderOfItsOwn() throws {
        let checkout = try Checkout()
        let location = try checkout.location(checkout.file)
        for root in ["/", "//", "/.", "", "repo", checkout.rootPath + "/gone", checkout.file.path(percentEncoded: false),
                     checkout.rootPath + "\n"] {
            #expect(ToolLocationResolver.resolve(location, scope: checkout.scope(checkout: root)) == .failure(.noCheckout),
                    "checkout \(root.debugDescription)")
        }
        // A checkout that is a link to the root directory is still the root directory.
        let rootLink = checkout.base.appending(path: "everything")
        try FileManager.default.createSymbolicLink(atPath: rootLink.path(percentEncoded: false), withDestinationPath: "/")
        #expect(ToolLocationResolver.resolve(location, scope: checkout.scope(checkout: rootLink.path(percentEncoded: false)))
                == .failure(.noCheckout))
        // A checkout reached through a link is compared resolved, like the file.
        let alias = checkout.base.appending(path: "repo-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout.root)
        #expect(try ToolLocationResolver.resolve(location, scope: checkout.scope(checkout: alias.path(percentEncoded: false))).get().path
                == checkout.canonical(checkout.file))
    }
}

@Suite struct ToolLocationScopeTests {
    @Test func onlyThisMacsServiceAndItsOwnLocalWorker() throws {
        let checkout = try Checkout()
        let location = try checkout.location(checkout.file)
        // A headless host's forwarded service marks its own workers `localhost` too.
        #expect(ToolLocationResolver.resolve(location, scope: checkout.scope(serviceIsLocal: false)) == .failure(.remoteService))
        #expect(ToolLocationResolver.resolve(location, scope: checkout.scope(serviceIsLocal: false, host: "build-01")) == .failure(.remoteService))
        // The marker is compared exactly: no empty host, other case, suffix or address reads as local.
        for host in ["", "build-01", "Localhost", "localhost.", "localhost.local", "localhost:22", "127.0.0.1", "::1",
                     ProcessInfo.processInfo.hostName] {
            let scope = checkout.scope(host: host)
            #expect(!scope.workerIsLocal, "host \(host.debugDescription)")
            #expect(ToolLocationResolver.resolve(location, scope: scope) == .failure(.remoteWorker))
        }
        #expect(checkout.scope().workerIsLocal)
        #expect(!checkout.scope(serviceIsLocal: false).workerIsLocal)
    }

    @Test func theScopeIsTheWorkersOwnHostAndCheckout() {
        func worker(host: String, worktree: String) -> Worker {
            Worker(id: "w-1", name: "reader", role: "worker", parentID: "", runID: "r-1", state: "working",
                   host: host, worktree: worktree, task: "", output: "", error: nil)
        }
        #expect(ToolLocationScope(worker: worker(host: "localhost", worktree: "/repo"), serviceIsLocal: true)
                == ToolLocationScope(serviceIsLocal: true, host: "localhost", checkout: "/repo"))
        let remote = ToolLocationScope(worker: worker(host: "build-01", worktree: "/srv/repo"), serviceIsLocal: true)
        #expect(remote.checkout == "/srv/repo")
        #expect(!remote.workerIsLocal)
    }
}

@Suite struct ToolLocationCommandTests {
    @Test func theCommandIsFixedAndThePathIsOneArgument() {
        #expect(ToolLocationCommand.executable == "/usr/bin/xed")
        let command = ToolLocationCommand(ToolLocationTarget(path: "/Users/me/repo/src/a file.swift", line: 42))
        #expect(command.arguments == ["--line", "42", "/Users/me/repo/src/a file.swift"])
    }

    /// A file's name is data. Whatever it looks like, it reaches the command inside one absolute
    /// path, after the line.
    @Test(arguments: ["--wait", "-l", "--line 9", "-b com.apple.Terminal", "$(touch pwned)", "`id`", "a; rm -rf ~", "a && b",
                      "it's \"quoted\".txt", " leading space", "glob*?.txt", "tab\\t.txt", "ünïcödé 文件.txt", "|pipe", ">out"])
    func aFilesNameIsNeverAnOption(name: String) throws {
        let checkout = try Checkout()
        let file = checkout.root.appending(path: name)
        try Data("x".utf8).write(to: file)
        let target = try ToolLocationResolver.resolve(checkout.location(file, line: 3), scope: checkout.scope()).get()
        let arguments = ToolLocationCommand(target).arguments
        #expect(arguments.count == 3)
        #expect(Array(arguments.prefix(2)) == ["--line", "3"])
        #expect(arguments[2] == (try checkout.canonical(file)))
        #expect(arguments[2].hasPrefix("/"))
        #expect(arguments[2].hasSuffix("/" + name))
    }

    @Test func aNameWithAControlCharacterIsNeverOpened() throws {
        let checkout = try Checkout()
        let odd = checkout.root.appending(path: "a\nb.txt")
        try Data("x".utf8).write(to: odd)
        #expect(ToolLocation(path: odd.path(percentEncoded: false), line: 1) == nil)
        // Reached through a plainly named link, the resolved name is still refused.
        let alias = try checkout.link("plain.txt", to: odd)
        guard case .failure = ToolLocationResolver.resolve(try checkout.location(alias), scope: checkout.scope()) else {
            Issue.record("A file whose resolved name holds a control character was offered")
            return
        }
    }
}

@Suite struct ToolLocationOpenerTests {
    @Test func runsTheFixedCommandOnceForAFileThatPasses() async throws {
        let checkout = try Checkout()
        let runs = Runs()
        let opener = runs.opener()
        let location = try checkout.location(checkout.file, line: 7)
        #expect(opener.offers(location, scope: checkout.scope()))
        #expect(runs.all.isEmpty)
        #expect(await opener.open(location, scope: checkout.scope()) == nil)
        #expect(runs.all == [["/usr/bin/xed", "--line", "7", try checkout.canonical(checkout.file)]])
    }

    @Test func runsNothingForALocationItRefuses() async throws {
        let checkout = try Checkout()
        let runs = Runs()
        let opener = runs.opener()
        let inside = try checkout.location(checkout.file)
        let escape = try checkout.location(checkout.link("notes.txt", to: checkout.outside))
        let refused: [(ToolLocation, ToolLocationScope, ToolLocationError)] = [
            (inside, checkout.scope(serviceIsLocal: false), .remoteService),
            (inside, checkout.scope(host: "build-01"), .remoteWorker),
            (inside, checkout.scope(checkout: "/"), .noCheckout),
            (try checkout.location(checkout.outside), checkout.scope(), .outsideCheckout),
            (escape, checkout.scope(), .outsideCheckout),
            (try checkout.location(checkout.root.appending(path: "src")), checkout.scope(), .notAFile),
            (try checkout.location(checkout.root.appending(path: "gone.txt")), checkout.scope(), .missing),
        ]
        for (location, scope, error) in refused {
            #expect(!opener.offers(location, scope: scope))
            #expect(await opener.open(location, scope: scope) == error)
        }
        #expect(runs.all.isEmpty)
    }

    /// The press checks again: what was offered a moment ago may have changed.
    @Test func checksAgainAtThePress() async throws {
        let checkout = try Checkout()
        let runs = Runs()
        let opener = runs.opener()
        let location = try checkout.location(checkout.file)
        #expect(opener.offers(location, scope: checkout.scope()))
        // The file became a link out of the checkout.
        try FileManager.default.removeItem(at: checkout.file)
        try FileManager.default.createSymbolicLink(at: checkout.file, withDestinationURL: checkout.outside)
        #expect(await opener.open(location, scope: checkout.scope()) == .outsideCheckout)
        try FileManager.default.removeItem(at: checkout.file)
        #expect(await opener.open(location, scope: checkout.scope()) == .missing)
        // The app moved to a host's service while the line was open.
        try Data("x".utf8).write(to: checkout.file)
        #expect(await opener.open(location, scope: checkout.scope(serviceIsLocal: false)) == .remoteService)
        #expect(runs.all.isEmpty)
    }

    /// The press reads the same call's summary again: only the location that was offered opens.
    @Test func opensOnlyTheLocationTheCallStillReports() async throws {
        let checkout = try Checkout()
        let runs = Runs()
        let opener = runs.opener()
        let offered = try checkout.location(checkout.file, line: 7)
        // Cleared, moved to another line, and moved to another file that would itself pass.
        let other = checkout.root.appending(path: "src/other.txt")
        try Data("x".utf8).write(to: other)
        for current in [nil, try checkout.location(checkout.file, line: 8), try checkout.location(other, line: 7)] {
            #expect(await opener.open(offered, current: current, scope: checkout.scope()) == .locationChanged)
        }
        #expect(runs.all.isEmpty)
        // Unchanged, it still passes every other check before anything runs.
        #expect(await opener.open(offered, current: offered, scope: checkout.scope(serviceIsLocal: false)) == .remoteService)
        #expect(runs.all.isEmpty)
        #expect(await opener.open(offered, current: offered, scope: checkout.scope()) == nil)
        #expect(runs.all == [["/usr/bin/xed", "--line", "7", try checkout.canonical(checkout.file)]])
    }

    /// What the press compares, read as the cockpit reads it: this worker's record under the
    /// call's own detail key, as the store holds it now.
    @MainActor @Test func thePressReadsTheSameWorkersSameCall() async throws {
        let checkout = try Checkout()
        let path = try checkout.canonical(checkout.file)
        let store = ToolDetailStore(source: ToolDetailSource(
            page: { _, after in
                let location = after == 0 ? #"{"path":"\#(path)","line":7}"# : #"{"path":"","line":0}"#
                let text = #"{"revision":\#(after + 1),"records":[{"key":"toolu_01","kind":"tool","location":\#(location)}]}"#
                return try JSONDecoder().decode(ToolDetailPage.self, from: Data(text.utf8))
            },
            record: { _, key in ToolDetailRecord(key: key, kind: "tool") },
            readSettings: { TranscriptSettings() },
            writeSettings: { $0 }))
        let runs = Runs()
        let opener = runs.opener()
        func press(_ offered: ToolLocation, worker: String, key: String) async -> ToolLocationError? {
            await opener.open(offered, current: store.summary(worker: worker, key: key)?.openableLocation, scope: checkout.scope())
        }
        await store.refresh(worker: "w-1")
        let offered = try #require(store.summary(worker: "w-1", key: "w-1:toolu_01")?.openableLocation)
        // Another call of the worker, and the same call ID under another worker, hold nothing.
        #expect(await press(offered, worker: "w-1", key: "w-1:toolu_02") == .locationChanged)
        #expect(await press(offered, worker: "w-2", key: "w-2:toolu_01") == .locationChanged)
        #expect(runs.all.isEmpty)
        #expect(await press(offered, worker: "w-1", key: "w-1:toolu_01") == nil)
        #expect(runs.all.count == 1)
        // The service clears the location while the line is open.
        await store.refresh(worker: "w-1")
        #expect(await press(offered, worker: "w-1", key: "w-1:toolu_01") == .locationChanged)
        #expect(runs.all.count == 1)
    }

    @Test func saysWhyTheCommandDidNotOpenTheFile() async throws {
        let checkout = try Checkout()
        let location = try checkout.location(checkout.file, line: 7)
        let failed = Runs()
        #expect(await failed.opener(result: .exited(1)).open(location, scope: checkout.scope()) == .runnerFailed(status: 1))
        // One attempt: a failure is never followed by an open without the line.
        #expect(failed.all.count == 1)
        #expect(await Runs().opener(result: .notStarted).open(location, scope: checkout.scope()) == .runnerNotStarted)
        let absent = Runs()
        #expect(!absent.opener(installed: false).offers(location, scope: checkout.scope()))
        #expect(await absent.opener(installed: false).open(location, scope: checkout.scope()) == .runnerMissing)
        #expect(absent.all.isEmpty)
    }

    @Test func wordsOfTheActionAndItsFailure() throws {
        let location = try #require(ToolLocation(path: "/repo/src/a.txt", line: 7))
        #expect(ToolLocationAction.title(location) == "Open at line 7")
        #expect(ToolLocationAction.statement(.missing, location: location)
                == "Couldn't open the file at line 7. The file is no longer there.")
        #expect(ToolLocationAction.statement(.runnerFailed(status: 1), location: location)
                == "Couldn't open the file at line 7. Xcode's xed tool ended with status 1. Check that Xcode is installed and selected.")
        // No sentence repeats the provider's path.
        #expect(ToolLocationAction.statement(.locationChanged, location: location)
                == "Couldn't open the file at line 7. This call no longer reports that file and line.")
        let errors: [ToolLocationError] = [.remoteService, .remoteWorker, .workerGone, .locationChanged, .noCheckout, .missing, .outsideCheckout,
                                           .notAFile, .runnerMissing, .runnerNotStarted, .runnerFailed(status: 2)]
        for error in errors {
            #expect(!ToolLocationAction.statement(error, location: location).contains("/repo"))
        }
    }
}
