import SwiftUI

// ATOMIC LEVEL: Pages (sample values for the design previews).
// Representative hosts, runs, workers and outcomes for the views that are not connected to the
// service yet. These values are passed to the same pages the product will use; nothing here is
// reachable in a normal launch.

@MainActor
enum PreviewSample {
    // MARK: Workspace

    private static func console(_ id: String, _ title: String, _ role: String, _ client: AgentClient, _ host: String,
                                remote: Bool, _ branch: String, _ project: String, _ run: String, _ state: String,
                                _ tone: Tone, _ lines: [(ConsolePreview.Line.Kind, String)]) -> AgentConsole {
        AgentConsole(id: id, title: title, role: role, client: client, host: host, isRemote: remote, branch: branch,
                     project: project, runID: run, state: state, tone: tone, lines: ConsolePreview.make(lines))
    }

    /// The six consoles of the All agents concept. `tick` advances the changing lines.
    static func agents(tick: Int) -> [AgentConsole] {
        let findings = max(0, 2 - tick % 3)
        let waiting = findings == 0 ? "Both findings received. Drafting the plan…"
            : "Waiting for \(findings) finding\(findings == 1 ? "" : "s")…"
        let tests = ["tests/backoff.test.ts   | 16 +++", "tests/backoff.test.ts   | 19 ++++", "tests/backoff.test.ts   | 23 +++++"]
        return [
            console("retry-policy", "Retry policy", "Coordinator", .claude, "Mac Studio", remote: false, "main", "Relay", "R-042",
                    "Working", .working,
                    [(.label, "COORDINATOR"),
                     (.text, "I’ll trace timeout handling and split the retry changes into isolated worktrees."),
                     (.command, "delegate → Backoff strategy"), (.command, "delegate → Failure paths"), (.quiet, waiting)]),
            console("backoff", "Backoff strategy", "Worker", .codex, "Mac Studio", remote: false, "feat/backoff", "Relay", "R-042",
                    "Working", .working,
                    [(.command, "$ git diff --stat"), (.text, " src/retry/backoff.ts    | 28 +++++"),
                     (.text, " " + tests[tick % tests.count]), (.label, "CODEX"),
                     (.text, "Added capped exponential backoff with deterministic jitter.")]),
            console("timeout", "Timeout cases", "Nested worker", .codex, "build-01", remote: true, "main", "Relay", "R-042",
                    "Needs input", .attention,
                    [(.label, "QUESTION  ·  Q-018"),
                     (.text, "Should the client retry after response body bytes have already been delivered?"),
                     (.quiet, "Parent  /  Failure paths"), (.wait, "Awaiting product decision")]),
            console("event-schema", "Event schema", "Coordinator", .codex, "Mac Studio", remote: false, "main", "Relay", "R-039",
                    "Working", .working,
                    [(.label, "COORDINATOR"), (.text, "Checking public consumers before we drop the legacy field."),
                     (.command, "read → schema/events.json"), (.quiet, "2 workers attached")]),
            console("api-compat", "API compatibility", "Worker", .mcp, "Mac Studio", remote: false, "main", "Relay", "R-042",
                    "Idle", .neutral,
                    [(.label, "RESULT"),
                     (.text, "Both versions accept the existing retry_after field. No schema migration is required."),
                     (.command, "result → Retry policy"), (.quiet, "Turn complete")]),
            console("queue-migration", "Queue migration", "Coordinator", .codex, "lab-02", remote: true, "queue-v2", "Beacon", "R-038",
                    "Disconnected", .neutral,
                    [(.command, "$ go test ./queue/..."), (.text, "ok    beacon/queue/codec"),
                     (.quiet, "Last output 14:13:16"), (.wait, "SSH link interrupted")])
        ]
    }

