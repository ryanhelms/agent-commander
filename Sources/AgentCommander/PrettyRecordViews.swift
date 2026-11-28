import SwiftUI

// PRETTY RECORD VIEWS (DESIGN.md, "Pretty transcript"; spec section H)
// Values come from `PrettyRecords.swift`; density and type come from the console.
//
//   Molecule   PrettyTurnEndLine       the end of a turn: how long it worked, or why it stopped
//              PrettyFormOutcomeLine   the line after a form reply: answered, declined, cancelled
//              PrettyCompactionDivider the boundary of a finished compaction, and its summary
//              PrettyChoiceCard        a provider question's choices, read-only
//              PrettyPlanDocument      a proposed plan as Markdown beside a rule
//              PrettyDeliverableCard   a published artifact or a sent file: name, kind, Open
//   Organism   PrettyToolCardView      picks the card for a call and keeps its opened line
//
// No new tokens. Nothing here reads the service.

/// The last item of a turn. Secondary ink for a duration or a cancelled turn; attention ink
/// when the provider stopped the turn itself. Never folded.
struct PrettyTurnEndLine: View {
    let end: PrettyTurnEnd
    let metrics: PrettyMetrics

    var body: some View {
        ActivitySentenceText(sentence: end.sentence, metrics: metrics,
                             ink: end.tone == .attention ? Palette.attention : Palette.secondary)
            .frame(maxWidth: metrics.readingWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(end.spoken)
    }
}

/// The line after the owner's reply to a form request: "Answered a form", "Declined a form" or
/// "Cancelled a form", in secondary ink like a turn's duration. It is text: it does not open,
/// takes no Tab stop and shows nothing the owner entered. Never folded.
struct PrettyFormOutcomeLine: View {
    let outcome: PrettyFormOutcome
    let metrics: PrettyMetrics

    var body: some View {
        ActivitySentenceText(sentence: outcome.sentence, metrics: metrics, ink: Palette.secondary)
            .frame(maxWidth: metrics.readingWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(outcome.spoken)
    }
}

/// The boundary of a finished provider compaction: a hairline rule on each side of "Conversation
/// compacted" and, when the record holds the provider's summary, the transcript's link "Show the
/// summary". It opens in place to that text beside a rule. Nothing above it is removed or dimmed.
/// With no summary it is text: no link and no Tab stop. Never folded.
///
/// The row has two layouts and takes the first that fits the width it is given:
///   wide     rule, heading, link, rule on one line, each rule at least `wideRule` long
///   stacked  rule, heading, rule, with the link centred on its own line beneath
/// A row with no summary has no link, so it is always the one line.
struct PrettyCompactionDivider: View {
    /// The provider's own summary, exactly as sent. Nil draws no link.
    let summary: String?
    let isExpanded: Bool
    let metrics: PrettyMetrics
    let toggle: () -> Void

    private static let showTitle = "Show the summary"
    private static let hideTitle = "Hide the summary"

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
            boundary
            if isExpanded, let summary {
                // A tile shows the first six lines and the PiP three; the focused worker and
                // coordinator show it all.
                let clamp: Int? = metrics.density == .regular ? nil : (metrics.density == .compact ? 6 : 3)
                PrettyClamp(lines: clamp, lineHeight: metrics.bodySize * 1.45, metrics: metrics) {
                    // The provider's text as sent: nothing is trimmed from either end.
                    Text(verbatim: summary)
                        .font(metrics.body)
                        .lineSpacing(metrics.lineSpacing * 0.6)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, metrics.density == .pip ? 9 : 15)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Compaction summary")
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
    }

