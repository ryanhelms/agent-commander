import SwiftUI

// COMMANDER ACTIVITY STATUS
// The status atom every activity story uses, in the terminal's restrained voice. The story card,
// its header, timeline, actions and Tool details are in ActivityStoryViews.swift.
//
//   Atom   ActivityStatusMark   status word with a symbol, or a subtle indeterminate spinner

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
        case .accepted: "checkmark.circle"
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
        case .accepted, .reported: Palette.secondary
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
