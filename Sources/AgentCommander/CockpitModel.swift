import Foundation
import Observation

@Observable @MainActor
final class CockpitModel {
    enum Connection: Equatable { case connecting, online, offline(String) }

    private let api = ServiceClient()
    var runs: [Run] = []
    var selectedID = UserDefaults.standard.string(forKey: "selectedRun")
    var connection: Connection = .connecting
    var notice: String?
    var isStopping = false
    var sending: Set<String> = []
    private(set) var workerActions: Set<String> = []
    private var replyAttempts: [String: (text: String, id: String)] = [:]
    private var followUpAttempts: [String: (text: String, generation: Int, id: String)] = [:]
    private var receivedStreamState = false
    private var usingLegacyService = false

    var selected: Run? { runs.first { $0.id == selectedID } }

    var pending: [PendingDecision] {
        runs.flatMap { run in
            (run.requests ?? []).compactMap { request in
                guard request.status == "pending",
                      let worker = run.workers?.first(where: { $0.id == request.workerID })
                else { return nil }
                return PendingDecision(run: run, worker: worker, request: request)
            }
        }
    }

    func select(_ id: String?) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedRun")
    }

    func follow() async {
        await refresh(allowStart: true)
        while !Task.isCancelled {
            do {
                for try await latest in await api.watchRuns() {
                    guard !Task.isCancelled else { return }
                    receivedStreamState = true
                    usingLegacyService = false
                    apply(latest)
                }
            } catch AGUIStreamError.unsupported {
                usingLegacyService = true
                await refresh()
            } catch {
                guard !Task.isCancelled else { return }
                connection = .offline(error.localizedDescription)
            }
            do {
                try await Task.sleep(for: usingLegacyService ? .seconds(2) : .seconds(1))
            } catch {
                break
            }
        }
    }

    private func apply(_ latest: [Run]) {
        connection = .online
        if runs != latest { runs = latest }
        if selected == nil { select(runs.last?.id) }
    }

    func refresh(allowStart: Bool = false) async {
        do {
            let latest: [Run]
            do {
                latest = try await api.runs()
            } catch ServiceError.offline where allowStart {
                try await api.startService()
                latest = try await api.runs()
            }
            if !receivedStreamState || usingLegacyService {
                apply(latest)
            }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func create(path: String, task: String, title: String? = nil, operationID: String) async throws {
        let run = try await api.create(path: path, task: task, title: title, operationID: operationID)
        if !runs.contains(where: { $0.id == run.id }) { runs.append(run) }
        select(run.id)
        if usingLegacyService { await refresh() }
    }

    func reply(to item: PendingDecision, text: String) async -> Bool {
        guard !sending.contains(item.id) else { return false }
        // Read from the current runs, so a worker that dropped after the surface was drawn is caught.
        let worker = runs.lazy.compactMap { $0.workers?.first { $0.id == item.worker.id } }.first ?? item.worker
        guard worker.state.lowercased() != TaskState.apiDisconnected else {
            notice = "Reply to \(worker.name): the worker is disconnected. The request stays pending until it is reconciled."
            return false
        }
        let prior = replyAttempts[item.id]
        let key = prior?.text == text ? prior!.id : UUID().uuidString
        replyAttempts[item.id] = (text, key)
        sending.insert(item.id)
        defer { sending.remove(item.id) }
        do {
            try await api.reply(to: item.id, answer: text, operationID: key)
            replyAttempts.removeValue(forKey: item.id)
            if usingLegacyService { await refresh() }
            return true
        } catch {
            notice = "Reply to \(item.worker.name): \(error.localizedDescription)"
            if usingLegacyService { await refresh() }
            return false
        }
    }

    func stop(_ run: Run) async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        do { try await api.stop(runID: run.id) } catch { notice = error.localizedDescription }
        if usingLegacyService { await refresh() }
    }

    private func workerTarget(_ id: String) -> (Run, Worker)? {
        guard let run = runs.first(where: { $0.workers?.contains(where: { $0.id == id }) == true }),
              id != run.coordinatorID, let worker = run.workers?.first(where: { $0.id == id })
        else { return nil }
        return (run, worker)
    }

    func canControlWorker(_ id: String) -> Bool {
        guard let (run, worker) = workerTarget(id) else { return false }
        return run.status == "running" && worker.control != nil &&
            ["working", "waiting", "idle", "completed"].contains(worker.state)
    }

    func canInterruptWorker(_ id: String) -> Bool {
        guard canControlWorker(id), let (_, worker) = workerTarget(id) else { return false }
        return ["working", "waiting"].contains(worker.state) && worker.control?.interruptRequested != true
    }

    func canStopWorker(_ id: String) -> Bool {
        guard let (run, worker) = workerTarget(id), run.status == "running" || run.status == "failed" else { return false }
        return worker.state != "stopped" && (worker.state != "stopping" || worker.error != nil)
    }

    func takeControl(_ id: String) async { await setWorkerControl(id, held: true) }
    func handBack(_ id: String) async { await setWorkerControl(id, held: false) }

    private func setWorkerControl(_ id: String, held: Bool) async {
        guard canControlWorker(id), let generation = workerTarget(id)?.1.control?.generation else { return }
        _ = await performWorkerAction(id, label: held ? "Take control" : "Hand back input") {
            try await api.setWorkerControl(id, held: held, generation: generation)
        }
    }

    func sendFollowUp(to id: String, text: String) async -> Bool {
        guard canControlWorker(id), let control = workerTarget(id)?.1.control, control.held,
              !workerActions.contains(id) else { return false }
        let prior = followUpAttempts[id]
        let operationID = prior.flatMap { attempt in
            attempt.text == text && attempt.generation == control.generation ? attempt.id : nil
        } ?? UUID().uuidString
        followUpAttempts[id] = (text, control.generation, operationID)
        let accepted = await performWorkerAction(id, label: "Send follow-up") {
            try await api.sendFollowUp(to: id, text: text, generation: control.generation, operationID: operationID)
        }
        if accepted { followUpAttempts[id] = nil }
        return accepted
    }

    func interruptWorker(_ id: String) async {
        guard canInterruptWorker(id) else { return }
        _ = await performWorkerAction(id, label: "Interrupt worker") {
            try await api.interruptWorker(id)
        }
    }

    func stopWorker(_ id: String) async {
        guard canStopWorker(id) else { return }
        _ = await performWorkerAction(id, label: "Stop worker") {
            try await api.stopWorker(id)
        }
    }

    private func performWorkerAction(_ id: String, label: String, perform: () async throws -> Void) async -> Bool {
        guard connection == .online, workerActions.insert(id).inserted else { return false }
        defer { workerActions.remove(id) }
        do {
            try await perform()
            if usingLegacyService { await refresh() }
            return true
        } catch {
            notice = "\(label): \(error.localizedDescription)"
            return false
        }
    }
}
