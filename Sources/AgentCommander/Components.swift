import AppKit
import SwiftUI

// COMPONENT CONTRACTS and the terminal leaf.
// Components receive these values and emit targeted actions. The mapping from the service types
// (Run, Worker, Question) lives at the bottom of this file, so no atom, molecule or organism reads
// the API model or a global "current worker". Design fixtures build the same values directly.

// MARK: - Shared vocabulary

enum Tone: Equatable {
    case working, attention, failure, focus, neutral

    var color: Color {
        switch self {
        case .working: Palette.working
        case .attention: Palette.attention
        case .failure: Palette.failure
        case .focus: Palette.focus
        case .neutral: Palette.secondary
        }
    }
}

enum AgentClient: Equatable {
    case claude, codex, mcp, other(String)

    init(_ raw: String?) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let key = value.lowercased()
        if key.contains("claude") { self = .claude }
        else if key.contains("codex") { self = .codex }
        else if key.contains("mcp") { self = .mcp }
        else { self = .other(value) }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .mcp: "MCP client"
        case .other(let name): name.isEmpty ? "Agent" : name
        }
    }
}

/// Task progress. Human attention (a pending request) is folded in only for the label; the request
/// itself stays a separate value on the worker.
enum TaskState: Equatable {
    case running, working, idle, needsInput, starting, stopping, completed, failed, stopped
    case unknown(String)

    init(api: String, hasPendingRequest: Bool = false) {
        if hasPendingRequest { self = .needsInput; return }
        switch api.lowercased() {
        case "running": self = .running
        case "working": self = .working
        case "idle": self = .idle
        case "waiting": self = .needsInput
        case "starting": self = .starting
        case "stopping": self = .stopping
        case "completed": self = .completed
        case "failed": self = .failed
        case "stopped": self = .stopped
        default: self = .unknown(api)
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .working: "Working"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown(let raw): raw.isEmpty ? "Unknown" : raw.capitalized
        }
    }

    var tone: Tone {
        switch self {
        case .running, .working, .completed: .working
        case .needsInput, .starting, .stopping: .attention
        case .failed: .failure
        case .idle, .stopped, .unknown: .neutral
        }
    }

    /// Distinct symbol used when Differentiate Without Color is on.
    var symbol: String {
        switch self {
        case .running, .working: "circle.fill"
        case .idle: "pause.circle"
        case .needsInput: "questionmark.circle.fill"
        case .starting, .stopping: "clock"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.diamond"
        }
    }
}

/// Terminal input ownership as the interface can truthfully state it today. The API has no lease,
/// so production always reports `.observing`; `.held` exists for the design fixture and the future lease.
enum InputControl: Equatable {
    case observing(holder: String)
    case held
}

// MARK: - Presentation values

struct RequestPresentation: Identifiable, Equatable {
    let id: String
    let shortID: String
    let question: String
    let workerID: String
    let workerName: String
    let workerIsCoordinator: Bool
    let client: AgentClient
    let runID: String
    let runTitle: String
    let project: String
    let host: String
    let inputHolder: String
    let contextTail: [String]
}

struct WorkerPresentation: Identifiable, Equatable {
    let id: String
    let shortID: String
    let name: String
    let client: AgentClient
    let host: String
    /// Branch when the service reports one, otherwise the worktree directory name.
    let location: String
    let locationIsBranch: Bool
    let task: String
    let output: String
    let error: String?
    let state: TaskState
    let isCoordinator: Bool
    /// Run title, then each parent worker, then this worker.
    let lineage: [String]
    let control: InputControl
    let request: RequestPresentation?
    /// Local clock time the worker started, when the service recorded it.
    let startedAt: String?
}

struct WorkerGroup: Identifiable, Equatable {
    let parent: WorkerPresentation
    let members: [WorkerPresentation]
    var id: String { parent.id }
    var all: [WorkerPresentation] { [parent] + members }
}

struct WallLayout: Equatable {
    var leaves: [WorkerPresentation] = []
    var groups: [WorkerGroup] = []
    var workers: [WorkerPresentation] { leaves + groups.flatMap(\.all) }
}

struct RunSummary: Identifiable, Equatable {
    let id: String
    let project: String
    let path: String
    let title: String
    let status: TaskState
}

struct RunContent: Identifiable, Equatable {
    let id: String
    let shortID: String
    let project: String
    let path: String
    let title: String
    let task: String
    let client: AgentClient
    let branch: String?
    let startedAt: String?
    let status: TaskState
    let canStop: Bool
    let coordinator: WorkerPresentation?
    let wall: WallLayout
    let awaiting: [RequestPresentation]
}

