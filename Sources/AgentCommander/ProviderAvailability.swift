import SwiftUI

// PROVIDER AVAILABILITY
// Whether a deliberately bound local Claude ACP delegate's adapter can still be reached. It reads
// only the service's optional `provider_availability` member of the worker, the same in the legacy
// feed and the incremental AG-UI projection (both build `Worker.allFields`). The service publishes
// `available` when a checked worker recovers; that, like an absent, null or unknown value, is the
// normal state: nothing is drawn and no gate changes.
//
//   Value      ProviderAvailability          `exited` or `checking`, and the one control gate for both
//              ProviderAvailabilityStatement the words a surface shows, and whether the console's
//                                            own error notice would only repeat them
//   Molecule   ProviderAvailabilityNotice    the compact strip in the worker's lower status area,
//                                            shared by the wall tile and the focused worker
//              ReservedInputCue              the status line's ownership cue while checking with
//                                            the developer's lease held
//
// Availability is independent of the task state. An exited worker keeps its Completed or Idle
// state; a checking worker may read Unknown. Neither is a stall, failure or stop decision.

enum ProviderAvailability: String, CaseIterable, Sendable {
    /// The adapter's observation stream ended between turns, after an authoritative completed or
    /// interrupted turn. Once the exit is confirmed the service releases the lease and rejects
    /// every control change. The transcript and source stay readable; nothing new can be sent.
    case exited
    /// The service restarted and waits for evidence from the original worker of the same
    /// authenticated session and turn. Control waits until the service reports `available`.
    case checking

    /// The service's member name on the worker. A contract value.
    static let fieldName = "provider_availability"
    /// The service's value for a worker that is reachable again, e.g. after checking succeeds. A
    /// contract value, read as the normal state.
    static let availableValue = "available"

    /// The availability in a worker's fields. Nil for `available` and when the member is absent,
    /// null, not a string or an unknown value: the worker behaves as before.
    static func reported(fields: AGUIValue) -> ProviderAvailability? {
        guard let value = fields[fieldName]?.stringValue, value != availableValue else { return nil }
        return ProviderAvailability(rawValue: value)
    }

    init?(worker: Worker) {
        guard let reported = Self.reported(fields: worker.allFields) else { return nil }
        self = reported
    }

    // MARK: Control gate
    // One policy for the feature model's domain gates and the cockpit's presentation gates, so a
    // surface never offers what the model would refuse.

    /// Taking control, handing it back, interrupting a turn and sending a follow-up. Only a normal
    /// worker: the service rejects every control change while exited or checking. Stopping and the
    /// passive source routes are not control and are unaffected.
    static func allowsControl(_ availability: ProviderAvailability?) -> Bool { availability == nil }
}

/// What a surface says about a worker's availability, from the availability, the worker's name and
/// the service's `error` explanation.
struct ProviderAvailabilityStatement: Equatable {
    /// Used while checking when the service sent no explanation of its own. The service's own
    /// checking reason, so the notice reads the same either way.
    static let defaultRestartReason = "Service restarted. Waiting for evidence from the original worker."

    let availability: ProviderAvailability
    /// The service's explanation, trimmed. Nil when it sent none.
    let serviceError: String?
    let workerName: String

    init(availability: ProviderAvailability, serviceError: String?, workerName: String) {
        self.availability = availability
        let trimmed = serviceError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.serviceError = trimmed.isEmpty ? nil : trimmed
        self.workerName = workerName
    }

    /// The compact visible label.
    var label: String {
        switch availability {
        case .exited: "Claude adapter exited"
        case .checking: "Checking Claude session"
        }
    }

    /// The visible restart reason while checking. Nil for an exited worker, whose own error notice
    /// is unchanged.
    var reason: String? {
        availability == .checking ? (serviceError ?? Self.defaultRestartReason) : nil
    }

    /// While checking, the notice shows the service's explanation as the restart reason, so the
    /// console's red error line would only repeat it.
    var suppressesConsoleNotice: Bool { availability == .checking && serviceError != nil }

    /// The full statement, for the help tag and the accessible value.
    var statement: String {
        switch availability {
        case .exited:
            return "Claude's adapter for \(workerName) exited after its last turn ended. "
                + "Its transcript and source stay readable. Control was released; taking control, "
                + "handing back and follow-ups are unavailable."
        case .checking:
            return "\(reason ?? Self.defaultRestartReason) Control of \(workerName), including handback, "
                + "is unavailable until its Claude session and turn are confirmed."
        }
    }

    /// A short clause for the tile's accessibility summary.
    var summary: String {
        switch availability {
        case .exited: "Claude adapter exited"
        case .checking: "checking Claude session"
        }
    }

