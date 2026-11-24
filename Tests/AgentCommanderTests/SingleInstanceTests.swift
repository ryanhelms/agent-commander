import Darwin
import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Each actor stands for a separate Commander process: it builds its own store, as a cold launch
// does. flock locks belong to open file descriptions, so actors in one test process contend
// exactly as separate processes do, and `relinquish()` drops a lease the way exit or a crash
// does. Pids are labels. Folders live under a private temp root and preferences in a throwaway
// suite; nothing reads or changes the real Application Support folder or UserDefaults.standard.

private struct LaunchSandbox: Sendable {
    static let identifier = "test.agentcommander.single-instance"
    let support: URL

    init() throws {
        support = FileManager.default.temporaryDirectory
            .appending(path: "SingleInstanceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func launch(_ identifier: String = Self.identifier,
                lockTimeout: Duration = .seconds(2)) throws -> SingleInstanceStore {
        try SingleInstanceStore(identifier: identifier, applicationSupport: support, lockTimeout: lockTimeout)
    }

    func remove() { try? FileManager.default.removeItem(at: support) }
}

private extension SingleInstanceAdmission {
    var membership: SingleInstanceMembership? {
        if case .registered(let membership) = self { return membership }
        return nil
    }

    var target: Int32? {
        if case .handedOff(let pid) = self { return pid }
        return nil
    }
}

private final class Collected: Sendable {
    let admissions = Mutex<[SingleInstanceAdmission]>([])
    let failures = Mutex<[String]>([])
}

private extension SingleInstanceError {
    var isBusy: Bool { if case .busy = self { true } else { false } }
    var isUnsafeFolder: Bool { if case .unsafeFolder = self { true } else { false } }
}

private func entries(_ store: SingleInstanceStore) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false)))
}