struct CockpitContent {
    var connection: CockpitModel.Connection
    var notice: String?
    var isStopping: Bool
    var runs: [RunSummary]
    var selected: RunContent?
    /// Pending requests across every run, oldest first.
    var pending: [RequestPresentation]
    var sending: Set<String>
}

/// Targeted intents emitted by the cockpit. Each names its run or request by stable ID.
struct CockpitActions {
    var selectRun: @MainActor (String) -> Void
    var reply: @MainActor (_ requestID: String, _ answer: String) async -> Bool
    var stopRun: @MainActor (_ runID: String) -> Void
    var reconnect: @MainActor () -> Void
    var dismissNotice: @MainActor () -> Void
    var createRun: @MainActor (_ path: String, _ task: String, _ title: String?, _ operationID: String) async throws -> Void
    /// Returns terminal input to its owner. Nil until the service exposes an input lease.
    var handBack: (@MainActor (_ workerID: String) -> Void)? = nil
    /// Types into a worker's terminal while the developer holds input. Nil until the service
    /// exposes terminal input, so the live app shows no terminal compose line.
    var sendTerminalInput: (@MainActor (_ workerID: String, _ text: String) -> Void)? = nil
    // Feature capabilities drawn in the concepts. Each control appears only when its action exists,
    // so the live app offers none of them until the service supports the operation.
    var messageCoordinator: (@MainActor (_ runID: String, _ text: String) -> Void)? = nil
    var searchWorkspace: (@MainActor () -> Void)? = nil
    var chooseWallGrouping: (@MainActor () -> Void)? = nil
}

// MARK: - Formatting helpers

enum Identifier {
    /// Compact form for display. The full value stays available to accessibility and copy actions.
    static func short(_ id: String) -> String {
        id.count > 10 ? String(id.prefix(8)) : id
    }
}

enum Timestamp {
    /// Local wall-clock time from an RFC 3339 value. Returns nil when the value is absent or unreadable.
    static func clock(_ value: String?, seconds: Bool = false) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let plain = try? Date(value, strategy: .iso8601)
        let fractional = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        guard let date = plain ?? fractional else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        return seconds ? String(format: "%02d:%02d:%02d", hour, minute, second)
                       : String(format: "%02d:%02d", hour, minute)
    }
}

enum PathDisplay {
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - TerminalWell (atom, AppKit leaf)

/// One opaque, selectable terminal projection. Every surface that shows a worker's output (wall tile,
/// focused worker, coordinator console) uses this view. It is passive: it never resizes the pane and
/// accepts no terminal input. Line tint is lexical only (prompt, check mark, cross, question) so plain
/// captured output stays readable; it adds no content.
struct TerminalWell: NSViewRepresentable {
    /// `tail` is the dense wall projection. `transcript` is the expanded reading view: it sets turn
    /// labels apart and insets each command with its results. Both render the same text.
    enum Style { case tail, transcript }

    let output: String
    let workerID: String
    var style: Style = .tail
    var workerName: String = ""
    var fontSize: CGFloat = TypeRole.wallTerminalSize
    var inset: NSSize = NSSize(width: 11, height: 12)
    /// Reports the laid-out height of the content, so a surface can place something directly after
    /// a short transcript. The well itself still scrolls when it is given less room than this.
    var onContentHeight: ((CGFloat) -> Void)? = nil

    @MainActor final class Coordinator: NSObject {
        var identity = ""
        var previous = ""
        var fontSize: CGFloat = 0
        var onContentHeight: ((CGFloat) -> Void)?
        weak var textView: NSTextView?
        private var reported: CGFloat = -1

        @objc func frameChanged(_ notification: Notification) { measure() }

