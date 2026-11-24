import Foundation
import Testing
@testable import AgentCommander

@Suite @MainActor
struct NativeTerminalViewerTests {
    private let worker = NativeTerminalTarget(workerID: "w-backoff", workerName: "Backoff",
                                              host: "localhost", clientName: "Codex", hostKind: .localMac)
    private let sshWorker = NativeTerminalTarget(workerID: "w-remote", workerName: "Review",
                                                 host: "build-01", clientName: "Claude", hostKind: .remoteLinux)
    private let cli = URL(fileURLWithPath: "/tmp/agentctl")

    @Test func staleExitCannotDisconnectReattachedWorker() {
        let model = NativeTerminalViewerModel(target: worker, agentctl: cli)
        #expect(model.launch?.arguments == ["terminal", "observe", worker.workerID])
        let original = model.generation
        model.detach()
        model.processEnded(generation: original, exitCode: 1)
        #expect(model.phase == .detached)
        model.reconnect()
        model.processEnded(generation: original, exitCode: 1)
        #expect(model.phase.isObserving)
        model.processEnded(generation: model.generation, exitCode: 1)
        #expect(model.phase == .ended(exitCode: 1))
    }

    /// Managed SSH workers attach through the local tmux runner. The platform is only a label.
    @Test func sshWorkerCanOpenStandaloneViewer() {
        let model = NativeTerminalViewerModel(target: sshWorker, agentctl: cli)
        #expect(model.phase.isObserving)
        #expect(model.launch?.arguments == ["terminal", "observe", sshWorker.workerID])
        #expect(sshWorker.platform == .remoteLinux)
    }

    @Test func buildWithoutAgentctlCannotStartByReconnecting() {
        let model = NativeTerminalViewerModel(target: worker, agentctl: nil)
        let phase = model.phase
        #expect(!phase.isObserving && !phase.canReconnect)
        model.reconnect()
        #expect(model.phase == phase)
    }

    @Test func inlineEligibilityIgnoresHostAndRequiresLiveWorker() {
        let ledger = NativeTerminalLedger(source: .live(cli))
        #expect(ledger.shouldAttach(worker))
        #expect(ledger.shouldAttach(sshWorker))
        var stopped = worker
        stopped.isLive = false
        #expect(!ledger.shouldAttach(stopped))
        #expect(!TaskState.starting.allowsLiveTerminal)
        #expect(TaskState.needsInput.allowsLiveTerminal)
        #expect(!TaskState.disconnected.allowsLiveTerminal)
        let none = NativeTerminalLedger(source: .unavailable("no agentctl"))
        #expect(!none.shouldAttach(worker))
    }

    /// A failed attachment keeps every console on the transcript until an explicit retry, and an
    /// exit from an earlier generation cannot block the new one.
    @Test func failureIsStickyUntilRetryWithoutRetryStorm() {
        let ledger = NativeTerminalLedger(source: .live(cli))
        let first = ledger.generation(for: worker.workerID)
        ledger.attachmentEnded(worker.workerID, generation: first, exitCode: 1, message: "service unavailable")
        #expect(!ledger.shouldAttach(worker))
        #expect(ledger.block(for: worker.workerID) == .ended(exitCode: 1, message: "service unavailable"))
        // A second viewport of the same generation reporting later changes nothing.
        ledger.attachmentEnded(worker.workerID, generation: first, exitCode: 2, message: nil)
        #expect(ledger.block(for: worker.workerID) == .ended(exitCode: 1, message: "service unavailable"))
        ledger.reconnect(worker.workerID)
        #expect(ledger.shouldAttach(worker))
        #expect(ledger.generation(for: worker.workerID) == first + 1)
        ledger.attachmentEnded(worker.workerID, generation: first, exitCode: 1, message: nil)
        #expect(ledger.shouldAttach(worker))
        // Other workers are unaffected.
        #expect(ledger.shouldAttach(sshWorker))
    }

    @Test func detachIsStickyAndReconnectGivesNewIdentity() {
        let ledger = NativeTerminalLedger(source: .live(cli))
        ledger.detach(worker.workerID)
        #expect(ledger.block(for: worker.workerID) == .detached)
        #expect(!ledger.shouldAttach(worker))
        ledger.reconnect(worker.workerID)
        #expect(ledger.shouldAttach(worker))
        #expect(ledger.generation(for: worker.workerID) == 1)
    }

    @Test func fixtureFeedStartsNoProcess() {
        let ledger = NativeTerminalLedger(source: .fixture)
        guard case .fixture(let text) = ledger.feed(for: worker) else {
            Issue.record("expected a fixture feed")
            return
        }
        #expect(text.contains("fixture"))
        #expect(NativeTerminalLedger(source: .unavailable("x")).feed(for: worker) == nil)
    }

    @Test func prettyIsTheDefaultModeAndOverridesStillApply() {
        let modes = ConsoleModeStore()
        #expect(modes.globalMode == .pretty)
        modes.setMode(.terminal, for: worker.workerID)
        #expect(modes.mode(for: worker.workerID) == .terminal)
        #expect(modes.mode(for: sshWorker.workerID) == .pretty)
        modes.applyGlobal(.console)
        #expect(modes.mode(for: worker.workerID) == .console)
    }

    /// The window value is the worker: a changed live state still opens the same window.
    @Test func targetIdentityIsTheWorker() {
        var changed = worker
        changed.isLive = false
        #expect(changed == worker)
        #expect(Set([changed, worker]).count == 1)
    }

    @Test func socketAliasReachesAgentctl() {
        let env = NativeTerminalLaunch.environment(from: ["AC_SOCKET": "/tmp/s.sock", "TMUX": "x"])
        #expect(env.contains("AGENT_COMMANDER_SOCKET=/tmp/s.sock"))
        #expect(!env.contains { $0.hasPrefix("TMUX=") })
    }
}