    /// Remote workers that the smart view lists beside the consoles above.
    static func remoteAgents(tick: Int) -> [AgentConsole] {
        let all = agents(tick: tick)
        let metric = ["+ retry_attempt_total", "+ retry_exhausted_total", "Updating metric assertions…"][tick % 3]
        let extras: [AgentConsole] = [
            console("failure-paths", "Failure paths", "Worker", .claude, "build-01", remote: true, "main", "Relay", "R-042",
                    "Working", .working,
                    [(.text, "Mapped retry eligibility across connect, headers and body reads."),
                     (.command, "delegate → Timeout cases"), (.quiet, "Waiting for 1 finding…")]),
            console("telemetry", "Retry telemetry", "Worker", .codex, "build-01", remote: true, "feat/telemetry", "Relay", "R-042",
                    "Working", .working,
                    [(.command, "$ rg 'retry.count' src/"), (.text, "Editing metrics/requests.ts"), (.text, metric)]),
            console("schema-migration", "Schema migration", "Worker", .codex, "build-01", remote: true, "main", "Relay", "R-039",
                    "Working", .working,
                    [(.command, "$ pnpm migrate --dry-run"), (.good, "✓ 3 consumers accept both field names")])
        ]
        let remote = all.filter(\.isRemote)
        let local = all.filter { !$0.isRemote }
        return remote + extras + local
    }

    static let smartViewRules: [ViewRule] = [
        ViewRule(id: "host", name: "Host type", symbol: "server.rack", options: ["SSH host", "Local host", "Any host"], value: "SSH host"),
        ViewRule(id: "lifecycle", name: "Lifecycle", symbol: "waveform.path.ecg",
                 options: ["Active sessions", "Working", "Needs attention"], value: "Active sessions"),
        ViewRule(id: "project", name: "Project", symbol: "folder", options: ["Any project", "Relay", "Beacon"], value: "Any project"),
        ViewRule(id: "group", name: "Group by", symbol: "square.stack.3d.up", options: ["Coordinator run", "Host"], value: "Coordinator run"),
        ViewRule(id: "sort", name: "Sort by", symbol: "arrow.up.arrow.down", options: ["Recent activity", "Name"], value: "Recent activity")
    ]

    static let checkouts: [CheckoutLink] = [
        CheckoutLink(id: "~/Developer/relay", host: "Mac Studio", worktree: "main", identity: "Primary checkout"),
        CheckoutLink(id: "~/.worktrees/relay/backoff", host: "Mac Studio", worktree: "feat/backoff", identity: "Linked"),
        CheckoutLink(id: "~/src/relay", host: "build-01", worktree: "main", identity: "Verified origin"),
        CheckoutLink(id: "~/.worktrees/relay/telemetry", host: "build-01", worktree: "feat/telemetry", identity: "Linked")
    ]

    static let identityChecks: [IdentityCheck] = [
        IdentityCheck(id: "Project directory", project: "~/Developer/relay", candidate: "~/sandbox/relay", agrees: false),
        IdentityCheck(id: "Host", project: "Mac Studio", candidate: "lab-02"),
        IdentityCheck(id: "Git origin", project: "git.example/infra/relay", candidate: "No origin configured", agrees: false),
        IdentityCheck(id: "Current branch", project: "main", candidate: "main", isBranch: true),
        IdentityCheck(id: "Shared commit", project: "7b21ae4", candidate: "7b21ae4")
    ]

    static let resolvedToday: [ResolvedRequest] = [
        ResolvedRequest(id: "Q-016", workerName: "API compatibility", time: "14:09"),
        ResolvedRequest(id: "Q-011", workerName: "Schema migration", time: "13:42")
    ]

    // MARK: Delegation

    static let delegation = DelegationSetup(
        kicker: "RELAY / RETRY POLICY",
        context: "R-042 started at 14:08. Claude Code is preparing workspace A-044 for a coding worker.",
        assignmentID: "A-044",
        workerName: "Retry telemetry",
        instructions: "Add retry counters and structured backoff events. Return the changed revision and the telemetry test results.",
        clients: ["Codex", "Claude Code", "Generic MCP client"],
        models: ["Codex default", "Sonnet"],
        hosts: ["build-01", "Mac Studio"],
        sourceHost: "Mac Studio",
        sourceCheckout: "~/Developer/relay",
        baseRevision: "main · 7b21ae4",
        workerBranch: "feat/telemetry",
        changes: [WorkingChange(id: "src/retry.ts", kind: "Modified"),
                  WorkingChange(id: "tests/retry.test.ts", kind: "Staged"),
                  WorkingChange(id: "notes.local", kind: "Untracked")],
        included: ["src/retry.ts", "tests/retry.test.ts"],
        worktree: "~/.worktrees/relay/telemetry/",
        slotsNote: "Retry policy · 4 of 10 worker slots allocated")

    private static func log(_ lines: [(String?, String)]) -> [LogLine] {
        lines.enumerated().map { LogLine(id: $0.offset + 1, tag: $0.element.0, text: $0.element.1) }
    }