    /// The boundary row. `ViewThatFits` measures each layout at its ideal width, where a rule is
    /// its minimum, so the wide layout is chosen only when both rules keep that length.
    @ViewBuilder
    private var boundary: some View {
        if summary == nil {
            headingLine
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: gap) {
                    rule(atLeast: wideRule)
                    heading.fixedSize()
                    link
                    rule(atLeast: wideRule)
                }
                VStack(alignment: .center, spacing: metrics.lineSpacing) {
                    headingLine
                    link
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A rule on each side of the heading. The heading keeps its width before the rules do; in a
    /// width too small for it, it ends in an ellipsis inside the row and never draws past it.
    private var headingLine: some View {
        HStack(alignment: .center, spacing: gap) {
            rule(atLeast: metrics.markerWidth)
            heading.layoutPriority(1)
            rule(atLeast: metrics.markerWidth)
        }
    }

    private var heading: some View {
        Text("Conversation compacted")
            .font(.system(size: metrics.detailSize)).foregroundStyle(Palette.secondary)
            .lineLimit(1)
    }

    /// The link, in a slot as wide as the longer of its two titles. The row's width, and so the
    /// layout chosen, is the same open and closed: toggling never swaps the layout under the
    /// keyboard focus.
    private var link: some View {
        ZStack {
            Text(Self.showTitle).font(.system(size: metrics.detailSize)).lineLimit(1).fixedSize().hidden()
            Text(Self.hideTitle).font(.system(size: metrics.detailSize)).lineLimit(1).fixedSize().hidden()
            PrettyLinkButton(title: isExpanded ? Self.hideTitle : Self.showTitle,
                             size: metrics.detailSize, action: toggle)
                .prettyDisclosureKeys(isExpanded: isExpanded, radius: metrics.chipRadius, toggle: toggle)
                .accessibilityLabel("Summary of the compacted conversation")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the summary the provider wrote")
        }
    }

    private var gap: CGFloat { metrics.density == .pip ? 8 : 12 }
    /// The shortest a rule may be beside the link on one line: twice the stacked row's.
    private var wideRule: CGFloat { metrics.markerWidth * 2 }

    private func rule(atLeast length: CGFloat) -> some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
            .frame(minWidth: length, idealWidth: length, maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// A provider's own question while it waits: the question, each option with its description, a
/// square mark when several may be chosen and a round one otherwise. Commander does not answer
/// this tool, so the card is read-only and says where the answer goes.
struct PrettyChoiceCard: View {
    let questions: [PrettyChoiceQuestion]
    let metrics: PrettyMetrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.density == .pip ? 6 : 10) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: metrics.density == .pip ? 3 : 6) {
                    Text(verbatim: question.question).font(metrics.body.weight(.medium)).foregroundStyle(Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options) { option in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: question.allowsSeveral ? "square" : "circle")
                                .font(.system(size: metrics.bodySize - 2)).foregroundStyle(.inkSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: option.label).font(metrics.body).foregroundStyle(Palette.foreground)
                                if let description = option.description, metrics.density != .pip {
                                    Text(verbatim: description).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if question.allowsSeveral {
                        Text("Several may be chosen.").font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                    }
                }
            }
            Text("Answer this in the terminal.").font(.system(size: metrics.detailSize)).foregroundStyle(Palette.attention)
        }
        .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.density == .pip ? 6 : 10)
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the provider. Answer this in the terminal.")
    }
}

/// A proposed plan: the plan as Markdown beside the report block's rule. In full on the focused
/// worker and coordinator; its first lines on a tile and the PiP.
struct PrettyPlanDocument: View {
    let plan: String
    let metrics: PrettyMetrics

    var body: some View {
        PrettyClamp(lines: metrics.density == .regular ? nil : metrics.clampLines, lineHeight: metrics.bodySize * 1.5,
                    metrics: metrics) {
            PrettyAssistantTurn(text: plan, metrics: metrics)
        }
        .padding(.leading, metrics.density == .pip ? 9 : 14)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan")
    }
}

/// What a call made for the reader: one row per file with its name, its kind and Open.
struct PrettyDeliverableCard: View {
    let deliverable: PrettyDeliverable
    let metrics: PrettyMetrics
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.listRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(deliverable.files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: file.kind == "Artifact" ? "doc.richtext" : "doc")
                        .font(.system(size: metrics.bodySize - 1)).foregroundStyle(.inkSecondary).accessibilityHidden(true)
                    Text(verbatim: file.name).font(metrics.body.weight(.medium)).foregroundStyle(Palette.foreground)
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: file.kind).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                    Spacer(minLength: 8)
                    if let url = file.url {
                        PrettyLinkButton(title: "Open", size: metrics.bodySize) { openURL(url) }
                            .accessibilityLabel("Open \(file.name)")
                    }
                }
                .padding(.vertical, metrics.density == .pip ? 2 : 5)
            }
            if let caption = deliverable.caption, metrics.density != .pip {
                Text(verbatim: caption).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, metrics.lineInset.width).padding(.vertical, metrics.density == .pip ? 3 : 6)
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// A call in the open: its sentence, which opens to the call's result and Source like any line,
/// then its card. With no stored input the sentence stands alone.
struct PrettyToolCardView<Detail: View>: View {
    let card: PrettyToolCard
    let summary: ToolDetailSummary?
    let record: ToolDetailRecord?
    let metrics: PrettyMetrics
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let detail: () -> Detail

    private var tag: ActivityTag? {
        // A finished plan call is the provider's word that the plan was accepted.
        if card.kind == .plan, card.step.state == .done { return ActivityTag(word: "approved", tone: .ok) }
        return card.step.tag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.blockSpacing * 0.8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ActivitySentenceText(sentence: card.step.sentence, metrics: metrics)
                    if let tag { ActivityTagView(tag: tag, metrics: metrics) }
                    ActivityChevron(isExpanded: isExpanded, size: metrics.bodySize)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ActivityRowButtonStyle())
            .textSelection(.disabled)
            .accessibilityLabel(([card.step.sentence.plain] + [tag?.word].compactMap { $0 }).joined(separator: ", "))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded { detail().padding(.leading, 14) }
            switch card.kind {
            case .question:
                let questions = PrettyChoiceQuestion.questions(input: record?.input)
                if questions.isEmpty {
                    Text("Answer this in the terminal.").font(.system(size: metrics.detailSize)).foregroundStyle(Palette.attention)
                } else {
                    PrettyChoiceCard(questions: questions, metrics: metrics)
                }
            case .plan:
                if let plan = PrettyToolInput.plan(input: record?.input, summary: summary) {
                    PrettyPlanDocument(plan: plan, metrics: metrics)
                }
            case .deliverable:
                if case .tool(let name, _, let result)? = card.entry?.kind {
                    let made = PrettyDeliverable(name: name, input: record?.input, summary: summary, result: result)
                    if !made.files.isEmpty { PrettyDeliverableCard(deliverable: made, metrics: metrics) }
                }
            }
        }
        .frame(maxWidth: metrics.readingWidth, alignment: .leading)
    }
}
