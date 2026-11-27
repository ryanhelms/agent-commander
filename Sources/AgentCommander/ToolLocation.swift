import Darwin
import Foundation
import SwiftUI

// TOOL LOCATION (DESIGN.md, "Pretty transcript", "Open at line"; spec section H, ACP tool `locations`)
// The one file and line an ACP tool reported for its call, and the "Open at line N" action of that
// call's opened Pretty line. The service keeps the location on the call's stored details and
// serves it only on the owner socket (internal/service/tool_details.go):
//
//   "location": { "path": "/absolute/file/path", "line": 7 }
//
//   Values         ToolLocation           the path and line, read only in that exact shape
//                  ToolLocationField      the wire member: anything else reads as no location
//                  ToolLocationScope      whose file it is: the service in use, the worker's host and checkout
//                  ToolLocationTarget     the canonical file and line, once every check has passed
//                  ToolLocationError      why the file is not opened, in words
//                  ToolLocationCommand    the fixed executable and its arguments
//   Feature layer  ToolLocationPaths      canonical paths and containment by path component
//                  ToolLocationResolver   every check, from the scope and the disk
//                  ToolLocationOpener     checks again, then runs the command without a shell
//   Boundary       ToolLocationIntents    how a console asks: offered, and open
//   Molecule       ToolLocationAction     the quiet inline link, and the reason a press failed
//
// The path is provider data. It is opened only when the app talks to this Mac's own service, the
// service marks the worker as its own local worker, and the file is a regular file inside that
// worker's checkout after symbolic links are resolved. It is never translated for another host,
// and it only ever reaches the command as one argument.

// MARK: - Values

/// The single file and line a tool call reported. Valid by construction.
struct ToolLocation: Equatable, Hashable, Sendable {
    /// The service accepts no longer path (`ToolLocation.Valid` in the service).
    static let pathLimit = 4096
    /// ACP sends a 1-based line as an unsigned 32-bit number, and the service enforces it.
    static let lineRange = 1...Int(UInt32.max)

    let path: String
    let line: Int

    /// Nil unless the path is absolute, free of control characters and within the service's
    /// bound, and the line is a positive line number.
    init?(path: String, line: Int) {
        guard Self.lineRange.contains(line), ToolLocationPaths.isPlainAbsolute(path) else { return nil }
        self.path = path
        self.line = line
    }
}

/// The `location` member of a stored tool detail. It never fails the record it sits in: a value
/// that is not exactly one object with a string `path` and an integer `line`, or whose values
/// `ToolLocation` refuses, reads as no location. That covers the service's explicit clearing
/// (`{"path":"","line":0}`), a list of locations and a null.
struct ToolLocationField: Decodable, Equatable, Sendable {
    let value: ToolLocation?

    init(_ value: ToolLocation?) { self.value = value }

    private struct Wire: Decodable {
        let path: String
        let line: Int
    }

    init(from decoder: Decoder) throws {
        value = (try? Wire(from: decoder)).flatMap { ToolLocation(path: $0.path, line: $0.line) }
    }
}

/// Whose file a location names. Built from the cockpit's own state for one worker, never from
/// the tool call.
struct ToolLocationScope: Equatable, Sendable {
    /// The app talks to this Mac's own service. False while a headless host's forwarded service
    /// is in use: its `localhost` workers run on that host.
    let serviceIsLocal: Bool
    /// The worker's execution host, as the service reports it.
    let host: String
    /// The worker's checkout, as the service reports it.
    let checkout: String

    /// The worker runs on this Mac: the service in use is this Mac's, and it marks the worker
    /// with its exact local marker. No name is matched or looked up.
    var workerIsLocal: Bool { serviceIsLocal && HostPlatform(serviceHost: host) == .localMac }
}

/// A file that passed every check, as it is handed to the command.
struct ToolLocationTarget: Equatable, Sendable {
    /// Canonical: absolute, symbolic links resolved.
    let path: String
    let line: Int
}

enum ToolLocationError: LocalizedError, Equatable {
    case remoteService
    case remoteWorker
    case workerGone
    /// The call's stored summary no longer holds the location that was offered.
    case locationChanged
    case noCheckout
    case missing
    case outsideCheckout
    case notAFile
    case runnerMissing
    case runnerNotStarted
    case runnerFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .remoteService: "Agent Commander is using another host's service, so the file is not on this Mac."
        case .remoteWorker: "This worker does not run on this Mac."
        case .workerGone: "This worker is no longer in a run."
        case .locationChanged: "This call no longer reports that file and line."
        case .noCheckout: "This worker has no checkout folder on this Mac."
        case .missing: "The file is no longer there."
        case .outsideCheckout: "The file is outside this worker's checkout."
        case .notAFile: "It is not a regular file."
        case .runnerMissing: "Xcode's xed tool is not at \(ToolLocationCommand.executable)."
        case .runnerNotStarted: "Xcode's xed tool could not be started."
        case .runnerFailed(let status): "Xcode's xed tool ended with status \(status). Check that Xcode is installed and selected."
        }
    }
}

