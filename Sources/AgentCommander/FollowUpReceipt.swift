import SwiftUI

// FOLLOW-UP RECEIPT
// What happened to each follow-up the developer sent a managed local Claude worker. It reads only
// the service's durable `control.messages` list (`id`, `status`, optional `generation`), which the
// service keeps whole in acceptance order through a cockpit reconnect, and the worker's observed
// pending requests, `control.active_turn_id` and held generation. The legacy feed and the
// incremental projection decode the same `WorkerFollowUp`. The service is the authority: drawing a
// receipt never sends anything, and the message text is never read to identify one.
//
//   Values     FollowUpReceipt         one receipt by its stable ID. An unrecognized status is kept
//                                      as sent and stated honestly
//              FollowUpBlocker         what a queued follow-up waits for, from observed state only
//              FollowUpReceipts        the worker's receipts: the claimed and the queued receipt
//                                      shown together, any further open count, the retained
//                                      latest outcome, the queued receipt's blocker and the
//                                      generation-scoped hand-back consequence
//   Molecule   FollowUpReceiptStatus   the compact row in the focused worker's lower status area
//
// Queued means Commander accepted it. Processing means the worker's runner claimed it. That alone
// never establishes delivery to Claude. Every other known status is the service's outcome.

struct FollowUpReceipt: Equatable, Identifiable, Sendable {
    /// Contract values of `control.messages[].status`.
    enum Status: String, CaseIterable, Sendable {
        case queued, processing, completed, interrupted, cancelled, failed
        case deliveryUnknown = "delivery_unknown"
    }

    /// Where a receipt stands, as this version reads it.
    enum Stage: Equatable, Sendable {
        /// Queued or processing: the outcome is still to come.
        case awaiting
        /// A status the service reports as the follow-up's outcome.
        case outcome
        /// A status this version does not know. Neither in flight nor settled can be claimed.
        case unrecognized
    }

    enum Ink: Equatable, Sendable { case pending, confirmed, settled, failure, attention }

    let id: String
    /// The status exactly as sent.
    let statusValue: String
    /// The control generation it was accepted under. Nil from an older service.
    let generation: Int?

    init(id: String, status: String, generation: Int? = nil) {
        self.id = id
        statusValue = status
        self.generation = generation
    }

    init(_ followUp: WorkerFollowUp) {
        self.init(id: followUp.id, status: followUp.status, generation: followUp.generation)
    }

    var status: Status? { Status(rawValue: statusValue) }
    var shortID: String { Identifier.short(id) }

    var stage: Stage {
        switch status {
        case .queued, .processing: .awaiting
        case nil: .unrecognized
        default: .outcome
        }
    }

    /// Accepted by Commander and not yet claimed by the runner: the only state hand-back cancels.
    var isUnclaimed: Bool { status == .queued }

    /// The visible status phrase.
    var label: String {
        switch status {
        case .queued: "Accepted by Commander"
        case .processing: "Claimed by runner"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .deliveryUnknown: "Delivery unknown"
        case nil: "Reported \(statusValue)"
        }
    }

    var ink: Ink {
        switch status {
        case .queued, .processing: .pending
        case .completed: .confirmed
        case .interrupted, .cancelled: .settled
        case .failed: .failure
        case .deliveryUnknown, nil: .attention
        }
    }

    /// `◌` queued, `◐` claimed, `✓` completed, `○` settled, `!` failed, `?` unknown.
    var mark: String {
        switch status {
        case .queued: "◌"
        case .processing: "◐"
        case .completed: "✓"
        case .interrupted, .cancelled: "○"
        case .failed: "!"
        case .deliveryUnknown, nil: "?"
        }
    }
}

/// What a queued follow-up is waiting for, from what the cockpit observes now.
enum FollowUpBlocker: Equatable {
    /// This worker's pending approval: an addressed request with explicit choices, by its exact ID.
    /// A free-form question is never an approval.
    case request(RequestPresentation)
    /// The worker's current turn, by the service's `active_turn_id`.
    case turn(String)
    /// The service gives no evidence of what holds it.
    case unreported

