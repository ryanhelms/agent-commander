import SwiftUI

// INTERRUPT RECEIPT
// What happened to the developer's interrupt of a bound local Claude worker's turn. It reads only
// the service's optional `control.interrupt` receipt (`id`, `turn_id`, `generation`, `phase`, optional
// `outcome`) and `control.active_turn_id`, the same in the legacy feed and the incremental projection.
// The service is the authority: drawing a receipt never sends anything, and the receipt stays
// visible after its outcome and through a cockpit reconnect, addressed to its original turn.
//
//   Values     WorkerInterruptReceipt      the decoded receipt. An unrecognized phase or outcome is
//                                          kept as sent and stated honestly
//              WorkerInterruptTarget       the optional `turn_id` and `generation` the interrupt POST
//                                          binds to, from the same observed control as the action
//              InterruptReceiptStatement   the words, ink and inspection policy a surface shows
//   Molecule   InterruptReceiptStatus      the compact row in the worker's lower status area, shared
//                                          by the focused worker (always) and the wall tile (while
//                                          the outcome is unresolved or unknown)
//
// Older services send only `control.interrupt_requested`, which keeps its existing cue and gate.

struct WorkerInterruptReceipt: Decodable, Equatable, Sendable {
    /// The last step the service confirmed. Contract values.
    enum Phase: String, CaseIterable, Sendable {
        case accepted, claimed, sent, unconfirmed
    }

    /// How the original turn ended. Absent while unresolved. Contract values.
    enum Outcome: String, CaseIterable, Sendable {
        case interrupted, completed, failed, unknown, cancelled
    }

    let id: String
    let turnID: String
    let generation: Int
    /// The phase exactly as sent, so a value this version does not know is still shown.
    let phaseValue: String
    /// The outcome exactly as sent. Nil while the turn's end is unresolved.
    let outcomeValue: String?

    var phase: Phase? { Phase(rawValue: phaseValue) }
    var outcome: Outcome? { outcomeValue.flatMap(Outcome.init(rawValue:)) }
    /// No outcome yet: the turn's end has not been observed.
    var isUnresolved: Bool { outcomeValue == nil }

    init(id: String, turnID: String, generation: Int, phase: String, outcome: String? = nil) {
        self.id = id
        self.turnID = turnID
        self.generation = generation
        phaseValue = phase
        outcomeValue = outcome
    }

    init(projection value: AGUIValue) throws {
        guard case .object(let fields) = value else { throw AGUIValueError("An interrupt receipt is not an object") }
        guard let generation = try fields.optionalInt("generation") else {
            throw AGUIValueError("An interrupt receipt has no generation")
        }
        self.init(id: try fields.string("id"), turnID: try fields.string("turn_id"), generation: generation,
                  phase: try fields.string("phase"), outcome: try fields.optionalString("outcome"))
    }

    init(from decoder: Decoder) throws { try self.init(projection: AGUIValue(from: decoder)) }
}

/// The turn and control generation an interrupt is addressed to. Present only when the service
/// reports a nonempty `active_turn_id`. Every other worker keeps the original empty request body.
struct WorkerInterruptTarget: Encodable, Equatable, Sendable {
    let turnID: String
    let generation: Int

    init(turnID: String, generation: Int) {
        self.turnID = turnID
        self.generation = generation
    }

    /// The target in one observed control record, or nil for an older service or provider.
    init?(control: WorkerControl?) {
        guard let control, let turn = control.activeTurnID, !turn.isEmpty else { return nil }
        self.init(turnID: turn, generation: control.generation)
    }

    private enum CodingKeys: String, CodingKey {
        case turnID = "turn_id", generation
    }
}

extension WorkerControl {
    /// An interrupt of the turn the worker is in now has been receipted and its end is unresolved.
    /// Asking again would only return the same receipt, so the action waits like
    /// `interrupt_requested`.
    var interruptPendsOnActiveTurn: Bool {
        guard let receipt = interrupt, receipt.isUnresolved, let turn = activeTurnID, !turn.isEmpty else { return false }
        return receipt.turnID == turn
    }
}