/// The one command that opens a file at a line: Xcode's `xed --line NUMBER FILE`. The executable
/// is fixed. Nothing is read from the provider, the environment or a setting to choose it.
struct ToolLocationCommand: Equatable, Sendable {
    static let executable = "/usr/bin/xed"

    let arguments: [String]

    /// The path is one whole argument, last. It is canonical, so it starts with a slash and is
    /// never read as an option whatever the file is called.
    init(_ target: ToolLocationTarget) {
        arguments = ["--line", String(target.line), target.path]
    }
}

// MARK: - Feature layer

enum ToolLocationPaths {
    /// An absolute path with no control character, within the service's bound. Says nothing
    /// about the disk.
    static func isPlainAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= ToolLocation.pathLimit
            && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The path as the file system resolves it: every symbolic link followed, `.` and `..`
    /// removed. Nil when nothing is there.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `file` is beneath `root`, compared one whole path component at a time, so
    /// `/repo-other/a` is not inside `/repo`. Both are canonical. The root directory holds
    /// nothing here: it is never a checkout.
    static func contains(root: String, file: String) -> Bool {
        let rootParts = root.split(separator: "/"), fileParts = file.split(separator: "/")
        return !rootParts.isEmpty && fileParts.count > rootParts.count && fileParts.starts(with: rootParts)
    }

    enum Kind: Equatable { case regular, directory, other }

    /// What is at a canonical path, without following a link placed there since.
    static func kind(_ path: String) -> Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        default: return .other
        }
    }
}

enum ToolLocationResolver {
    /// Every check between a reported location and a file to open, in order: the service, the
    /// worker's host, the checkout, then the file on disk.
    static func resolve(_ location: ToolLocation, scope: ToolLocationScope) -> Result<ToolLocationTarget, ToolLocationError> {
        guard scope.serviceIsLocal else { return .failure(.remoteService) }
        guard scope.workerIsLocal else { return .failure(.remoteWorker) }
        guard ToolLocationPaths.isPlainAbsolute(scope.checkout),
              let root = ToolLocationPaths.canonical(scope.checkout), root != "/",
              ToolLocationPaths.kind(root) == .directory else { return .failure(.noCheckout) }
        guard let file = ToolLocationPaths.canonical(location.path) else { return .failure(.missing) }
        // A link inside the checkout may lead anywhere: the resolved path is the one compared.
        guard ToolLocationPaths.isPlainAbsolute(file), ToolLocationPaths.contains(root: root, file: file) else {
            return .failure(.outsideCheckout)
        }
        guard let kind = ToolLocationPaths.kind(file) else { return .failure(.missing) }
        guard kind == .regular else { return .failure(.notAFile) }
        return .success(ToolLocationTarget(path: file, line: location.line))
    }
}

/// Opens a location. The checks are made again at the press, on the scope the caller reads then;
/// only a target that passes reaches the command.
struct ToolLocationOpener: Sendable {
    enum Run: Equatable, Sendable {
        case exited(Int32)
        case notStarted
    }

    /// The command's executable is installed and may be run.
    var isInstalled: @Sendable () -> Bool = { FileManager.default.isExecutableFile(atPath: ToolLocationCommand.executable) }
    /// Runs the executable with exactly these arguments and waits for it to end.
    var run: @Sendable (_ executable: String, _ arguments: [String]) async -> Run = ToolLocationOpener.process

    /// Whether the action is offered: the same checks as a press, without running anything.
    func offers(_ location: ToolLocation, scope: ToolLocationScope) -> Bool {
        guard isInstalled(), case .success = ToolLocationResolver.resolve(location, scope: scope) else { return false }
        return true
    }

    /// Nil once the command has ended well. There is no fallback: a file that cannot be opened
    /// at its line is not opened.
    func open(_ location: ToolLocation, scope: ToolLocationScope) async -> ToolLocationError? {
        let target: ToolLocationTarget
        switch ToolLocationResolver.resolve(location, scope: scope) {
        case .success(let resolved): target = resolved
        case .failure(let error): return error
        }
        guard isInstalled() else { return .runnerMissing }
        switch await run(ToolLocationCommand.executable, ToolLocationCommand(target).arguments) {
        case .exited(0): return nil
        case .exited(let status): return .runnerFailed(status: status)
        case .notStarted: return .runnerNotStarted
        }
    }