    /// The first addressable pending approval of this worker, in the service's order: a request with
    /// explicit choices. A free-form question neither counts nor hides a later approval. Otherwise
    /// its active turn when the service reports one, otherwise nothing is claimed.
    static func observed(workerID: String, requests: [RequestPresentation], activeTurnID: String?) -> FollowUpBlocker {
        if let request = requests.first(where: {
            $0.workerID == workerID && !$0.id.isEmpty && !$0.choices.isEmpty
        }) {
            return .request(request)
        }
        if let turn = activeTurnID, !turn.isEmpty { return .turn(turn) }
        return .unreported
    }

    /// The request to open in Attention, by ID. Nil unless the blocker is a request.
    var request: RequestPresentation? {
        if case .request(let request) = self { return request }
        return nil
    }
}

/// Every follow-up receipt of one worker, and what its focused view says about them.
struct FollowUpReceipts: Equatable {
    let workerName: String
    /// The service's list, in acceptance order.
    let receipts: [FollowUpReceipt]
    /// What the queued receipt waits for.
    let blocker: FollowUpBlocker
    /// The control generation the developer holds now. Nil while control is not held.
    let heldGeneration: Int?

    init(workerName: String, receipts: [FollowUpReceipt], blocker: FollowUpBlocker, heldGeneration: Int?) {
        self.workerName = workerName
        self.receipts = receipts
        self.blocker = blocker
        self.heldGeneration = heldGeneration
    }

    /// The receipts of one worker's observed control, or nil when the service lists none.
    init?(control: WorkerControl?, workerID: String, workerName: String, requests: [RequestPresentation]) {
        guard let control, let messages = control.messages, !messages.isEmpty else { return nil }
        self.init(workerName: workerName, receipts: messages.map(FollowUpReceipt.init),
                  blocker: .observed(workerID: workerID, requests: requests, activeTurnID: control.activeTurnID),
                  heldGeneration: control.held ? control.generation : nil)
    }

    /// Receipts without a known outcome: those awaiting one in acceptance order, then those with a
    /// status this version does not recognize.
    var open: [FollowUpReceipt] {
        receipts.filter { $0.stage == .awaiting } + receipts.filter { $0.stage == .unrecognized }
    }

    /// The earliest receipt the runner has claimed.
    var claimed: FollowUpReceipt? { receipts.first { $0.status == .processing } }

    /// The earliest receipt Commander holds in the queue.
    var queued: FollowUpReceipt? { receipts.first { $0.status == .queued } }

    /// The normal in-flight receipts, each on its own line: the claimed one, then the queued one.
    /// Commander allows one of each at a time.
    var inFlight: [FollowUpReceipt] { [claimed, queued].compactMap { $0 } }

    /// The open receipts with their own line: both in flight, otherwise the first open one.
    var shownOpen: [FollowUpReceipt] { inFlight.isEmpty ? Array(open.prefix(1)) : inFlight }

    /// The receipt the row leads with.
    var lead: FollowUpReceipt? { shownOpen.first }

    /// Open receipts without their own line, counted beside them. Empty in the normal case. It keeps
    /// an unrecognized status, or more than Commander normally holds, stated.
    var further: [FollowUpReceipt] {
        let shown = shownOpen
        return open.filter { !shown.contains($0) }
    }

    /// The most recently accepted follow-up with an outcome, kept after the queue drains.
    var retainedOutcome: FollowUpReceipt? { receipts.last { $0.stage == .outcome } }

    /// The row has something to show.
    var isShown: Bool { lead != nil || retainedOutcome != nil }

    /// What the queued receipt waits for, kept while an earlier receipt runs. Nil without one.
    var queuedBlocker: FollowUpBlocker? { queued == nil ? nil : blocker }

    /// The pending approval to open from the row, by its exact ID. Nil unless the queued receipt waits on it.
    var blockingRequest: RequestPresentation? { queuedBlocker?.request }

