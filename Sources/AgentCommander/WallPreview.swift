import SwiftUI

// ATOMIC LEVEL: Sample values (coordinator wall, live work).
// The wall's live work for the design preview and the headless renders: two hand-offs on
// friends' Macs, a review and a fan-out that still need a look, a worker a friend holds, and a
// suggestion waiting. The worker IDs are the preview run's own (PreviewSamples.swift).

enum WallSample {
    static let studio = "srv-studio"
    /// The preview run's workers the samples attach to.
    static let heldWorker = "W-044", suggestedWorker = "W-045"

    static func work(now: Date = NetworkSample.now) -> WallLiveWork {
        var wall = WallLiveWork()
        wall.now = now
        wall.remoteWorkers = [
            MultiplayerRemoteWorker(server: studio, request: "ho-1", resource: "d-mira", canWatch: true,
                                    task: "Move the retry budget to each request", agent: "relay-builder", friend: "mira",
                                    serverName: "studio", harness: "claude", state: "Running", tone: .working,
                                    at: now.addingTimeInterval(-540)),
            MultiplayerRemoteWorker(server: studio, request: "ho-3", resource: "d-ines", canWatch: false,
                                    task: "Draft the migration note", agent: "docs-agent", friend: "ines",
                                    serverName: "studio", harness: "codex", state: "Done", tone: .working,
                                    at: now.addingTimeInterval(-4_200))
        ]
        wall.work = [
            MultiplayerRemoteWork(kind: .review, server: studio, request: "rv-1", title: "Lease renewal",
                                  detail: "relay-builder on studio", state: "2 important, 1 nit", tone: .attention,
                                  at: now.addingTimeInterval(-900)),
            MultiplayerRemoteWork(kind: .fanout, server: studio, request: "fo-1", title: "Name the retry knob",
                                  detail: "3 workers on studio", state: "2 of 3 answered", tone: .attention,
                                  at: now.addingTimeInterval(-1_500))
        ]
        wall.controls = [
            WallLiveWork.Control(server: studio, serverName: "studio",
                                 handover: MultiplayerHandover(handle: "mira", user: "u-mira",
                                                               resource: WallLiveWork.resourceID(forWorker: heldWorker),
                                                               until: now.addingTimeInterval(24 * 60 + 12), server: studio, minutes: 30),
                                 resourceName: "Retry telemetry")
        ]
        wall.suggestions = [
            WallLiveWork.Suggestion(server: studio, approval: "ap-9", resource: WallLiveWork.resourceID(forWorker: suggestedWorker),
                                    who: "jonah", text: "Check the streaming client too, it builds its own options.")
        ]
        return wall
    }

    /// What the zoom view of the first sample hand-off reads.
    static func watch(now: Date = NetworkSample.now) -> MultiplayerWatchState {
        var watch = MultiplayerWatchState(server: studio, resource: "d-mira")
        watch.take(MultiplayerWatchReply(events: [
            MultiplayerWatchEvent(at: now.addingTimeInterval(-96), kind: .status, text: "Run started in relay, branch handoff/retry-budget"),
            MultiplayerWatchEvent(at: now.addingTimeInterval(-80), kind: .message, text: "The budget lives on the client today. Moving it to the request so two calls don’t share it."),
            MultiplayerWatchEvent(at: now.addingTimeInterval(-61), kind: .tool, text: "edit retry/budget.go"),
            MultiplayerWatchEvent(at: now.addingTimeInterval(-44), kind: .tool, text: "edit retry/policy.go"),
            MultiplayerWatchEvent(at: now.addingTimeInterval(-20), kind: .tool, text: "make integration"),
            MultiplayerWatchEvent(at: now.addingTimeInterval(-4), kind: .message, text: "9 of 14 integration tests pass so far. The rest are still running.")
        ], cursor: "c-6", state: "running"), at: now)
        return watch
    }

    /// The zoom view of a sample remote worker, as the tray's organism draws it.
    @MainActor static func zoom(_ id: String, now: Date = NetworkSample.now) -> AnyView {
        guard let worker = work(now: now).remoteWorkers.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
        let entry = MultiplayerDirectoryEntry(id: worker.resource, name: worker.agent, kind: "agent", owner: worker.friend,
                                              offered: NetworkSample.agentActions, granted: [MultiplayerSharePolicy.watch],
                                              capabilities: NetworkSample.opus)
        return AnyView(RemoteWorkerZoom(worker: worker, watch: watch(now: now), entry: entry,
                                        color: MultiplayerTheme.swatch(for: worker.server), interval: 2, now: now,
                                        onRetry: {}, onOpenTray: {}))
    }
}