    private static let failedAttempts: [IntegrationAttempt] = [
        IntegrationAttempt(
            id: "#03", title: "Telemetry event count mismatch", time: "14:49", revision: "993fdd8", outcome: .failed,
            duration: "42.8s",
            log: log([("RUN", "Relay combined test suite"), ("PASS", "tests/backoff.test.ts (18)"),
                      ("PASS", "tests/telemetry.test.ts (12)"), ("FAIL", "tests/retry.integration.test.ts"),
                      (nil, "Expected 2 retry events, received 3.")]),
            suiteTitle: "Combined suite failed", suiteDetail: "One of 36 tests failed at 993fdd8.",
            summary: "14:49 · Attempt 03 failed its combined test. The target branch remains at c914b0e."),
        IntegrationAttempt(
            id: "#02", title: "Target branch advanced", time: "14:45", revision: "9ea311b", outcome: .stale,
            suiteTitle: "Target branch advanced", suiteDetail: "main moved while 9ea311b was being tested, so the result no longer applies.",
            summary: "14:45 · Attempt 02 was tested against a base that main has since left."),
        IntegrationAttempt(
            id: "#01", title: "Conflicting edit in src/retry.ts", time: "14:41", revision: "e51b470", outcome: .conflict,
            suiteTitle: "Handoffs conflict", suiteDetail: "Backoff strategy and Retry telemetry both edited src/retry.ts. The suite did not run.",
            summary: "14:41 · Attempt 01 could not combine the two handoffs.")
    ]

    static func integration(blocked: Bool) -> IntegrationReview {
        let passed = IntegrationAttempt(
            id: "#04", title: "Combined tests passed", time: "14:53", revision: "a6f491e", outcome: .passed,
            duration: "42.8s",
            log: log([("RUN", "Relay combined test suite"), ("PASS", "tests/backoff.test.ts (18)"),
                      ("PASS", "tests/telemetry.test.ts (12)"), ("PASS", "tests/retry.integration.test.ts (6)"),
                      ("PASS", "36 passed across 3 files")]),
            suiteTitle: "Combined suite passed", suiteDetail: "36 tests passed at a6f491e.",
            summary: "14:53 · Attempt 04 passed after Retry telemetry corrected the event count.")
        return IntegrationReview(
            kicker: "RELAY / RETRY POLICY", target: "Relay / main", targetBranch: "main", coordinatorHost: "Mac Studio",
            expectedHead: "c914b0e", command: "pnpm test",
            handoffs: [Handoff(id: "Backoff strategy", branch: "feat/backoff", revision: "88ea7c1", tests: "18 passed"),
                       Handoff(id: "Retry telemetry", branch: "feat/telemetry", revision: blocked ? "5315de0" : "d803ef2",
                               tests: "12 passed")],
            attempts: blocked ? failedAttempts : [passed] + failedAttempts,
            remediationTargets: ["Retry telemetry · W-044", "Backoff strategy · W-043", "Retry policy · coordinator"],
            worktreeNote: "Disposable worktree · Mac Studio",
            diffStat: log([(nil, "src/retry/backoff.ts        | 42 ++++++"), (nil, "src/retry/budget.ts         | 18 +++"),
                           (nil, "src/metrics/requests.ts     | 27 ++++"), (nil, "tests/retry.integration.ts  | 31 +++++"),
                           (nil, "4 files changed, 118 insertions(+)")]))
    }