/// What a surface says about one receipt.
struct InterruptReceiptStatement: Equatable {
    enum Ink: Equatable { case confirmed, settled, failure, attention }

    let receipt: WorkerInterruptReceipt
    let workerName: String
    /// The worker's current turn, as the service reports it. Nil when none is open or unreported.
    let activeTurnID: String?

    var shortTurn: String { Identifier.turn(receipt.turnID) }
    var shortReceipt: String { Identifier.short(receipt.id) }

    /// A later turn is open now. The receipt applies to its original turn only.
    var originalTurnHasPassed: Bool {
        guard let activeTurnID, !activeTurnID.isEmpty else { return false }
        return activeTurnID != receipt.turnID
    }

    /// The outcome is unresolved, unknown or unrecognized: the developer may read the source.
    var needsInspection: Bool { receipt.outcome == nil || receipt.outcome == .unknown }

    /// The wall shows the receipt only while it needs inspection. The focused worker always does.
    func isShown(focused: Bool) -> Bool { focused || needsInspection }

    /// Whether a tile's interrupt row offers `Inspect source`. One affordance per tile: the
    /// availability strip offers it whenever present, so the interrupt row then does not, and the
    /// progress row defers to whichever of the two does.
    static func rowOffersSource(_ receipt: InterruptReceiptStatement?, focused: Bool, hasSource: Bool,
                                availability: ProviderAvailability?) -> Bool {
        guard hasSource, availability == nil, let receipt, receipt.isShown(focused: focused) else { return false }
        return receipt.needsInspection
    }

    /// The visible last confirmed step.
    var stepLabel: String {
        switch receipt.phase {
        case .accepted: "accepted by service"
        case .claimed: "claimed by runner"
        case .sent: "cancel sent to adapter"
        case .unconfirmed: "send unconfirmed"
        case nil: "reported \(receipt.phaseValue)"
        }
    }

    /// The visible outcome.
    var outcomeLabel: String {
        guard let value = receipt.outcomeValue else { return "unresolved" }
        switch receipt.outcome {
        case .interrupted: return "turn interrupted"
        case .completed: return "turn completed"
        case .failed: return "turn failed"
        case .unknown: return "unknown"
        case .cancelled: return "interrupt cancelled"
        case nil: return "reported \(value)"
        }
    }

    /// The outcome as the row shows it after `Interrupt outcome ·`, e.g. `Turn completed`. The ink
    /// and the full statement keep the distinction from an interrupted turn.
    var outcomeTitle: String { outcomeLabel.prefix(1).uppercased() + outcomeLabel.dropFirst() }

    /// `✓` confirmed, `○` settled, `!` failed, `?` unresolved or unknown.
    var mark: String {
        switch ink {
        case .confirmed: "✓"
        case .settled: "○"
        case .failure: "!"
        case .attention: "?"
        }
    }

    var ink: Ink {
        if needsInspection { return .attention }
        switch receipt.outcome {
        case .interrupted: return .confirmed
        case .failed: return .failure
        default: return .settled
        }
    }

    private var stepSentence: String {
        switch receipt.phase {
        case .accepted: "the service accepted the request"
        case .claimed: "the worker's runner claimed it"
        case .sent: "the cancel notification was sent to Claude's adapter"
        case .unconfirmed: "the service could not confirm that the cancel notification was sent"
        case nil: "the service reported \"\(receipt.phaseValue)\""
        }
    }

    private var outcomeSentence: String {
        guard let value = receipt.outcomeValue else { return "The turn's end has not been observed yet." }
        switch receipt.outcome {
        case .interrupted: return "Claude ended the turn as interrupted."
        case .completed: return "The turn completed."
        case .failed: return "The turn ended with a failure."
        case .unknown: return "The service could not determine how the turn ended."
        case .cancelled: return "The service cancelled this interrupt request."
        case nil: return "The service reported an outcome this version does not recognize: \"\(value)\"."
        }
    }

