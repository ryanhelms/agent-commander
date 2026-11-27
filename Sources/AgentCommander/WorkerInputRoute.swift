import Foundation

// VALUE. Who answers a worker's pending input: its questions and its portable ACP approval
// choices. This is the one rule. `CockpitModel.pending`, `CockpitModel.reply`, the cockpit's
// projection (`RunContent`) and the input-request panel's scope all read it, so a request is
// never counted, shown as actionable or sent on one surface and withheld on another.
//
// A delegated worker's request stays with the coordinator or the worker that delegated it until
// the developer explicitly takes control of that worker. Handing back returns it at once: the
// request is not dropped, it only stops being the developer's to answer. A coordinator's own
// question, an escalation to the developer included, is always the developer's.

/// The owner of a delegated worker's input while the developer does not hold it.
struct WorkerInputOwner: Equatable, Sendable {
    /// The worker that delegated it, when that is not the coordinator. Nil for the coordinator.
    var parentName: String? = nil

    /// As a status word names it: "Waiting for coordinator", "Waiting for Failure paths".
    var word: String { parentName ?? "coordinator" }
    /// Inside a sentence: "waiting for the coordinator's answer".
    var phrase: String { parentName ?? "the coordinator" }
    var waitingLabel: String { "Waiting for \(word)" }
}

enum WorkerInputRoute: Equatable, Sendable {
    /// The developer answers. `generation` is the worker-control generation the reply is sent
    /// under, so the service refuses it once control has changed. Nil for a coordinator's own
    /// request and for a worker the service keeps no control record for; those replies carry none.
    case developer(generation: Int?)
    /// The coordinator or delegating parent answers. The developer observes.
    case owner

    var isDeveloper: Bool {
        if case .developer = self { return true }
        return false
    }

    /// The route of `worker`'s pending input in a run led by `coordinatorID`.
    static func of(_ worker: Worker, coordinatorID: String) -> WorkerInputRoute {
        // The coordinator is never taken over, and its questions are asked of the developer.
        if worker.id == coordinatorID { return .developer(generation: nil) }
        // No control record: the service models no input ownership for this worker (an older
        // service or a legacy runner), so nobody can take or hand back control. As before.
        guard let control = worker.control else { return .developer(generation: nil) }
        return control.held ? .developer(generation: control.generation) : .owner
    }
}

extension Run {
    /// The route of one worker's pending input, by the shared rule.
    func inputRoute(of worker: Worker) -> WorkerInputRoute {
        WorkerInputRoute.of(worker, coordinatorID: coordinatorID)
    }

    /// Who owns a delegated worker's input while the developer does not: the nearest parent that
    /// is itself a delegated worker, else the coordinator.
    func inputOwner(of worker: Worker) -> WorkerInputOwner {
        guard let parent = workers?.first(where: { $0.id == worker.parentID }), parent.id != coordinatorID,
              parent.id != worker.id else { return WorkerInputOwner() }
        return WorkerInputOwner(parentName: parent.name)
    }
}
