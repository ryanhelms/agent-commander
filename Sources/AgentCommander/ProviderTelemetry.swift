import SwiftUI

// PROVIDER TELEMETRY
// What a provider (ACP) session last reported about its own consumption, for the console footer.
// Two independent facts, each exactly as reported and never derived from the other:
//
//   context  the latest `usage_update`: tokens in the context window, its size, and any cost
//   tokens   the latest prompt result's reported token counts. An adapter may report the turn or
//            the session total, so they are shown as "reported tokens", never summed or diffed.
//
// The service's worker `telemetry` field is the source: it keeps the latest live readings apart
// from the bounded transcript. A worker without it falls back to the newest live message whose
// `metadata.acp` carries the same reading. A count the provider did not report is absent, never 0.
//
//   Values     ProviderTelemetry           the two readings, read once per projection
//   Molecule   ProviderUsageStatus         the footer cue: context gauge and percentage, input and
//                                          output tokens, or a compact "usage —" when nothing yet

struct ProviderTelemetry: Equatable, Sendable {
    struct Context: Equatable, Sendable {
        let used: Int64
        let size: Int64
        /// The cost literal exactly as reported, and its currency.
        var costAmount: String? = nil
        var costCurrency: String? = nil

        /// The share of the window in use, limited to 0...1 for an indicator. Nil without a size.
        var fraction: Double? {
            guard size > 0 else { return nil }
            return min(max(Double(used) / Double(size), 0), 1)
        }

        /// Whole percent for an indicator, limited to 0...100. Nil without a size.
        var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }

        var cost: String? {
            guard let costAmount else { return nil }
            return costAmount + (costCurrency.map { " " + $0 } ?? "")
        }
    }

    struct Tokens: Equatable, Sendable {
        var input: Int64? = nil
        var output: Int64? = nil
        var thought: Int64? = nil
        var cachedRead: Int64? = nil
        var cachedWrite: Int64? = nil
        var total: Int64? = nil

        var isEmpty: Bool { [input, output, thought, cachedRead, cachedWrite, total].allSatisfy { $0 == nil } }

        /// Each reported count with its name, in a fixed order. Absent counts are left out.
        var reported: [(name: String, count: Int64)] {
            let all: [(String, Int64?)] = [("input", input), ("output", output), ("thought", thought),
                                           ("cached read", cachedRead), ("cached write", cachedWrite), ("total", total)]
            return all.compactMap { pair -> (name: String, count: Int64)? in
                pair.1.map { (name: pair.0, count: $0) }
            }
        }
    }

    var context: Context? = nil
    var tokens: Tokens? = nil

    var isEmpty: Bool { context == nil && tokens == nil }

    /// The worker's readings: its `telemetry` field first, then, for whichever reading that
    /// lacks, the newest live message carrying it.
    static func reported(fields: AGUIValue, messages: [AGUIMessage]) -> ProviderTelemetry {
        var telemetry = ProviderTelemetry()
        if case .object(let projected)? = fields["telemetry"] {
            telemetry.context = projected["context"].flatMap(context(from:))
            telemetry.tokens = projected["turnTokens"].flatMap(tokens(from:))
        }
        guard telemetry.context == nil || telemetry.tokens == nil else { return telemetry }
        for message in messages.reversed() {
            guard case .object(let acp)? = message.metadata?["acp"],
                  acp["source"]?.stringValue == ConversationChunks.liveSource else { continue }
            let kind = acp["kind"]?.stringValue
            if telemetry.context == nil, kind == "usage_update", let usage = acp["usage"].flatMap(context(from:)) {
                telemetry.context = usage
            }
            if telemetry.tokens == nil, kind == "acp.prompt_result", let turn = acp["turnTokens"].flatMap(tokens(from:)) {
                telemetry.tokens = turn
            }
            if telemetry.context != nil && telemetry.tokens != nil { break }
        }
        return telemetry
    }

    static func context(from value: AGUIValue) -> Context? {
        guard case .object(let usage) = value,
              let used = usage["used"]?.numberValue?.int64Value, used >= 0,
              let size = usage["size"]?.numberValue?.int64Value, size >= 0 else { return nil }
        var context = Context(used: used, size: size)
        if case .object(let cost)? = usage["cost"], let amount = cost["amount"]?.numberValue {
            context.costAmount = amount.literal
            context.costCurrency = cost["currency"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        return context
    }

    static func tokens(from value: AGUIValue) -> Tokens? {
        guard case .object(let fields) = value else { return nil }
        func count(_ key: String) -> Int64? { fields[key]?.numberValue?.int64Value }
        let tokens = Tokens(input: count("inputTokens"), output: count("outputTokens"),
                            thought: count("thoughtTokens"), cachedRead: count("cachedReadTokens"),
                            cachedWrite: count("cachedWriteTokens"), total: count("totalTokens"))
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: Words

    /// The full statement with exact counts, for help tags and accessibility.
    var statement: String {
        var parts: [String] = []
        if let context {
            var line = "Latest usage: \(context.used) of \(context.size) context tokens"
            if let percent = context.percent {
                line += context.used > context.size ? ", over the window" : ", \(percent) percent"
            }
            if let cost = context.cost { line += ", cost \(cost)" }
            parts.append(line + ".")
        } else {
            parts.append("No context usage reported yet.")
        }
        if let tokens {
            parts.append("Reported tokens for the latest prompt: "
                         + tokens.reported.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
                         + ". The provider may report the turn or the session total.")
        } else {
            parts.append("No token counts reported yet.")
        }
        return parts.joined(separator: " ")
    }
}

extension CockpitModel {
    /// A worker's reported usage from the runs this model already holds, for a surface outside
    /// the cockpit such as the standalone terminal window. No new subscription. Nil when the
    /// worker is unknown or has no provider session.
    func providerTelemetry(workerID: String) -> ProviderTelemetry? {
        for run in runs {
            guard let worker = run.workers?.first(where: { $0.id == workerID }) else { continue }
            guard worker.boundSession != nil else { return nil }
            return ProviderTelemetry.reported(fields: worker.allFields, messages: worker.messages ?? [])
        }
        return nil
    }
}

// MARK: - Molecule

/// The footer cue for a provider session's reported consumption. It takes the widest face that
/// fits: context gauge, percentage and window, then input and output tokens; then the context
/// alone; then the percentage alone. With nothing reported it says `usage —`. The exact counts
/// are always the help tag and the accessible value.
struct ProviderUsageStatus: View {
    let telemetry: ProviderTelemetry
    var size: CGFloat = 11

    var body: some View {
        Group {
            if telemetry.isEmpty {
                Text("usage —").foregroundStyle(.inkTermDim)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { contextFace(window: true); tokensFace }
                    HStack(spacing: 8) { contextFace(window: false); tokensFace }
                    contextFace(window: true)
                    contextFace(window: false)
                    tokensFace
                }
            }
        }
        .font(Term.font(size))
        .lineLimit(1)
        .help(telemetry.statement)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provider usage")
        .accessibilityValue(telemetry.statement)
    }

    @ViewBuilder
    private func contextFace(window: Bool) -> some View {
        if let context = telemetry.context {
            HStack(spacing: 5) {
                if let fraction = context.fraction {
                    UsageBar(fraction: fraction, ink: ink(context), height: max(3, size * 0.32))
                        .frame(width: size * 2.6)
                }
                Text("ctx").foregroundStyle(.inkTermDim)
                if let percent = context.percent {
                    Text(context.used > context.size ? ">100%" : "\(percent)%").foregroundStyle(ink(context))
                }
                if window || context.percent == nil {
                    Text(TranscriptOrigin.compact(context.used) + "/" + TranscriptOrigin.compact(context.size))
                        .foregroundStyle(Term.text)
                }
            }
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private var tokensFace: some View {
        if let tokens = telemetry.tokens {
            HStack(spacing: 5) {
                if let input = tokens.input { label("in", input) }
                if let output = tokens.output { label("out", output) }
                // Neither input nor output was reported: the total, if any, stands for them.
                if tokens.input == nil, tokens.output == nil, let total = tokens.total { label("tok", total) }
            }
            .monospacedDigit()
        }
    }

    private func label(_ name: String, _ count: Int64) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(.inkTermDim)
            Text(TranscriptOrigin.compact(count)).foregroundStyle(Term.text)
        }
    }

    private func ink(_ context: ProviderTelemetry.Context) -> Color {
        guard let fraction = context.fraction else { return Term.text }
        if context.used > context.size || fraction >= 0.9 { return Term.red }
        if fraction >= 0.75 { return Term.amber }
        return Term.green
    }
}

/// A thin capacity bar, filled to `fraction` (already limited to 0...1).
private struct UsageBar: View {
    let fraction: Double
    let ink: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Term.rule)
                Capsule().fill(ink).frame(width: max(height, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