    /// The full statement, for the help tag and the accessible value.
    var statement: String {
        var parts = ["Interrupt \(receipt.id) of \(workerName)'s turn \(receipt.turnID).",
                     "At the last confirmed step, \(stepSentence).", outcomeSentence]
        if originalTurnHasPassed { parts.append("A later turn is open now. This receipt applies to the original turn only.") }
        if needsInspection {
            parts.append("Inspect source reads what Claude reported. Stopping the worker is a separate action.")
        }
        return parts.joined(separator: " ")
    }

    /// A short clause for the tile's accessibility summary.
    var summary: String { "interrupt of turn \(shortTurn) · \(stepLabel), \(outcomeLabel)" }
}

// MARK: - Molecule

/// The interrupt row of a worker with a receipt, in its own row of the lower status area beside the
/// Claude progress row. It replaces the status line's generic `interrupt requested` cue.
///
///   `? Interrupt · turn 4a1f2c3d  Last step cancel sent to adapter  Interrupt outcome · Unresolved  [ Inspect source ]`
///   `✓ Interrupt · turn 4a1f2c3d  Last step cancel sent to adapter  Interrupt outcome · Turn interrupted`
///   `○ Interrupt · turn 4a1f2c3d  Last step cancel sent to adapter  Interrupt outcome · Turn completed`
///
/// on one row where it fits, otherwise the identity, the step, then the outcome and the action on
/// their own lines. `[ Inspect source ]` is the existing read-only source route, offered only while
/// the outcome is unresolved or unknown and only when no other row of the tile already offers it.
/// Nothing here sends to the worker, and stopping it stays in the action list.
struct InterruptReceiptStatus: View {
    let statement: InterruptReceiptStatement
    var size: CGFloat = 11
    /// Opens this worker's read-only source inspector. Offered only while inspection is useful.
    var inspectSource: (() -> Void)? = nil

    private var inspect: (() -> Void)? { statement.needsInspection ? inspectSource : nil }

    var body: some View {
        let gap = size * 0.9
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: gap) {
                identity
                step
                outcome
                inspectButton
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                identity
                step
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: gap) { outcome; inspectButton }.fixedSize()
                    VStack(alignment: .leading, spacing: 3) { outcome; inspectButton }.fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Term.font(size))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    private var inkColor: Color {
        switch statement.ink {
        case .confirmed: Term.green
        case .settled: Term.text
        case .failure: Term.red
        case .attention: Term.amber
        }
    }

    /// The mark, `Interrupt` and the original turn. Carries the full statement.
    private var identity: some View {
        HStack(spacing: size * 0.45) {
            Text(statement.mark).foregroundStyle(inkColor)
            Text("Interrupt").foregroundStyle(Term.text)
            Text("·").foregroundStyle(.inkTermDim)
            Text("turn \(statement.shortTurn)").foregroundStyle(.inkTermDim).textSelection(.enabled)
        }
        .fixedSize()
        .help(statement.statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Interrupt of turn \(statement.receipt.turnID), \(statement.workerName)")
        .accessibilityValue(statement.statement)
    }

    private var step: some View {
        HStack(spacing: size * 0.45) {
            Text("Last step").foregroundStyle(.inkTermDim)
            Text(statement.stepLabel).foregroundStyle(Term.text)
        }
        .fixedSize()
        .help(statement.statement)
        .accessibilityHidden(true)
    }

    private var outcome: some View {
        HStack(spacing: size * 0.45) {
            Text("Interrupt outcome").foregroundStyle(.inkTermDim)
            Text("·").foregroundStyle(.inkTermDim)
            Text(statement.outcomeTitle).foregroundStyle(inkColor)
        }
        .fixedSize()
        .help(statement.statement)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var inspectButton: some View {
        if let inspect {
            Button("Inspect source", action: inspect)
                .buttonStyle(TermButtonStyle(ink: Term.text, size: size))
                .fixedSize()
                .help("Open the read-only source inspector for \(statement.workerName).")
                .accessibilityLabel("Inspect source of \(statement.workerName)")
        }
    }
}
