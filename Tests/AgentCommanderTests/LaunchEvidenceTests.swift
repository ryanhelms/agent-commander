import Darwin
import Foundation
import Testing
@testable import AgentCommander

// Evidence is written to a lease in a private temp folder. Nothing reads or changes the real
// Application Support folder.

private let production = LaunchEvidence.productionBundleIdentifier
private let stampedRevision = "0123456789abcdef0123456789abcdef01234567"
private let launch = "3f2b8c1e-6d4a-4b7f-9a55-0c1d2e3f4a5b"
private let started = LaunchEvidence.ProcessStart(seconds: 1_795_000_000, micros: 123_456)

private func stamp(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var info: [String: Any] = ["AgentCommanderGitVersion": "v0.1.0-pilot.3-236-g441beb9",
                               "AgentCommanderGitRevision": stampedRevision, "AgentCommanderGitTree": "clean"]
    info.merge(overrides) { $1 }
    return info
}

private func evidence(bundle: String? = production, info: [String: Any]? = stamp(),
                      executable: URL? = URL(filePath: "/bin/ls"), socket: String = "/tmp/commander/service.sock",
                      pid: Int32 = 4242, start: LaunchEvidence.ProcessStart? = started,
                      launchID: String = launch) -> LaunchEvidence? {
    LaunchEvidence.make(bundleIdentifier: bundle, info: info, executable: executable, socket: socket,
                        pid: pid, started: start, launchID: launchID)
}