        func measure() {
            guard onContentHeight != nil, let text = textView,
                  let container = text.textContainer, let manager = text.layoutManager else { return }
            manager.ensureLayout(for: container)
            let height = (manager.usedRect(for: container).height + text.textContainerInset.height * 2).rounded(.up)
            guard abs(height - reported) > 0.5 else { return }
            reported = height
            // Deliver after the current view update so SwiftUI state is not changed mid-layout.
            Task { @MainActor [weak self] in self?.onContentHeight?(height) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.textContainerInset = inset
        text.textContainer?.lineFragmentPadding = 0
        text.postsFrameChangedNotifications = true
        context.coordinator.textView = text
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.setAccessibilityLabel(workerName.isEmpty ? "Console output" : "Console output, \(workerName)")
        let cache = context.coordinator
        cache.onContentHeight = onContentHeight
        let changedPane = cache.identity != workerID
        guard changedPane || cache.previous != output || cache.fontSize != fontSize else { return }
        defer { cache.measure() }
        let following = changedPane || scroll.documentVisibleRect.maxY >= text.bounds.height - 6
        let savedOrigin = scroll.contentView.bounds.origin
        let oldSelection = text.selectedRange()
        text.textStorage?.setAttributedString(Self.styled(output, fontSize: fontSize, style: style))
        if !changedPane, NSMaxRange(oldSelection) <= text.string.utf16.count {
            text.setSelectedRange(oldSelection)
        }
        if following {
            text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
        } else {
            scroll.contentView.scroll(to: savedOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        cache.previous = output
        cache.identity = workerID
        cache.fontSize = fontSize
    }

    private static func styled(_ output: String, fontSize: CGFloat, style: Style) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (fontSize * 1.62).rounded()
        paragraph.lineBreakMode = .byWordWrapping
        let plain: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

        var pieces: [NSAttributedString] = []
        var codeParagraph: NSParagraphStyle?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if style == .transcript {
                // A command and its result lines, up to the next blank line, form one inset block.
                if codeParagraph != nil, trimmed.isEmpty {
                    codeParagraph = nil
                    continue
                }
                if codeParagraph == nil, trimmed.hasPrefix("$ ") {
                    codeParagraph = commandBlockParagraph(basedOn: paragraph)
                }
                if let codeParagraph {
                    pieces.append(NSAttributedString(string: line, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12.7, weight: .regular),
                        .foregroundColor: tint(for: line),
                        .paragraphStyle: codeParagraph
                    ]))
                    continue
                }
                if let label = turnLabel(trimmed, basedOn: paragraph) {
                    pieces.append(label)
                    continue
                }
            }
            pieces.append(NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: tint(for: line), .paragraphStyle: paragraph
            ]))
        }

        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            result.append(piece)
            guard index < pieces.count - 1 else { break }
            let attributes = piece.length > 0 ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : plain
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return result
    }

    /// Paragraph style that draws its lines inside one bordered, inset block (concept `.ck-codeblock`).
    private static func commandBlockParagraph(basedOn base: NSParagraphStyle) -> NSParagraphStyle {
        let block = NSTextBlock()
        block.backgroundColor = NSColor(hex: 0x0B0C10)
        block.setBorderColor(NSColor(white: 1, alpha: 0.13))
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(13, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(13, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(9, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(15, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.minimumLineHeight = (12.7 * 1.7).rounded()
        style.textBlocks = [block]
        return style
    }

    /// A line of the form "14:14:03 CODEX" is a turn label: a time and an upper-case speaker.
    private static func turnLabel(_ line: String, basedOn base: NSParagraphStyle) -> NSAttributedString? {
        let characters = Array(line)
        guard characters.count > 9, characters[2] == ":", characters[5] == ":", characters[8] == " " else { return nil }
        let time = String(characters[0..<8])
        let speaker = String(characters[9...])
        guard time.allSatisfy({ $0.isNumber || $0 == ":" }),
              speaker == speaker.uppercased(), speaker.contains(where: \.isLetter) else { return nil }
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 3
        let color = NSColor(hex: 0xB6BDC9)
        let label = NSMutableAttributedString(string: time, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.75, weight: .regular),
            .foregroundColor: color, .paragraphStyle: style
        ])
        label.append(NSAttributedString(string: "  " + speaker, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color, .kern: 1, .paragraphStyle: style
        ]))
        return label
    }

    private static func tint(for line: String) -> NSColor {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$ ") { return NSColor(hex: 0xF5F5F9) }
        if trimmed.hasPrefix("✓") || trimmed.hasPrefix("✔") { return NSColor(hex: 0xA5D7B6) }
        if trimmed.hasPrefix("✗") || trimmed.hasPrefix("✘") { return NSColor(hex: 0xEC9B92) }
        if trimmed.hasPrefix("? ") { return NSColor(hex: 0xF1C88E) }
        return NSColor(hex: 0xD3D7E1)
    }
}

// MARK: - Mapping from the service model (feature layer)

extension RunSummary {
    init(run: Run) {
        self.init(id: run.id, project: run.project, path: run.path, title: run.title,
                  status: TaskState(api: run.status))
    }
}

