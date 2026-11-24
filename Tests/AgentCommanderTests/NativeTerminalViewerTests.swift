import Foundation
import Testing
@testable import AgentCommander

@Suite @MainActor
struct NativeTerminalViewerTests {
    private let worker = NativeTerminalTarget(workerID: "w-backoff", workerName: "Backoff",
                                              host: "localhost", clientName: "Codex", isLocal: true)
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

    @Test func unavailableTargetsCannotStartByReconnecting() {
        let remote = NativeTerminalTarget(workerID: "w-remote", workerName: "Review",
                                          host: "build-01", clientName: "Claude", isLocal: false)
        for model in [NativeTerminalViewerModel(target: remote, agentctl: cli),
                      NativeTerminalViewerModel(target: worker, agentctl: nil)] {
            let phase = model.phase
            #expect(!phase.isObserving && !phase.canReconnect)
            model.reconnect()
            #expect(model.phase == phase)
        }
    }
}
