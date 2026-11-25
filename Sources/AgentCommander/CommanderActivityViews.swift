import SwiftUI

// COMMANDER ACTIVITY VIEWS
// Pretty's purposeful rows for Commander's own MCP calls, in the terminal's restrained voice.
// The same views serve the coordinator, a wall tile, the focused worker and the PiP: every one
// draws `PrettyConsoleView`, which lays a `CommanderWorkflow` out with these.
//
//   Atom      ActivityStatusMark       status word with a symbol, or a subtle indeterminate spinner
//   Molecule  CommanderActivityHeader  domain symbol, label, summary, outcome, step trail, status
//   Organism  CommanderActivityCard    = header + the original call rows when open (collapsed by default)
//
// Values come from `CommanderWorkflow`; the card emits only its toggle. A pending request is
// answered in its existing request form, never here.

extension CommanderActivityStatus {
    /// The symbol ahead of the word, so status never rests on colour alone.
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "ellipsis"
        case .waitingForReply: "hourglass"
        case .awaitingApproval: "hand.raised"
        case .answered: "checkmark.bubble"
        case .complete: "checkmark"
        case .failed: "xmark"
        case .cancelled, .declined, .interrupted: "exclamationmark"
        case .partial: "circle.lefthalf.filled"
        case .uncertain: "questionmark.circle"
        case .reported: "circle.dotted"
        }
    }

    var ink: Color {
        switch self {
        case .complete, .answered: Term.green
        case .failed: Term.red
        case .awaitingApproval, .partial, .uncertain: Palette.attention
        case .running, .waitingForReply, .queued, .cancelled, .declined, .interrupted: Term.amber
        case .reported: Palette.secondary
        }
    }
}

/// ATOM. A status as a word with its symbol. A live status (running, waiting for reply) shows a
/// small indeterminate spinner instead of the symbol; with Reduce Motion the symbol stays.
struct ActivityStatusMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: CommanderActivityStatus
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: fontSize * 0.35) {
            if status.isLive && !reduceMotion {
                ProgressView().controlSize(.mini).scaleEffect(fontSize < 11 ? 0.8 : 1)
                    .frame(width: fontSize, height: fontSize)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: fontSize - 1.5, weight: .semibold))
            }
            Text(status.word)
                .font(.system(size: fontSize - 1, weight: .medium))
        }
        .foregroundStyle(status.ink)
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.word)
    }
}

/// MOLECULE. The one line that stands for a Commander workflow: what it is, what it was about,
/// what came back, its steps and its status. A button: it opens the original calls.
struct CommanderActivityHeader: View {
    let workflow: CommanderWorkflow
    let isExpanded: Bool
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let toggle: () -> Void

    var body: some View {
        let status = workflow.status
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: fontSize - 3.5, weight: .semibold))
                    .foregroundStyle(.inkSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: fontSize - 2)
                    .accessibilityHidden(true)
                Image(systemName: workflow.symbol)
                    .font(.system(size: fontSize - 1, weight: .medium))
                    .foregroundStyle(status == .awaitingApproval ? Palette.attention : Term.violet)
                    .frame(width: fontSize + 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: density == .pip ? 0 : 2) {
                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
                        Text(workflow.title)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Palette.foreground.opacity(0.9))
                            .lineLimit(1).fixedSize()
                        if let summary = workflow.summary {
                            Text(verbatim: summary)
                                .font(Term.font(fontSize - 0.5))
                                .foregroundStyle(Term.text)
                                .lineLimit(isExpanded ? 4 : 1).truncationMode(.tail)
                        }
                    }
                    if let line = secondLine {
                        Text(verbatim: line)
                            .font(Term.font(fontSize - 1.5))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(isExpanded ? 3 : 1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: fontSize * 0.5)
                if workflow.failedCalls > 0, status != .failed {
                    // A failed poll stays visible even while the request is still unresolved.
                    Text(workflow.failedCalls == 1 ? "1 call failed" : "\(workflow.failedCalls) calls failed")
                        .font(.system(size: fontSize - 2, weight: .medium))
                        .foregroundStyle(Term.red)
                        .lineLimit(1).fixedSize()
                }
                ActivityStatusMark(status: status, fontSize: fontSize)
            }
            .padding(.horizontal, fontSize * 0.7).padding(.vertical, fontSize * (density == .pip ? 0.3 : 0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .help(workflow.reference.map { "Linked by exact \($0)" } ?? "Commander tool call")
        .accessibilityLabel(workflow.accessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the original Commander calls")
    }

    /// The step trail first, so it survives truncation on a narrow tile; then the outcome and the
    /// linking ID, shortened (the full ID is in the help tag and fields).
    private var secondLine: String? {
        var parts: [String] = []
        if let steps = workflow.steps { parts.append(steps) }
        if let outcome = workflow.outcome { parts.append(outcome) }
        switch workflow.link {
        case .request(let id): parts.append(CommanderCall.request(id))
        case .operation(let id): parts.append(CommanderCall.operation(id))
        case .revision(let revision): parts.append("rev \(Identifier.short(revision))")
        case .single: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// ORGANISM. A Commander workflow as one quiet card, collapsed by default. Open, it lists every
/// original call in order, drawn by the console's own row (the shared `TranscriptToolRow` with
/// its detail, result, error and fields action), so nothing about a call is lost.
struct CommanderActivityCard<Member: View>: View {
    let workflow: CommanderWorkflow
    let isExpanded: Bool
    var fontSize: CGFloat = 12
    var density: PrettyDensity = .regular
    let toggle: () -> Void
    @ViewBuilder let member: (TranscriptEntry) -> Member

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: fontSize * 0.7, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            CommanderActivityHeader(workflow: workflow, isExpanded: isExpanded, fontSize: fontSize,
                                    density: density, toggle: toggle)
            if isExpanded {
                Rectangle().fill(.inkHairline).frame(height: 1)
                VStack(alignment: .leading, spacing: density == .pip ? 3 : 5) {
                    ForEach(workflow.entries) { entry in member(entry) }
                }
                .padding(.horizontal, fontSize * 0.6).padding(.vertical, fontSize * 0.5)
                .background(Palette.well)
            }
        }
        .background(Palette.panel.opacity(0.7), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(workflow.status == .awaitingApproval ? Palette.attentionEdge : Palette.hairline,
                               lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