extension RunContent {
    init(run: Run) {
        let workers = run.workers ?? []
        let byID = Dictionary(workers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = (run.requests ?? []).filter { $0.status == "pending" }
        let requestByWorker = Dictionary(pending.map { ($0.workerID, $0) }, uniquingKeysWith: { first, _ in first })
        let runClient = run.client
        let runTitle = run.title
        let coordinatorID = run.coordinatorID

        func parents(of worker: Worker) -> [String] {
            var names: [String] = []
            var seen: Set<String> = [worker.id]
            var current = worker
            while let parent = byID[current.parentID], parent.id != coordinatorID, seen.insert(parent.id).inserted {
                names.insert(parent.name, at: 0)
                current = parent
            }
            return names
        }

        func present(_ worker: Worker) -> WorkerPresentation {
            let isCoordinator = worker.id == coordinatorID
            let ancestors = parents(of: worker)
            let holder = ancestors.last ?? runTitle
            let client = AgentClient(worker.client ?? runClient)
            let branch = worker.branch?.trimmingCharacters(in: .whitespaces) ?? ""
            let request = requestByWorker[worker.id].map { question in
                RequestPresentation(
                    id: question.id, shortID: Identifier.short(question.id), question: question.question,
                    workerID: worker.id, workerName: worker.name, workerIsCoordinator: isCoordinator,
                    client: client, runID: run.id, runTitle: runTitle, project: run.project, host: worker.host,
                    inputHolder: isCoordinator ? worker.name : holder,
                    contextTail: Self.tail(of: worker.output))
            }
            return WorkerPresentation(
                id: worker.id, shortID: Identifier.short(worker.id), name: worker.name, client: client,
                host: worker.host,
                location: branch.isEmpty ? URL(filePath: worker.worktree).lastPathComponent : branch,
                locationIsBranch: !branch.isEmpty,
                task: worker.task, output: worker.output, error: worker.error,
                state: TaskState(api: worker.state, hasPendingRequest: request != nil),
                isCoordinator: isCoordinator,
                lineage: isCoordinator ? [runTitle] : [runTitle] + ancestors + [worker.name],
                control: .observing(holder: isCoordinator ? worker.name : holder),
                request: request,
                startedAt: Timestamp.clock(worker.createdAt, seconds: true))
        }

        // Wall: root workers without children fill the top rows; a root with nested workers becomes a group.
        let delegates = run.delegates
        let delegateIDs = Set(delegates.map(\.id))
        let children = Dictionary(grouping: delegates, by: \.parentID)
        var layout = WallLayout()
        var visited = Set<String>()
        func descendants(of worker: Worker) -> [Worker] {
            var found: [Worker] = []
            for child in children[worker.id] ?? [] where visited.insert(child.id).inserted {
                found.append(child)
                found += descendants(of: child)
            }
            return found
        }
        for root in delegates where !delegateIDs.contains(root.parentID) {
            guard visited.insert(root.id).inserted else { continue }
            let nested = descendants(of: root)
            if nested.isEmpty {
                layout.leaves.append(present(root))
            } else {
                layout.groups.append(WorkerGroup(parent: present(root), members: nested.map(present)))
            }
        }
        // A parent cycle would leave workers unvisited; show them as leaves so nothing disappears.
        for worker in delegates where visited.insert(worker.id).inserted {
            layout.leaves.append(present(worker))
        }

        let coordinator = run.coordinator.map(present)
        let everyone = (coordinator.map { [$0] } ?? []) + layout.workers
        self.init(
            id: run.id, shortID: Identifier.short(run.id), project: run.project, path: run.path,
            title: runTitle, task: run.task, client: AgentClient(runClient),
            branch: run.branch.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: Timestamp.clock(run.createdAt),
            status: TaskState(api: run.status), canStop: run.canStop,
            coordinator: coordinator, wall: layout,
            awaiting: everyone.compactMap(\.request))
    }

    /// Last two non-empty lines of terminal output, used as context beside a pending question.
    static func tail(of output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(2).map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 }
    }
}

extension CockpitContent {
    @MainActor init(model: CockpitModel) {
        let contents = model.runs.map(RunContent.init(run:))
        self.init(connection: model.connection, notice: model.notice, isStopping: model.isStopping,
                  runs: model.runs.map(RunSummary.init(run:)),
                  selected: contents.first { $0.id == model.selectedID },
                  pending: contents.flatMap(\.awaiting),
                  sending: model.sending)
    }
}
