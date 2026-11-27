import AppKit
import Foundation

// ATOMIC LEVEL: Values (directory-backed projects and read-only links).
// A project is a folder the service has recorded, with or without runs. The service owns the
// catalog (GET and POST /v1/projects); the window lists it, groups runs under it and opens it.
//
//   Project               one catalog record: id, path, name
//   ProjectCatalogState   whether the service in use has a catalog at all
//   ProjectOpenOutcome    how recording a folder came out
//   ProjectEntry          one row of the Projects group: a recorded project with its runs, or, for
//                         a service without a catalog, the runs of one directory
//   CommanderLink         agentcommander://run/<id> and agentcommander://project/<id>, read-only
//   ProjectFolderPicker   the one NSOpenPanel for a local folder

/// A folder the service has recorded as a project.
struct Project: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let name: String

    /// Reads `{ "projects": [...] }`. A missing or null list is empty.
    static func list(json data: Data) throws -> [Project] {
        struct Catalog: Decodable { let projects: [Project]? }
        return try JSONDecoder().decode(Catalog.self, from: data).projects ?? []
    }

    /// The name to show: the service's, else the folder's own.
    var displayName: String { name.isEmpty ? URL(filePath: path).lastPathComponent : name }
}

/// What the app knows about the selected service's project catalog.
enum ProjectCatalogState: Equatable, Sendable {
    /// Not read yet.
    case unknown
    /// The service answered GET /v1/projects.
    case supported
    /// An older service: it has no catalog. Projects are the directories its runs name.
    case unsupported
}

/// How recording a folder came out.
enum ProjectOpenOutcome: Equatable, Sendable {
    case opened(Project)
    /// An older service: it records no projects. A run started in the folder still lists it.
    case noCatalog
    /// The service refused the folder. The reason is in the window's notice.
    case refused
}

/// One row of the Projects group.
struct ProjectEntry: Identifiable, Equatable, Sendable {
    /// The row's stable key: the project ID, or the directory for a run that names no project.
    let key: String
    /// The catalog ID. Nil for a legacy row grouped by directory.
    let projectID: String?
    let name: String
    let path: String
    /// The runs in this project, in the service's order: oldest first.
    let runIDs: [String]

    var id: String { key }

    /// The Projects group from the catalog and the runs.
    ///   1. Every recorded project, in the catalog's order, with the runs that name its ID. A run
    ///      that names no project joins the project recorded for its directory.
    ///   2. A run naming a project the catalog doesn't list yet keeps a row under that ID, so the
    ///      row stays put when the catalog catches up.
    ///   3. A run that names no project and matches no recorded directory is grouped by directory,
    ///      as before the catalog existed.
    static func list(catalog: [Project], runs: [RunSummary]) -> [ProjectEntry] {
        var order: [String] = []
        var names: [String: String] = [:], paths: [String: String] = [:], ids: [String: String] = [:]
        var members: [String: [String]] = [:]
        var keyByPath: [String: String] = [:]
        for project in catalog where names[project.id] == nil {
            order.append(project.id)
            names[project.id] = project.displayName
            paths[project.id] = project.path
            ids[project.id] = project.id
            if keyByPath[project.path] == nil { keyByPath[project.path] = project.id }
        }
        for run in runs {
            let key = run.projectID ?? keyByPath[run.path] ?? run.path
            if names[key] == nil {
                order.append(key)
                names[key] = run.project
                paths[key] = run.path
                if let id = run.projectID { ids[key] = id }
            }
            members[key, default: []].append(run.id)
        }
        return order.map { key in
            ProjectEntry(key: key, projectID: ids[key], name: names[key] ?? "", path: paths[key] ?? "",
                         runIDs: members[key] ?? [])
        }
    }

    /// The row a run belongs to.
    static func entry(for run: RunSummary, in entries: [ProjectEntry]) -> ProjectEntry? {
        entries.first { $0.runIDs.contains(run.id) }
    }
}

extension RunContent {
    /// Still going: the service calls the run running, or it failed with workers left to stop.
    var isActive: Bool { status == .running || canStop }
}

// MARK: - Links

/// A read-only link into the main window. It names a run or a project of the service in use by
/// its exact ID and only shows it: a link never starts, stops or changes anything.
///
///     agentcommander://run/r-0123456789abcdef0123456789abcdef
///     agentcommander://project/p-0123456789abcdef0123456789abcdef
enum CommanderLink: Equatable, Sendable {
    case run(String)
    case project(String)

    static let scheme = "agentcommander"

    /// Nil for anything else: another scheme or host, an ID of the wrong shape, more path, a
    /// query, a fragment, a port or credentials.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), parts.path.hasPrefix("/") else { return nil }
        let id = String(parts.path.dropFirst())
        switch host {
        case "run" where Self.isID(id, prefix: "r-"): self = .run(id)
        case "project" where Self.isID(id, prefix: "p-"): self = .project(id)
        default: return nil
        }
    }

    /// `^[rp]-[0-9a-f]{32}$`, with the prefix the link's kind requires.
    static func isID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let digits = text.dropFirst(prefix.count).utf8
        return digits.count == 32 && digits.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var id: String {
        switch self { case .run(let id), .project(let id): id }
    }

    /// What the link names, for a sentence: "Run r-0123…".
    var subject: String {
        switch self {
        case .run(let id): "Run \(Identifier.short(id))"
        case .project(let id): "Project \(Identifier.short(id))"
        }
    }
}

// MARK: - Folder picker

/// The local folder picker. It is offered only while the app uses this Mac's service: a folder
/// chosen here is a path on this Mac.
@MainActor
enum ProjectFolderPicker {
    /// The chosen folder's standardized path. Nil when the panel was cancelled.
    static func pick(prompt: String = "Open Folder", startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = "Choose a folder to open as a project."
        if let path, !path.isEmpty { panel.directoryURL = URL(filePath: path, directoryHint: .isDirectory) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    /// A path typed for a headless host: absolute, with no trailing slash. Nil when it isn't absolute.
    static func typed(_ text: String) -> String? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