    static let transcriptMatches: [TranscriptMatch] = [
        TranscriptMatch(
            id: "m1", worker: "Timeout cases", runID: "R-042", runTitle: "Retry policy", project: "Relay",
            client: "Codex", host: "build-01", parent: "Failure paths", workspace: "main · review",
            position: "14:31:08 · line 218", time: "14:31",
            excerpt: "Should timeout budget include the initial request?",
            lines: [
                TranscriptLine(id: 216, time: "14:30:55", speaker: "codex", text: "Boundary cases cover an expired deadline and a"),
                TranscriptLine(id: 217, text: "retry scheduled exactly at the deadline."),
                TranscriptLine(id: 218, time: "14:31:08", speaker: "question",
                               text: "Should timeout budget include the initial request?", isHit: true),
                TranscriptLine(id: 219, time: "14:31:44", speaker: "Failure paths · owning coordinator",
                               text: "Yes. Measure from the first attempt and stop"),
                TranscriptLine(id: 220, text: "when the end-to-end deadline is reached."),
                TranscriptLine(id: 221, time: "14:31:46", speaker: "codex", text: "I’ll add that expectation to the boundary tests.")
            ],
            gapTitle: "Recording gap · 14:34:11–14:36:32",
            gapDetail: "build-01 disconnected. Recording resumed at 14:36:32.",
            resolution: "Failure paths answered Q-024 at 14:31:44."),
        TranscriptMatch(
            id: "m2", worker: "Failure paths", runID: "R-042", runTitle: "Retry policy", project: "Relay",
            client: "Claude Code", host: "build-01", parent: "Retry policy", workspace: "main",
            position: "14:24:19 · line 142", time: "14:24",
            excerpt: "Compare elapsed time to the timeout budget.",
            lines: [
                TranscriptLine(id: 141, time: "14:24:02", speaker: "claude code", text: "Each retry path needs one shared clock."),
                TranscriptLine(id: 142, time: "14:24:19", speaker: "claude code",
                               text: "Compare elapsed time to the timeout budget.", isHit: true),
                TranscriptLine(id: 143, text: "Stop scheduling attempts once it is spent.")
            ]),
        TranscriptMatch(
            id: "m3", worker: "Backoff strategy", runID: "R-042", runTitle: "Retry policy", project: "Relay",
            client: "Codex", host: "Mac Studio", parent: "Retry policy", workspace: "feat/backoff",
            position: "14:18:40 · line 96", time: "14:18",
            excerpt: "Clamp jitter to the remaining timeout budget.",
            lines: [
                TranscriptLine(id: 95, time: "14:18:31", speaker: "codex", text: "Jitter can push the last delay past the deadline."),
                TranscriptLine(id: 96, time: "14:18:40", speaker: "codex",
                               text: "Clamp jitter to the remaining timeout budget.", isHit: true),
                TranscriptLine(id: 97, time: "14:18:52", speaker: "codex", text: "✓ jitter stays within cap")
            ]),
        TranscriptMatch(
            id: "m4", worker: "Request lifecycle", runID: "R-037", runTitle: "Transport review", project: "Relay",
            client: "Claude Code", host: "Mac Studio", parent: "Transport review", workspace: "docs/transport",
            position: "Yesterday 16:02:11 · line 54", time: "Yesterday",
            excerpt: "Document the per-request timeout budget.",
            lines: [
                TranscriptLine(id: 53, time: "16:01:58", speaker: "claude code", text: "The lifecycle page omits deadlines."),
                TranscriptLine(id: 54, time: "16:02:11", speaker: "claude code",
                               text: "Document the per-request timeout budget.", isHit: true)
            ])
    ]

    static let crossRun = CrossRunAccess(
        kicker: "RELAY / EVENT SCHEMA",
        context: "14:23 · Event schema is inspecting a worker assigned to Retry policy.",
        workerName: "Retry telemetry", workerDetail: "Codex · build-01", branch: "feat/telemetry",
        assignmentID: "A-044", workerID: "W-044",
        owner: "Retry policy · R-042", ownerAddress: "Claude Code · Retry policy · R-042",
        actingAs: "Event schema · R-039", deniedCommand: "worker.interrupt", outcome: "permission_denied",
        explanation: "Event schema can read project history and ask the owner a question. Retry policy must issue any command to its worker.",
        transcript: [
            SharedEntry(id: 1, time: "14:21:10", speaker: "codex", text: "Reviewed the retry event payload."),
            SharedEntry(id: 2, time: "14:21:34", speaker: "codex", text: "request_id is present on each attempt."),
            SharedEntry(id: 3, time: "14:22:03", speaker: "finding", text: "Keeping retry_after preserves compatibility.", isFinding: true)
        ],
        question: "Can Event schema depend on retry_after remaining in the next payload version?",
        historyNote: "Shared project history · Relay")

    // MARK: Setup and recovery

    static let setupHosts: [SetupHost] = [
        SetupHost(id: "Mac Studio", detail: "This Mac · local discovery", symbol: "desktopcomputer", isRemote: false),
        SetupHost(id: "build-01", detail: "SSH alias · persistent helper available", symbol: "server.rack", isRemote: true),
        SetupHost(id: "lab-02", detail: "SSH alias · SSH-only", symbol: "server.rack", isRemote: true)
    ]