private func lease(_ pid: Int32) throws -> (SingleInstanceMembership, String, URL) {
    let support = FileManager.default.temporaryDirectory
        .appending(path: "LaunchEvidenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let store = try SingleInstanceStore(identifier: "test.agentcommander.evidence", applicationSupport: support)
    guard case .registered(let membership) = try store.admit(onlyOneInstance: true, pid: pid) else {
        throw SingleInstanceError.system("register \(pid)", EEXIST)
    }
    return (membership, store.directory.path(percentEncoded: false) + "/\(pid).lease", support)
}

@Suite("Launch evidence")
struct LaunchEvidenceTests {
    @Test func theRecordHasExactlyTheContractKeys() throws {
        let record = try #require(evidence())
        let object = try #require(try JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "pid", "startedSeconds", "startedMicros", "launchId", "version",
                                     "revision", "tree", "executable", "commanderSocket"])
        #expect(object["schema"] as? Int == 1 && object["pid"] as? Int == 4242)
        #expect(object["startedSeconds"] as? Int == 1_795_000_000 && object["startedMicros"] as? Int == 123_456)
        #expect(object["launchId"] as? String == launch)
        #expect(object["version"] as? String == "v0.1.0-pilot.3-236-g441beb9")
        #expect(object["revision"] as? String == stampedRevision && object["tree"] as? String == "clean")
        #expect(object["executable"] as? String == "/bin/ls")
        #expect(object["commanderSocket"] as? String == "/tmp/commander/service.sock")
        #expect(try JSONDecoder().decode(LaunchEvidence.self, from: record.encoded()) == record)
        // Paths are written as they are, with no escaped slashes.
        #expect(String(decoding: try record.encoded(), as: UTF8.self).contains(#""executable":"/bin/ls""#))
    }

    @Test func aMissingOrMalformedRevisionIsLeftOutAndTheTreeIsUnknown() throws {
        for revision in ["", "0123456789ABCDEF0123456789abcdef01234567", String(stampedRevision.dropLast()),
                         stampedRevision + "0", "g" + String(stampedRevision.dropFirst())] {
            // The stamped tree is well formed, but it says nothing without a revision.
            for tree in ["clean", "dirty"] {
                let record = try #require(evidence(info: stamp(["AgentCommanderGitRevision": revision,
                                                                "AgentCommanderGitTree": tree])))
                #expect(record.revision == nil && record.tree == "unknown")
                let object = try #require(try JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
                #expect(object["revision"] == nil && object["tree"] as? String == "unknown" && object.count == 9)
            }
        }
        let unstamped = try #require(evidence(info: ["AgentCommanderGitVersion": "v0.1.0",
                                                     "AgentCommanderGitTree": "clean"]))
        #expect(unstamped.revision == nil && unstamped.tree == "unknown")
        #expect(evidence(info: stamp(["AgentCommanderGitTree": "dirty"]))?.tree == "dirty")
        for tree in ["Clean", "", "modified"] {
            let record = try #require(evidence(info: stamp(["AgentCommanderGitTree": tree])))
            #expect(record.revision == stampedRevision && record.tree == "unknown")
        }
        #expect(evidence(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"])?.version == "0.1.0 (7)")
    }

    @Test func onlyTheProductionBundleWithCompleteValuesGetsARecord() {
        #expect(evidence() != nil)
        #expect(evidence(bundle: nil) == nil)
        #expect(evidence(bundle: "local.agentcommander.cockpit.fixture") == nil)
        #expect(evidence(bundle: "unbundled.AgentCommander") == nil)
        #expect(evidence(info: stamp(["AgentCommanderGitVersion": " \n"]), executable: nil) == nil)
        #expect(evidence(info: ["CFBundleShortVersionString": "  "]) == nil)
        #expect(evidence(executable: nil) == nil)
        #expect(evidence(executable: URL(filePath: "/nonexistent/AgentCommander")) == nil)
        #expect(evidence(socket: "service.sock") == nil)
        #expect(evidence(socket: "") == nil)
        #expect(evidence(pid: 0) == nil)
        #expect(evidence(start: nil) == nil)
        #expect(evidence(start: .init(seconds: 1_795_000_000, micros: 1_000_000)) == nil)
        #expect(evidence(launchID: launch.uppercased()) == nil)
        #expect(evidence(launchID: "not-a-uuid") == nil)
    }

    @Test func theVersionIsBoundedAndTheExecutableIsTheRealPath() throws {
        let long = String(repeating: "é", count: 200)
        let bounded = try #require(LaunchEvidence.boundedVersion("  " + long + " "))
        #expect(bounded.utf8.count == 128 && long.hasPrefix(bounded))
        #expect(LaunchEvidence.boundedVersion("") == nil)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "LaunchEvidenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "AgentCommander")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/bin/ls"))
        #expect(evidence(executable: link)?.executable == "/bin/ls")
    }

    @Test func theLaunchIDIsMintedOnceAndTheStartComesFromTheKernel() throws {
        let id = LaunchEvidence.launchID
        #expect(id == LaunchEvidence.launchID && id == id.lowercased() && UUID(uuidString: id) != nil)
        #expect(id.count == 36 && id.filter { $0 == "-" }.count == 4)

        let start = try #require(LaunchEvidence.processStart(of: getpid()))
        #expect(start == LaunchEvidence.processStart(of: getpid()))
        #expect(start.seconds > 1_600_000_000 && start.seconds <= Int64(time(nil)))
        #expect((0..<1_000_000).contains(start.micros))
        // The test runner is not the production bundle, so it claims nothing.
        #expect(LaunchEvidence.current() == nil)
    }

    @Test func theRecordIsWrittenOnceToTheHeldLease() throws {
        let (membership, path, support) = try lease(301)
        defer { try? FileManager.default.removeItem(at: support) }
        defer { membership.relinquish() }
        let record = try #require(evidence(pid: 301)).encoded()
        try membership.recordEvidence(record)
        #expect(try Data(contentsOf: URL(filePath: path)) == record)

        // Still the same locked lease: a reader sees the record and can't take the lock.
        let probe = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        try #require(probe >= 0)
        defer { close(probe) }
        #expect(flock(probe, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK)
        var info = stat()
        try #require(fstat(probe, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let again = #expect(throws: SingleInstanceError.self) { try membership.recordEvidence(Data("{}".utf8)) }
        #expect(again == .system("record launch evidence", EEXIST))
        #expect(try Data(contentsOf: URL(filePath: path)) == record)
    }

    @Test func aRefusedRecordLeavesTheLeaseEmptyAndHeld() throws {
        let (membership, path, support) = try lease(302)
        defer { try? FileManager.default.removeItem(at: support) }
        for record in [Data(), Data(count: SingleInstanceMembership.evidenceLimit + 1)] {
            let refused = #expect(throws: SingleInstanceError.self) { try membership.recordEvidence(record) }
            #expect(refused == .system("record launch evidence", EINVAL))
        }
        #expect(try Data(contentsOf: URL(filePath: path)).isEmpty)

        // A bundle that isn't production writes nothing and throws nothing.
        LaunchEvidence.record(on: membership)
        #expect(try Data(contentsOf: URL(filePath: path)).isEmpty)

        membership.relinquish()
        let released = #expect(throws: SingleInstanceError.self) { try membership.recordEvidence(Data("{}".utf8)) }
        #expect(released == .system("record launch evidence", EBADF))
    }
}
