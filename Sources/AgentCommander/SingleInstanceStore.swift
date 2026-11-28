import Darwin
import Foundation
import Synchronization

// Launch admission for "Allow only one instance". Foundation and Darwin only, so it runs before
// NSApplication exists and tests can drive it in a private temp folder.
//
//   ~/Library/Application Support/<bundle id>/Launch/     owner-only (0700)
//     admission.lock   never removed; flock'd only while a launch registers or hands off
//     <pid>.lease      one per running Commander, flock'd for the life of that process; empty, or
//                      the production app's startup evidence (LaunchEvidence.swift)
//     <pid>.focus      "bring the cockpit forward"; at most one per lease, so requests coalesce
//
// The kernel drops a lease's lock when its process exits or crashes. A lease anyone else can lock
// is stale and is removed, with its marker, by the next admission. Every descriptor is O_CLOEXEC,
// so helpers Commander starts can't keep a lease alive. The folder comes from the password
// database and the bundle identifier, never from the install path, the process list or $HOME.

enum SingleInstanceError: Error, Equatable, CustomStringConvertible {
    case unsafeFolder(String)
    case busy(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .unsafeFolder(let path):
            "\(path) must be a folder you own that other users can't change"
        case .busy(let path):
            "another launch is holding \(path); quit the copy that isn't responding and try again"
        case .system(let action, let code):
            "couldn't \(action): \(String(cString: strerror(code)))"
        }
    }
}

enum SingleInstanceAdmission: Sendable {
    /// This process holds a lease and continues launching.
    case registered(SingleInstanceMembership)
    /// The live Commander with this pid has a pending focus request; this process should exit.
    case handedOff(Int32)
}

final class SingleInstanceStore: Sendable {
    let directory: URL
    let lockTimeout: Duration

    /// This user's store for the running bundle. An unbundled build gets its own namespace.
    static func current(bundle: Bundle = .main) throws -> SingleInstanceStore {
        guard let account = getpwuid(geteuid()), let home = account.pointee.pw_dir else {
            throw SingleInstanceError.system("find your home folder", ENOENT)
        }
        let support = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let executable = bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
        return try SingleInstanceStore(
            identifier: identifier(bundleIdentifier: bundle.bundleIdentifier, executable: executable),
            applicationSupport: support)
    }

    /// The bundle identifier as one safe path component.
    static func identifier(bundleIdentifier: String?, executable: String) -> String {
        let raw = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "unbundled." + executable
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let safe = String(raw.prefix(200).map { allowed.contains($0) ? $0 : "-" })
        return safe.hasPrefix(".") ? "-" + safe.dropFirst() : safe
    }

    /// Creates or verifies `<support>/<identifier>/Launch`. Application Support may be a link; the
    /// two folders below it must be real folders owned by this user.
    init(identifier: String, applicationSupport: URL, lockTimeout: Duration = .seconds(2)) throws {
        self.lockTimeout = lockTimeout
        let support = applicationSupport.path(percentEncoded: false)
        try Self.makeFolder(support)
        guard let resolved = realpath(support, nil) else { throw SingleInstanceError.system("resolve \(support)", errno) }
        let root = String(cString: resolved)
        free(resolved)
        try Self.requireFolder(root, ownerOnly: false)
        let application = root + "/" + identifier
        try Self.makeFolder(application)
        try Self.requireFolder(application, ownerOnly: false)
        let launch = application + "/Launch"
        try Self.makeFolder(launch)
        try Self.requireFolder(launch, ownerOnly: true)
        directory = URL(fileURLWithPath: launch, isDirectory: true)
    }

    /// Registers this process, or, when only one instance is allowed and another Commander is live,
    /// leaves a focus request for the lowest live pid and reports the handoff. `willHandOff` runs
    /// before the request is posted, so activation can be yielded before the target acts on it.
    func admit(onlyOneInstance: Bool, pid: Int32 = getpid(),
               willHandOff: (Int32) -> Void = { _ in }) throws -> SingleInstanceAdmission {
        try withAdmissionLock {
            var live = try liveProcesses().filter { $0 != pid }
            while onlyOneInstance, let target = live.first {
                willHandOff(target)
                try requestFocus(of: target)
                if try isLeaseHeld(target) { return .handedOff(target) }
                // The target exited while the request was posted; try the next live process.
                unlink(path(target, ".lease"))
                unlink(path(target, ".focus"))
                live.removeFirst()
            }
            return .registered(try register(pid))
        }
    }

    /// Live pids, lowest first. Removes stale leases and markers on the way.
    func members() throws -> [Int32] {
        try withAdmissionLock { try liveProcesses() }
    }

    // MARK: Admission lock held