    static let discoveredSessions: [DiscoveredSession] = [
        DiscoveredSession(id: "s1", client: .claude, place: "Mac Studio · relay:0.1", state: .working),
        DiscoveredSession(id: "s2", client: .codex, place: "build-01 · relay:1.0", state: .idle),
        DiscoveredSession(id: "s3", client: .codex, place: "lab-02 · beacon:0.0", state: .idle)
    ]

    static let hosts: [EnrolledHost] = [
        EnrolledHost(id: "Mac Studio", kind: "This Mac", typeLabel: "Local host", symbol: "desktopcomputer", isConnected: true,
                     mode: "Local service", checkout: "~/Developer/relay", activeRun: "Retry policy · R-042", lastSeen: nil),
        EnrolledHost(id: "build-01", kind: "SSH · Persistent helper", typeLabel: "SSH host", symbol: "server.rack", isConnected: true,
                     mode: "Persistent helper", checkout: "~/src/relay", activeRun: "Retry policy · R-042", lastSeen: nil),
        EnrolledHost(id: "lab-02", kind: "SSH-only", typeLabel: "SSH host", symbol: "server.rack", isConnected: false,
                     mode: "SSH-only", checkout: "~/sandbox/relay", activeRun: "Queue migration · R-038", lastSeen: "14:13:16")
    ]

    static let hostCapabilities: [CapabilityComparison] = [
        CapabilityComparison(id: "Existing tmux work", persistentHelper: "Can continue", sshOnly: "Can continue"),
        CapabilityComparison(id: "Remote coordination", persistentHelper: "Within run limits", sshOnly: "Wait for reconnect"),
        CapabilityComparison(id: "Pending decisions", persistentHelper: "Retained on host", sshOnly: "Review on reconnect"),
        CapabilityComparison(id: "Recoverable history", persistentHelper: "Durable events", sshOnly: "Available scrollback")
    ]

    private static let clientCapabilities: [ClientCapability] = [
        ClientCapability(id: "Register and delegate", detail: "Create independently controllable worker tiles"),
        ClientCapability(id: "Receive messages", detail: "Read the Commander inbox with a bounded wait"),
        ClientCapability(id: "Report results", detail: "Return findings, questions, and status to the parent")
    ]

    static let clients: [ClientProfile] = [
        ClientProfile(id: "claude", kind: "Discovered client", symbol: "terminal", tone: .attention, isLaunchProfile: false,
                      name: "Claude Code", executable: "/opt/homebrew/bin/claude", arguments: "(client defaults)",
                      mcpCommand: "agent-commander-mcp", connectionTest: "Tool list received · registration verified",
                      capabilities: clientCapabilities + [ClientCapability(id: "Answer approvals", detail: "Pending approvals can be answered from Commander")],
                      delegationMode: "Managed",
                      delegationDetail: "Commander configures this client’s delegation tools and project instructions, so coordinators delegate through Commander.",
                      hint: "Incoming messages wake the client through its hook."),
        ClientProfile(id: "codex", kind: "Discovered client", symbol: "chevron.left.forwardslash.chevron.right", tone: .focus,
                      isLaunchProfile: false, name: "Codex", executable: "/opt/homebrew/bin/codex", arguments: "(client defaults)",
                      mcpCommand: "agent-commander-mcp", connectionTest: "Tool list received · registration verified",
                      capabilities: clientCapabilities, delegationMode: "Managed",
                      delegationDetail: "Commander configures this client’s delegation tools and project instructions, so coordinators delegate through Commander.",
                      hint: "Incoming messages arrive on the next inbox read."),
        ClientProfile(id: "generic", kind: "Reusable launch profile", symbol: "command", tone: .working, isLaunchProfile: true,
                      name: "Generic MCP", executable: "~/bin/relay-agent", arguments: "--interactive",
                      mcpCommand: "agent-commander-mcp", connectionTest: "Tool list received · registration verified",
                      capabilities: clientCapabilities, delegationMode: "Cooperative",
                      delegationDetail: "Project instructions direct this client to delegate through Commander. This profile relies on the client to follow them.",
                      hint: "Incoming messages arrive on the next inbox read.")
    ]