    /// Queued follow-ups accepted under the generation the developer holds now, which handing back
    /// cancels. A claimed receipt, or one from another generation or an older service that sends no
    /// generation, is never counted.
    var handBackCancels: [FollowUpReceipt] {
        guard let heldGeneration else { return [] }
        return receipts.filter { $0.isUnclaimed && $0.generation == heldGeneration }
    }

    /// The short consequence beside Hand back. Nil when handing back cancels nothing.
    var handBackNote: String? {
        let count = handBackCancels.count
        guard count > 0 else { return nil }
        return count == 1 ? "cancels 1 queued follow-up" : "cancels \(count) queued follow-ups"
    }

    /// The full consequence, for the help tag and accessibility hint.
    var handBackStatement: String? {
        let cancelled = handBackCancels
        guard !cancelled.isEmpty else { return nil }
        let ids = cancelled.map(\.id).joined(separator: ", ")
        let subject = cancelled.count == 1 ? "follow-up \(ids), which the runner has not claimed"
            : "follow-ups \(ids), which the runner has not claimed"
        return "Handing back control of \(workerName) cancels \(subject). A claimed follow-up keeps its receipt."
    }

    // MARK: Words

    /// The compact phrase for what the queued receipt waits for.
    var blockerLabel: String? {
        switch queuedBlocker {
        case .request(let request): "waits for approval \(request.shortID)"
        case .turn(let turn): "waits for turn \(Identifier.turn(turn))"
        case .unreported: "waiting"
        case nil: nil
        }
    }

    private func blockerSentence(_ blocker: FollowUpBlocker) -> String {
        switch blocker {
        case .request(let request):
            "It waits for pending approval \(request.id) from \(workerName)."
        case .turn(let turn):
            "It waits for \(workerName)'s current turn \(turn) to end."
        case .unreported:
            "Commander is waiting for the runner to claim it."
        }
    }

    /// The full statement of one receipt, for its help tag and accessible value.
    func statement(for receipt: FollowUpReceipt) -> String {
        var parts = ["Follow-up \(receipt.id) to \(workerName)."]
        switch receipt.status {
        case .queued:
            parts.append("Commander accepted it and holds it in the queue.")
            if receipt == queued, let queuedBlocker { parts.append(blockerSentence(queuedBlocker)) }
        case .processing:
            parts.append("The worker's runner claimed it. Delivery to Claude stays unconfirmed until the service reports an outcome.")
        case .completed: parts.append("The service reports it completed.")
        case .interrupted: parts.append("The service reports its turn interrupted.")
        case .cancelled: parts.append("The service reports it cancelled.")
        case .failed: parts.append("The service reports it failed.")
        case .deliveryUnknown: parts.append("The service could not confirm whether Claude received it.")
        case nil:
            parts.append("The service reported the status \"\(receipt.statusValue)\", which this version does not recognize.")
        }
        return parts.joined(separator: " ")
    }

