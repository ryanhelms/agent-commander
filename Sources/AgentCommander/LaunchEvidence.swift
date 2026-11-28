import Darwin
import Foundation
import OSLog

// Startup evidence for the production app, written once to this process's held lease
// (`<pid>.lease`, see SingleInstanceStore.swift). The local Go service reads it while the kernel
// lock is held, then checks the executable, process start, code signature and address scope
// itself. Nothing here is proof by itself, and none of it enters a remote-facing model.
//
// The JSON object has exactly these keys:
//   schema 1, pid, startedSeconds, startedMicros, launchId, version, revision (optional), tree,
//   executable, commanderSocket

struct LaunchEvidence: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let productionBundleIdentifier = "local.agentcommander.cockpit"
    static let versionLimit = 128

    /// Minted once per process. A restart gets a new one.
    static let launchID = UUID().uuidString.lowercased()

    let schema: Int
    let pid: Int32
    let startedSeconds: Int64
    let startedMicros: Int32
    let launchId: String
    let version: String
    /// Omitted unless the build stamped an exact 40-digit lower-case revision.
    let revision: String?
    let tree: String
    let executable: String
    let commanderSocket: String

    /// When the kernel started a process.
    struct ProcessStart: Equatable, Sendable {
        let seconds: Int64
        let micros: Int32
    }

    /// The record for this bundle and process. Nil for anything but the production bundle, and
    /// when any required value is missing or malformed.
    static func make(bundleIdentifier: String?, info: [String: Any]?, executable: URL?, socket: String,
                     pid: Int32, started: ProcessStart?, launchID: String = LaunchEvidence.launchID) -> LaunchEvidence? {
        guard bundleIdentifier == productionBundleIdentifier, pid > 0, let started,
              started.seconds > 0, (0..<1_000_000).contains(started.micros),
              let version = boundedVersion(AppVersionFooter.version(in: info)),
              let executable = canonicalPath(executable),
              socket.hasPrefix("/"), isPlain(socket),
              UUID(uuidString: launchID) != nil, launchID == launchID.lowercased() else { return nil }
        let exact = revision(info?["AgentCommanderGitRevision"] as? String)
        return LaunchEvidence(schema: currentSchema, pid: pid, startedSeconds: started.seconds,
                              startedMicros: started.micros, launchId: launchID, version: version,
                              revision: exact,
                              tree: tree(info?["AgentCommanderGitTree"] as? String, revision: exact),
                              executable: executable, commanderSocket: socket)
    }

    /// This process's record. The socket is this Mac's own, never a selected remote host's.
    static func current(bundle: Bundle = .main, endpoint: ServiceEndpoint = .live,
                        pid: Int32 = getpid()) -> LaunchEvidence? {
        make(bundleIdentifier: bundle.bundleIdentifier, info: bundle.infoDictionary,
             executable: bundle.executableURL, socket: endpoint.localSocket, pid: pid,
             started: processStart(of: pid))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Best effort: a launch with no evidence behaves exactly as before.
    static func record(on membership: SingleInstanceMembership, bundle: Bundle = .main,
                       endpoint: ServiceEndpoint = .live) {
        let log = Logger(subsystem: bundle.bundleIdentifier ?? "AgentCommander", category: "launch-evidence")
        guard let evidence = current(bundle: bundle, endpoint: endpoint, pid: membership.pid) else { return }
        do {
            try membership.recordEvidence(try evidence.encoded())
        } catch {
            log.error("Launch evidence unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Values

    /// The start time the kernel holds for `pid` (`kern.proc.pid`, `p_starttime`).
    static func processStart(of pid: Int32) -> ProcessStart? {
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessStart(seconds: Int64(start.tv_sec), micros: Int32(start.tv_usec))
    }

    /// The footer label, trimmed and cut to the limit in UTF-8 bytes. Nil when blank.
    static func boundedVersion(_ label: String) -> String? {
        var version = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, isPlain(version) else { return nil }
        while version.utf8.count > versionLimit { version.removeLast() }
        return version
    }

    static func revision(_ stamped: String?) -> String? {
        guard let stamped, stamped.utf8.count == 40,
              stamped.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return stamped
    }

    /// "clean" or "dirty" only beside a well-formed revision. Anything else is "unknown".
    static func tree(_ stamped: String?, revision: String?) -> String {
        guard revision != nil, let stamped, stamped == "clean" || stamped == "dirty" else { return "unknown" }
        return stamped
    }

    /// The real absolute path, with every symbolic link resolved.
    static func canonicalPath(_ url: URL?) -> String? {
        guard let url, url.isFileURL, let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return path.hasPrefix("/") && isPlain(path) ? path : nil
    }

    private static func isPlain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