    static let panes: [DiscoveredPane] = [
        DiscoveredPane(
            id: "p1", name: "Claude Code", provider: .claude, place: "Mac Studio · relay:0.1",
            identity: .verified,
            pane: "relay:0.1 · %12", conversation: "claude · …3d8a", hostDirectory: "Mac Studio · ~/Developer/relay",
            taskState: "Working · 1 open approval", joinMethod: "Live provider connection",
            checks: [
                PreservationCheck(id: "Conversation identity", detail: "Provider session matches this pane"),
                PreservationCheck(id: "Message history", detail: "Current thread is accessible"),
                PreservationCheck(id: "Pending approval", detail: "REQ-17 matched · response supported"),
                PreservationCheck(id: "In-flight work", detail: "Active turn remains attached")
            ]),
        DiscoveredPane(
            id: "p2", name: "Codex", provider: .codex,
            place: "build-01 · relay:1.0",
            identity: .needsVerification,
            pane: "relay:1.0 · %31", conversation: "codex · 2 candidates", hostDirectory: "build-01 · ~/src/relay",
            taskState: "Idle · no open approval", joinMethod: "Live provider connection after verification",
            checks: [
                PreservationCheck(id: "Conversation identity", detail: "Provider session matches this pane",
                                  pendingDetail: "Two conversations match this directory"),
                PreservationCheck(id: "Message history", detail: "Current thread is accessible",
                                  pendingDetail: "Available once the conversation is identified"),
                PreservationCheck(id: "Pending approval", detail: "No approval is waiting"),
                PreservationCheck(id: "In-flight work", detail: "No active turn")
            ],
            warningTitle: "Codex needs identity verification",
            warningDetail: "Two conversations match its directory. Messages and approvals are unavailable until you verify the session in its live pane."),
        DiscoveredPane(
            id: "p3", name: "Shell", place: "Mac Studio · tests:0.0", identity: .consoleOnly,
            note: "Conversation controls unsupported",
            pane: "tests:0.0 · %4", conversation: nil, hostDirectory: "Mac Studio · ~/Developer/relay",
            taskState: "Shell prompt", joinMethod: "Console view only", checks: [])
    ]

    static let recovery = RecoveryReport(
        kicker: "HOSTS / BUILD-01",
        summary: "14:36 · The SSH connection is back. One worker message still has an unknown delivery outcome.",
        events: [
            TimelineEvent(id: 1, time: "14:34:11", title: "SSH connection lost",
                          detail: "The persistent helper kept running on build-01.", tone: .attention),
            TimelineEvent(id: 2, time: "14:34:11", title: "Acknowledgment missing",
                          detail: "The connection closed after a worker message was accepted.", tone: .attention),
            TimelineEvent(id: 3, time: "14:36:32", title: "Host reconnected",
                          detail: "Live panes restored and recorded helper events reconciled.", tone: .working)
        ],
        workers: [
            AffectedWorker(id: "Retry telemetry", detail: "Codex", branch: "feat/telemetry", follow: .checkDelivery),
            AffectedWorker(id: "Failure paths", detail: "Claude Code", branch: "main", follow: .heldByYou)
        ],
        heldWorker: "Failure paths",
        gapNote: "Transcript gap · 14:34:11–14:36:32 on the Failure paths branch",
        recipient: "Retry telemetry", messageID: "msg-0186", accepted: "14:34:10",
        message: "Please include the attempt number in each retry event.",
        reconciled: "Last reconciled at 14:36:35")

    static let operation = OperationDetail(
        kicker: "Attention / OP-208",
        title: "Sign in on build-01",
        noticeTitle: "Provider sign-in requested",
        noticeDetail: "The client is waiting for its account sign-in. Open the named worker terminal to complete it.",
        facts: [
            OperationFact(id: "Run / worker", value: "Retry policy / Retry telemetry"),
            OperationFact(id: "Request", value: "OP-208 · W-044", monospaced: true),
            OperationFact(id: "Outcome", value: "requires_user_action", monospaced: true),
            OperationFact(id: "Host / checkout", value: "build-01 · feat/telemetry"),
            OperationFact(id: "Requested by", value: "Retry policy · owning coordinator"),
            OperationFact(id: "Continuation", value: "Check sign-in, then resume the existing assignment")
        ],
        history: [
            OperationEvent(id: 1, time: "14:42:01", text: "Worker requested access"),
            OperationEvent(id: 2, time: "14:42:02", text: "Sign-in prompt detected"),
            OperationEvent(id: 3, time: "14:42:02", text: "Request sent to cockpit")
        ],
        workerName: "Retry telemetry")
}