    /// A short clause for the tile's accessibility summary.
    var summary: String {
        var parts: [String] = []
        for receipt in shownOpen {
            var clause = "follow-up \(receipt.shortID) \(receipt.label.lowercased())"
            if receipt == queued, let blockerLabel { clause += ", \(blockerLabel)" }
            parts.append(clause)
        }
        if !further.isEmpty { parts.append("\(further.count) more follow-ups open") }
        if let retainedOutcome {
            parts.append("follow-up \(retainedOutcome.shortID) \(retainedOutcome.label.lowercased())")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Molecule

/// The follow-up row of the focused worker, in its own row of the lower status area directly above
/// the status line. It replaces the footer's generic `N follow-ups queued` cue.
///
///   `◐ Follow-up 9d0e1f2a · Claimed by runner                                 ✓ Follow-up 1b2c3d4e · Completed`
///   `◌ Follow-up 3f9a2c1d · Accepted by Commander · waits for [ approval 7c21e0aa ]`
///
/// The claimed and the queued receipt each keep a line, and the queued line keeps its own blocker
/// while the earlier receipt runs. The retained outcome sits beside the first line where it fits,
/// otherwise below. `[ approval … ]` opens that exact request through the cockpit's
/// request-ID routing. Nothing here sends to the worker.
struct FollowUpReceiptStatus: View {
    let receipts: FollowUpReceipts
    var size: CGFloat = 11
    /// Opens the blocking approval by its ID. Present only when the queued receipt waits on one.
    var openBlocker: (() -> Void)? = nil

    var body: some View {
        let gap = size * 0.9
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: gap * 1.6) {
                openLines
                retained
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                openLines
                retained
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(receipts.shownOpen) { receipt in
                    identity(receipt)
                    if receipt == receipts.queued { blockerSegment }
                }
                furtherSegment
                retained
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Term.font(size))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// One line per shown open receipt. The queued line carries its blocker, the last the further count.
    @ViewBuilder private var openLines: some View {
        let shown = receipts.shownOpen
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(shown) { receipt in
                    HStack(alignment: .firstTextBaseline, spacing: size * 0.9) {
                        identity(receipt)
                        if receipt == receipts.queued { blockerSegment }
                        if receipt == shown.last { furtherSegment }
                    }
                    .fixedSize()
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var retained: some View {
        if let outcome = receipts.retainedOutcome { identity(outcome) }
    }

    private func color(_ ink: FollowUpReceipt.Ink) -> Color {
        switch ink {
        case .pending: Term.cyan
        case .confirmed: Term.green
        case .settled: Term.text
        case .failure: Term.red
        case .attention: Term.amber
        }
    }

    /// The mark, `Follow-up`, its short ID and its status. Carries the full statement.
    private func identity(_ receipt: FollowUpReceipt) -> some View {
        let statement = receipts.statement(for: receipt)
        return HStack(spacing: size * 0.45) {
            Text(receipt.mark).foregroundStyle(color(receipt.ink))
            Text("Follow-up").foregroundStyle(Term.text)
            Text(receipt.shortID).foregroundStyle(.inkTermDim).textSelection(.enabled)
            Text("·").foregroundStyle(.inkTermDim)
            Text(receipt.label).foregroundStyle(color(receipt.ink))
        }
        .fixedSize()
        .id(receipt.id)
        .help(statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Follow-up \(receipt.id) to \(receipts.workerName)")
        .accessibilityValue(statement)
    }

    /// What the queued receipt waits for. The pending approval is a button to that exact request.
    @ViewBuilder private var blockerSegment: some View {
        switch receipts.queuedBlocker {
        case .request(let request):
            HStack(spacing: size * 0.45) {
                Text("waits for").foregroundStyle(.inkTermDim).accessibilityHidden(true)
                if let openBlocker {
                    Button("approval \(request.shortID)", action: openBlocker)
                        .buttonStyle(TermButtonStyle(ink: Term.amber, size: size))
                        .help("Show pending approval \(request.id) from \(receipts.workerName).")
                        .accessibilityLabel("Show pending approval \(request.id) from \(receipts.workerName)")
                } else {
                    Text("approval \(request.shortID)").foregroundStyle(Term.amber)
                        .help("Pending approval \(request.id) from \(receipts.workerName).")
                        .accessibilityLabel("Pending approval \(request.id) from \(receipts.workerName)")
                }
            }
            .fixedSize()
        case .turn, .unreported:
            if let label = receipts.blockerLabel {
                Text(label).foregroundStyle(.inkTermDim).fixedSize().accessibilityHidden(true)
            }
        case nil:
            EmptyView()
        }
    }

    /// The count of further open receipts, each named in the help tag by its ID and status.
    @ViewBuilder private var furtherSegment: some View {
        let further = receipts.further
        if !further.isEmpty {
            let detail = further.map { "\($0.id) \($0.label.lowercased())" }.joined(separator: ", ")
            Text("+\(further.count) open").foregroundStyle(Term.cyan)
                .fixedSize()
                .help("Further follow-ups to \(receipts.workerName), in acceptance order. \(detail).")
                .accessibilityLabel("\(further.count) more open follow-ups")
                .accessibilityValue(detail)
        }
    }
}