private func permissions(_ path: String) -> mode_t {
    var info = stat()
    guard lstat(path, &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

@Suite("Single instance launch admission")
struct SingleInstanceTests {
    @Test func preferenceDefaultsOnAndBelongsToItsDomain() throws {
        let suite = "SingleInstanceTests.\(UUID().uuidString)"
        let copySuite = suite + ".copy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let copyDefaults = try #require(UserDefaults(suiteName: copySuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            copyDefaults.removePersistentDomain(forName: copySuite)
        }

        #expect(SingleInstancePreference.key == "AllowOnlyOneInstance")
        #expect(SingleInstancePreference.isEnabled(in: defaults))
        defaults.set(false, forKey: SingleInstancePreference.key)
        #expect(!SingleInstancePreference.isEnabled(in: defaults))
        #expect(SingleInstancePreference.isEnabled(in: copyDefaults))
    }

    @Test func firstLaunchRegistersWithOwnerOnlyRecords() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let first = try #require(try store.admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }
        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 102).target == 101)

        let folder = store.directory.path(percentEncoded: false)
        #expect(permissions(folder) == 0o700)
        #expect(permissions(folder + "/101.lease") == 0o600)
        #expect(permissions(folder + "/101.focus") == 0o600)
        #expect(permissions(folder + "/admission.lock") == 0o600)
        #expect(try store.members() == [101])
    }

    @Test func duplicateLaunchesCoalesceIntoOneFocusRequest() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let first = try #require(try store.admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }

        for pid: Int32 in 102...104 {
            #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: pid).target == 101)
        }
        #expect(try entries(store) == ["admission.lock", "101.lease", "101.focus"])
        #expect(first.takeFocusRequest())
        #expect(!first.takeFocusRequest())
        #expect(try entries(store) == ["admission.lock", "101.lease"])
    }

    @Test func requestPostedBeforeWatcherIsReplayed() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let first = try #require(try sandbox.launch().admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }
        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 102).target == 101)

        // Install, then consume: the order the coordinator uses when the GUI is ready.
        let watcher = try first.watch(queue: DispatchQueue(label: "SingleInstanceTests.replay")) {}
        defer { watcher.cancel() }
        #expect(first.takeFocusRequest())
    }

    @Test func watcherFiresWhenRequestArrives() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let first = try #require(try sandbox.launch().admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }
        let changed = DispatchSemaphore(value: 0)
        let watcher = try first.watch(queue: DispatchQueue(label: "SingleInstanceTests.watch")) {
            changed.signal()
        }
        defer { watcher.cancel() }

        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 102).target == 101)
        #expect(changed.wait(timeout: .now() + 2) == .success)
        #expect(first.takeFocusRequest())
    }

    @Test func disabledLaunchesRegisterAndReenablingPicksLowestLivePid() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let higher = try #require(try sandbox.launch().admit(onlyOneInstance: false, pid: 205).membership)
        let lower = try #require(try sandbox.launch().admit(onlyOneInstance: false, pid: 103).membership)
        defer { higher.relinquish(); lower.relinquish() }
        #expect(try sandbox.launch().members() == [103, 205])

        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 300).target == 103)
        #expect(try sandbox.launch().members() == [103, 205])
        #expect(lower.takeFocusRequest())
        #expect(!higher.takeFocusRequest())
    }

    @Test func survivorReceivesLaunchesAfterLowestExits() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let lower = try #require(try sandbox.launch().admit(onlyOneInstance: false, pid: 101).membership)
        let survivor = try #require(try sandbox.launch().admit(onlyOneInstance: false, pid: 102).membership)
        defer { survivor.relinquish() }
        lower.relinquish()

        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 103).target == 102)
        #expect(survivor.takeFocusRequest())
        #expect(try sandbox.launch().members() == [102])
    }

    @Test func targetExitingDuringHandoffFallsThroughToNextLivePid() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let lower = try #require(try store.admit(onlyOneInstance: false, pid: 101).membership)
        let survivor = try #require(try store.admit(onlyOneInstance: false, pid: 102).membership)
        defer { survivor.relinquish() }

        let admission = try sandbox.launch().admit(onlyOneInstance: true, pid: 103) { target in
            if target == 101 { lower.relinquish() }
        }
        #expect(admission.target == 102)
        #expect(survivor.takeFocusRequest())
        #expect(try entries(store) == ["admission.lock", "102.lease"])
    }

    @Test func crashedInstanceLeavesNoLockoutOrPhantomRequest() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let crashed = try #require(try store.admit(onlyOneInstance: true, pid: 101).membership)
        #expect(try sandbox.launch().admit(onlyOneInstance: true, pid: 102).target == 101)
        crashed.relinquish()

        let next = try #require(try sandbox.launch().admit(onlyOneInstance: true, pid: 103).membership)
        defer { next.relinquish() }
        #expect(try entries(store) == ["admission.lock", "103.lease"])

        // A later Commander that reuses the crashed pid starts with no pending request.
        next.relinquish()
        let reused = try #require(try sandbox.launch().admit(onlyOneInstance: true, pid: 101).membership)
        defer { reused.relinquish() }
        #expect(!reused.takeFocusRequest())
        #expect(try store.members() == [101])
    }

    @Test func concurrentColdLaunchesAdmitExactlyOne() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let collected = Collected()

        DispatchQueue.concurrentPerform(iterations: 4) { index in
            do {
                let admission = try sandbox.launch().admit(onlyOneInstance: true, pid: Int32(201 + index))
                collected.admissions.withLock { $0.append(admission) }
            } catch {
                collected.failures.withLock { $0.append(String(describing: error)) }
            }
        }

        let results = collected.admissions.withLock { $0 }
        let registered = results.compactMap(\.membership)
        defer { registered.forEach { $0.relinquish() } }
        #expect(collected.failures.withLock { $0 }.isEmpty)
        #expect(registered.count == 1)
        let winner = try #require(registered.first)
        #expect(results.compactMap(\.target) == [winner.pid, winner.pid, winner.pid])
        #expect(winner.takeFocusRequest())
        #expect(!winner.takeFocusRequest())
    }

    @Test func copiedAppWithDistinctIdentifierIsIsolated() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let production = try sandbox.launch()
        let copy = try sandbox.launch(LaunchSandbox.identifier + "-copy")
        let first = try #require(try production.admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }

        let copied = try #require(try copy.admit(onlyOneInstance: true, pid: 102).membership)
        defer { copied.relinquish() }
        #expect(production.directory != copy.directory)
        #expect(try production.members() == [101])
        #expect(try copy.members() == [102])
        #expect(!first.takeFocusRequest())
    }

    @Test func heldAdmissionLockFailsInsteadOfAdmitting() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch(lockTimeout: .milliseconds(50))
        let holder = open(store.directory.path(percentEncoded: false) + "/admission.lock",
                          O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX) == 0)

        let error = #expect(throws: SingleInstanceError.self) {
            try store.admit(onlyOneInstance: true, pid: 101)
        }
        #expect(error?.isBusy == true)
        #expect(try entries(store) == ["admission.lock"])
    }

    @Test func unsafeFoldersAreRefusedAndLooseLaunchFolderIsMadePrivate() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let elsewhere = sandbox.support.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try #require(symlink(elsewhere.path(percentEncoded: false),
                             sandbox.support.appending(path: "test.linked").path(percentEncoded: false)) == 0)
        let linked = #expect(throws: SingleInstanceError.self) { try sandbox.launch("test.linked") }
        #expect(linked?.isUnsafeFolder == true)

        let shared = sandbox.support.appending(path: "test.shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try #require(chmod(shared.path(percentEncoded: false), 0o777) == 0)
        let writable = #expect(throws: SingleInstanceError.self) { try sandbox.launch("test.shared") }
        #expect(writable?.isUnsafeFolder == true)

        let loose = sandbox.support.appending(path: "test.loose/Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try #require(chmod(loose.path(percentEncoded: false), 0o755) == 0)
        let store = try sandbox.launch("test.loose")
        #expect(permissions(store.directory.path(percentEncoded: false)) == 0o700)
    }

    @Test func foreignNamesInLaunchFolderAreIgnored() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let folder = store.directory.path(percentEncoded: false)
        for name in ["0101.lease", "-5.lease", "abc.lease", "notes.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data())
        }
        #expect(try store.members().isEmpty)
        let first = try #require(try store.admit(onlyOneInstance: true, pid: 101).membership)
        defer { first.relinquish() }
        #expect(try store.members() == [101])
    }

    @Test func unprobeableRecordsFailAdmissionAndArePreserved() throws {
        let sandbox = try LaunchSandbox()
        defer { sandbox.remove() }
        let store = try sandbox.launch()
        let folder = store.directory.path(percentEncoded: false)

        // A numeric lease that can't be opened (ELOOP) isn't proven stale: no removal, no new lease.
        try #require(symlink(sandbox.support.path(percentEncoded: false) + "/missing", folder + "/101.lease") == 0)
        let unprobeable = #expect(throws: SingleInstanceError.self) {
            try store.admit(onlyOneInstance: true, pid: 102)
        }
        #expect(unprobeable == .system("open \(folder)/101.lease", ELOOP))
        #expect(try entries(store) == ["admission.lock", "101.lease"])
        try #require(unlink(folder + "/101.lease") == 0)

        // A directory in place of a live peer's marker can't carry a request, so there is no handoff.
        let live = try #require(try store.admit(onlyOneInstance: true, pid: 201).membership)
        defer { live.relinquish() }
        try #require(mkdir(folder + "/201.focus", 0o700) == 0)
        let unusable = #expect(throws: SingleInstanceError.self) {
            try store.admit(onlyOneInstance: true, pid: 202)
        }
        #expect(unusable == .system("use \(folder)/201.focus", EFTYPE))
        #expect(try entries(store) == ["admission.lock", "201.lease", "201.focus"])
    }

    @Test func namespaceIdentifierIsOneSafeComponent() {
        #expect(SingleInstanceStore.identifier(bundleIdentifier: "local.agentcommander.cockpit",
                                               executable: "AgentCommander") == "local.agentcommander.cockpit")
        #expect(SingleInstanceStore.identifier(bundleIdentifier: nil, executable: "AgentCommander")
                == "unbundled.AgentCommander")
        let hostile = SingleInstanceStore.identifier(bundleIdentifier: "../../etc", executable: "x")
        #expect(!hostile.contains("/"))
        #expect(!hostile.hasPrefix("."))
    }
}