    private func withAdmissionLock<Result>(_ body: () throws -> Result) throws -> Result {
        let lockPath = directory.path(percentEncoded: false) + "/admission.lock"
        let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw SingleInstanceError.system("open \(lockPath)", errno) }
        defer { close(lock) }
        let deadline = ContinuousClock.now + lockTimeout
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw SingleInstanceError.system("lock \(lockPath)", code)
            }
            guard ContinuousClock.now < deadline else { throw SingleInstanceError.busy(lockPath) }
            usleep(2_000)
        }
        return try body()
    }

    private func liveProcesses() throws -> [Int32] {
        let folder = directory.path(percentEncoded: false)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw SingleInstanceError.system("list \(folder)", Int32(posix?.code ?? Int(EIO)))
        }
        var live: [Int32] = []
        for name in names {
            guard let pid = Self.pid(name, suffix: ".lease") else { continue }
            if try isLeaseHeld(pid) { live.append(pid) } else { unlink(path(pid, ".lease")) }
        }
        for name in names {
            guard let pid = Self.pid(name, suffix: ".focus"), !live.contains(pid) else { continue }
            unlink(path(pid, ".focus"))
        }
        return live.sorted()
    }

    /// True while the owning process holds its lock (the probe gets EWOULDBLOCK). False only when the
    /// lease is proven stale: it is gone, or this probe could lock it. Any other open or lock failure
    /// throws, so the caller never removes a record it couldn't prove stale.
    private func isLeaseHeld(_ pid: Int32) throws -> Bool {
        let leasePath = path(pid, ".lease")
        var lease: Int32
        repeat {
            lease = open(leasePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        } while lease < 0 && errno == EINTR
        guard lease >= 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw SingleInstanceError.system("open \(leasePath)", code)
        }
        defer { close(lease) }
        while flock(lease, LOCK_SH | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK { return true }
            guard code == EINTR else { throw SingleInstanceError.system("lock \(leasePath)", code) }
        }
        return false
    }

    /// Creates the marker if absent. An existing regular-file marker already asks for the same
    /// thing; anything else in its place can't carry the request, so admission fails.
    private func requestFocus(of pid: Int32) throws {
        let marker = path(pid, ".focus")
        while true {
            let file = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if file >= 0 {
                close(file)
                return
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EEXIST else { throw SingleInstanceError.system("create \(marker)", code) }
            var info = stat()
            if lstat(marker, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw SingleInstanceError.system("use \(marker)", EFTYPE) }
                return
            }
            // The target consumed the marker between the two calls; post a fresh request.
            guard errno == ENOENT else { throw SingleInstanceError.system("inspect \(marker)", errno) }
        }
    }

    private func register(_ pid: Int32) throws -> SingleInstanceMembership {
        let lease = path(pid, ".lease")
        // O_EXLOCK locks the lease as it is created, so no launch ever sees it unlocked.
        let descriptor = open(lease, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw SingleInstanceError.system("create \(lease)", errno) }
        return SingleInstanceMembership(pid: pid, directory: directory, marker: path(pid, ".focus"),
                                        leaseDescriptor: descriptor)
    }

    private func path(_ pid: Int32, _ suffix: String) -> String {
        directory.path(percentEncoded: false) + "/" + String(pid) + suffix
    }

    private static func pid(_ name: String, suffix: String) -> Int32? {
        guard name.hasSuffix(suffix) else { return nil }
        let digits = String(name.dropLast(suffix.count))
        guard let pid = Int32(digits), pid > 0, String(pid) == digits else { return nil }
        return pid
    }

    // MARK: Folders

    private static func makeFolder(_ path: String) throws {
        guard mkdir(path, 0o700) != 0 else { return }
        let code = errno
        if code != EEXIST { throw SingleInstanceError.system("create \(path)", code) }
    }

    /// A real folder (not a link) owned by this user that no one else can change. `ownerOnly`
    /// also removes group and other read access.
    private static func requireFolder(_ path: String, ownerOnly: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw SingleInstanceError.system("inspect \(path)", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw SingleInstanceError.unsafeFolder(path)
        }
        if ownerOnly {
            if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
                throw SingleInstanceError.system("make \(path) private", errno)
            }
        } else if info.st_mode & 0o022 != 0 {
            throw SingleInstanceError.unsafeFolder(path)
        }
    }
}

/// This process's lease. It stays locked until the process exits (or `relinquish()` in tests).
final class SingleInstanceMembership: Sendable {
    let pid: Int32
    let directory: URL
    private let marker: String
    private let lease: Mutex<Int32>

    init(pid: Int32, directory: URL, marker: String, leaseDescriptor: Int32) {
        self.pid = pid
        self.directory = directory
        self.marker = marker
        lease = Mutex(leaseDescriptor)
    }

    deinit { relinquish() }

    /// Consumes the pending focus request, if any. Any number of launches yield one true.
    func takeFocusRequest() -> Bool {
        unlink(marker) == 0
    }

    /// Calls `handler` on `queue` whenever the Launch folder changes. Kernel-delivered; nothing
    /// polls. Call `takeFocusRequest()` after installing it so an earlier request isn't missed.
    func watch(queue: DispatchQueue,
               handler: @escaping @Sendable () -> Void) throws -> any DispatchSourceFileSystemObject {
        let folder = directory.path(percentEncoded: false)
        let descriptor = open(folder, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SingleInstanceError.system("watch \(folder)", errno) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                               queue: queue)
        source.setEventHandler { handler() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    static let evidenceLimit = 4096

    /// Writes this process's startup evidence to the held lease, once. The lease keeps its lock
    /// and its name. A short or failed write leaves the lease empty again and throws.
    func recordEvidence(_ record: Data) throws {
        try lease.withLock { descriptor in
            guard descriptor >= 0 else { throw SingleInstanceError.system("record launch evidence", EBADF) }
            guard !record.isEmpty, record.count <= Self.evidenceLimit else {
                throw SingleInstanceError.system("record launch evidence", EINVAL)
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SingleInstanceError.system("inspect the lease", errno) }
            guard info.st_size == 0 else { throw SingleInstanceError.system("record launch evidence", EEXIST) }
            var written: Int
            repeat {
                written = record.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            } while written < 0 && errno == EINTR
            guard written == record.count else {
                let code = written < 0 ? errno : EIO
                ftruncate(descriptor, 0)
                throw SingleInstanceError.system("record launch evidence", code)
            }
        }
    }

    /// Drops the lease exactly as process exit would. The next admission removes the records.
    func relinquish() {
        lease.withLock { descriptor in
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
    }
}
