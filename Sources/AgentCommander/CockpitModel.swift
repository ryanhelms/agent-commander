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
    private var replyAttempts: [String: (text: String, id: String)] = [:]

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
            do { try await Task.sleep(for: .seconds(1.2)) } catch { break }
            await refresh()
        }
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
            connection = .online
            if runs != latest { runs = latest }
            if selected == nil { select(runs.last?.id) }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func create(path: String, task: String, title: String? = nil, operationID: String) async throws {
        let run = try await api.create(path: path, task: task, title: title, operationID: operationID)
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        select(run.id)
        await refresh()
    }

    func reply(to item: PendingDecision, text: String) async -> Bool {
        guard !sending.contains(item.id) else { return false }
        let prior = replyAttempts[item.id]
        let key = prior?.text == text ? prior!.id : UUID().uuidString
        replyAttempts[item.id] = (text, key)
        sending.insert(item.id)
        defer { sending.remove(item.id) }
        do {
            try await api.reply(to: item.id, answer: text, operationID: key)
            replyAttempts.removeValue(forKey: item.id)
            await refresh()
            return true
        } catch {
            notice = "Reply to \(item.worker.name): \(error.localizedDescription)"
            await refresh()
            return false
        }
    }

    func stop(_ run: Run) async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        do { try await api.stop(runID: run.id) } catch { notice = error.localizedDescription }
        await refresh()
    }
}