    /// Whether the status line shows the reserved-input cue in place of the ownership cue: only
    /// while checking with the developer's lease held. Otherwise, while exited or checking, the
    /// status line shows no ownership cue, since there is no usable input path to name.
    func showsReservedInput(control: InputControl) -> Bool {
        availability == .checking && control == .held
    }

    /// The tile summary's ownership clause. Never claims live, usable control: nil when exited or
    /// when checking without the lease, a reserved statement when checking with it.
    func controlSummary(control: InputControl) -> String? {
        showsReservedInput(control: control)
            ? "input reserved for you, usable after the original turn is verified"
            : nil
    }
}

/// The status-line cue for a checking worker whose lease the developer still holds. Neutral ink:
/// the lease is reserved, not usable, so it neither reads as control nor offers hand back.
///
///   `🔒 input reserved`, or the symbol alone in a narrow tile with the full statement in its
///   help tag and accessibility label.
struct ReservedInputCue: View {
    let workerName: String
    var isKeyFocused = false
    var size: CGFloat = 11

    private var explanation: String {
        "Input to \(workerName) is reserved for you. It will be usable after the original turn is verified."
    }

    var body: some View {
        HStack(spacing: 10) {
            if isKeyFocused { KeyFocusCue(size: size) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: "lock").font(.system(size: size - 1.5))
                    Text("input reserved").lineLimit(1).fixedSize()
                }
                Image(systemName: "lock").font(.system(size: size - 1.5))
            }
            .font(Term.font(size))
            .foregroundStyle(.inkTermDim)
            .help(explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input reserved")
            .accessibilityValue(explanation)
        }
    }
}

// MARK: - Molecule

/// The availability strip of one worker, in its own row of the lower status area beside the Claude
/// progress row, in every display mode. The task status line below it is unchanged.
///
///   exited    `○ Claude adapter exited  [ Inspect source ]`
///   checking  `↻ Checking Claude session  Service restarted. Waiting for evidence from the original worker.
///              [ Watch Terminal in Window… ] [ Inspect source ]`
///             on one row where it fits; otherwise the label, the wrapped reason, then the actions
///             (stacked on a narrow tile)
///
/// Both actions are the existing passive routes: the standalone read-only terminal window and the
/// read-only source inspector. Neither sends anything to the worker. Each is drawn only when given.
struct ProviderAvailabilityNotice: View {
    let statement: ProviderAvailabilityStatement
    var size: CGFloat = 11
    /// Opens this worker's standalone read-only terminal window. Offered while checking.
    var watchTerminal: (() -> Void)? = nil
    /// Opens this worker's read-only source inspector.
    var inspectSource: (() -> Void)? = nil

    private var isChecking: Bool { statement.availability == .checking }
    private var watch: (() -> Void)? { isChecking ? watchTerminal : nil }

    var body: some View {
        let gap = size * 0.9
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: gap) {
                label
                if let reason = statement.reason { reasonText(reason).fixedSize() }
                actions
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                label
                if let reason = statement.reason {
                    reasonText(reason).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: gap) { actions }.fixedSize()
                    VStack(alignment: .leading, spacing: 3) { actions }.fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Term.font(size))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// The mark and the label. Carries the statement for the help tag and accessibility.
    private var label: some View {
        HStack(spacing: size * 0.45) {
            // Checking is a pending re-establishment, drawn in the attention ink as `↻ reconnecting`
            // is; an exited adapter is a settled fact, drawn neutral so Completed keeps its meaning.
            Text(isChecking ? "↻" : "○")
                .foregroundStyle(isChecking ? AnyShapeStyle(Term.amber) : AnyShapeStyle(.inkTermDim))
            Text(statement.label).foregroundStyle(isChecking ? Term.amber : Term.text)
        }
        .fixedSize()
        .help(statement.statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statement.label), \(statement.workerName)")
        .accessibilityValue(statement.statement)
    }

    private func reasonText(_ reason: String) -> some View {
        Text(reason).foregroundStyle(.inkTermDim).textSelection(.enabled)
            .help(statement.statement)
            .accessibilityLabel("Restart reason: \(reason)")
    }

    @ViewBuilder
    private var actions: some View {
        if let watch {
            Button("Watch Terminal in Window…", action: watch)
                .buttonStyle(TermButtonStyle(ink: Term.text, size: size))
                .fixedSize()
                .help("Open \(statement.workerName)'s terminal in a read-only window. Keys and paste are not sent.")
                .accessibilityLabel("Watch the terminal of \(statement.workerName) in a window")
        }
        if let inspectSource {
            Button("Inspect source", action: inspectSource)
                .buttonStyle(TermButtonStyle(ink: Term.text, size: size))
                .fixedSize()
                .help("Open the read-only source inspector for \(statement.workerName).")
                .accessibilityLabel("Inspect source of \(statement.workerName)")
        }
    }
}