    /// A press on an offered location. `current` is what the same worker's same call holds in
    /// its stored summary now; unless it is still the location that was offered, nothing is
    /// checked on disk and nothing runs.
    func open(_ offered: ToolLocation, current: ToolLocation?, scope: ToolLocationScope) async -> ToolLocationError? {
        guard current == offered else { return .locationChanged }
        return await open(offered, scope: scope)
    }

    /// One child process, started directly: no shell, no input, and its output is dropped.
    static let process: @Sendable (String, [String]) async -> Run = { executable, arguments in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: .exited($0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .notStarted)
            }
        }
    }
}

// MARK: - Boundary

/// How a console asks about one of its own worker's locations. The cockpit supplies it; a
/// surface without one offers no action.
struct ToolLocationIntents {
    /// Whether the location can be opened now, for the worker with this exact ID.
    var offers: @MainActor (_ workerID: String, _ location: ToolLocation) -> Bool
    /// Opens the location offered for one call, named by the worker's exact ID and the call's
    /// exact transcript detail key. Nil on success, else why not.
    var open: @MainActor (_ workerID: String, _ detailKey: String, _ location: ToolLocation) async -> ToolLocationError?
}

extension ToolLocationScope {
    /// The scope of one worker as the service sent it.
    init(worker: Worker, serviceIsLocal: Bool) {
        self.init(serviceIsLocal: serviceIsLocal, host: worker.host, checkout: worker.worktree)
    }
}

extension CockpitModel {
    /// The scope of the worker with this exact ID, read now: the service in use, and that
    /// worker's own host and checkout. Nil when no run holds the worker.
    func toolLocationScope(workerID: String) -> ToolLocationScope? {
        for run in runs {
            if let worker = run.workers?.first(where: { $0.id == workerID }) {
                return ToolLocationScope(worker: worker, serviceIsLocal: hosts.inUse == nil)
            }
        }
        return nil
    }

    var toolLocationIntents: ToolLocationIntents {
        let opener = ToolLocationOpener()
        return ToolLocationIntents(
            offers: { [weak self] workerID, location in
                guard let scope = self?.toolLocationScope(workerID: workerID) else { return false }
                return opener.offers(location, scope: scope)
            },
            open: { [weak self] workerID, detailKey, location in
                guard let self, let scope = self.toolLocationScope(workerID: workerID) else { return .workerGone }
                // The same worker's same call, as its stored summary reads at the press.
                let current = self.toolDetails.summary(worker: workerID, key: detailKey)?.openableLocation
                return await opener.open(location, current: current, scope: scope)
            })
    }
}

extension ToolDetailSummary {
    /// The location an "Open at line" action may use: this record is a tool call's, and it holds
    /// one valid location now. Read from the summary on every draw, so a location the service
    /// has since cleared offers nothing.
    var openableLocation: ToolLocation? { kind == "tool" ? location?.value : nil }
}

// MARK: - Molecule

/// "Open at line 7", in an opened Pretty line: the transcript's quiet link. It is drawn only
/// while the cockpit says the file can be opened. A press that fails says why beneath it.
struct ToolLocationAction: View {
    let workerID: String
    /// The call's exact transcript detail key, so a press reads the same call's summary again.
    let detailKey: String
    let location: ToolLocation
    let intents: ToolLocationIntents
    let metrics: PrettyMetrics

    @State private var isOffered = false
    @State private var isOpening = false
    @State private var failure: ToolLocationError?

    nonisolated static func title(_ location: ToolLocation) -> String { "Open at line \(location.line)" }

    /// What a failed press reads as: what was not done, then the reason.
    nonisolated static func statement(_ error: ToolLocationError, location: ToolLocation) -> String {
        "Couldn't open the file at line \(location.line). " + (error.errorDescription ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isOffered || failure != nil {
                PrettyLinkButton(title: Self.title(location), size: metrics.detailSize) {
                    guard !isOpening else { return }
                    isOpening = true
                    Task {
                        failure = await intents.open(workerID, detailKey, location)
                        isOpening = false
                    }
                }
                .disabled(isOpening)
                // The file is named by the line above; no path or address is repeated here.
                .help("Opens the file this call reported, at line \(location.line), in Xcode")
                .accessibilityLabel(Self.title(location))
                .accessibilityHint("Opens the file this call reported in Xcode")
            }
            if let failure {
                Text(verbatim: Self.statement(failure, location: location))
                    .font(.system(size: metrics.detailSize))
                    .foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Room before the result only while something is drawn.
        .padding(.bottom, isOffered || failure != nil ? 10 : 0)
        // Checked when the line opens and when the record names another location.
        .task(id: location) {
            failure = nil
            isOffered = intents.offers(workerID, location)
        }
    }
}
