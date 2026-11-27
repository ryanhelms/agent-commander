import SwiftUI

// ACTIVITY RESULT VIEWS
// The body of an opened Pretty line: the call and its result drawn by their properties, with the
// wire name, tool ID and exact text behind one quiet Source action (DESIGN.md, "Typed results";
// spec section E). Values come from `ActivityResult.swift`.
//
//   Value      ActivityResultSource     what one opened call holds: names, texts, state, failure
//   Atoms      IDChip, PathText         a short ID with its full value in help; a middle-cut path
//   Molecules  ResultFieldList          label and typed value rows (the generic renderer)
//              ResultRecordTable        a uniform list as a table
//              ResultQuote              quoted text that keeps its line breaks, clamped
//              ResultWell               file lines or terminal output in the terminal face
//              ResultEmptyState         the sentence an empty result reads as
//              ResultTruncationBanner   a result the service cut short
//              SecretValue              "Hidden, N characters" with Reveal
//              ResultDisclosure         a quiet nested disclosure ("3 more fields, 1 empty")
//              ResultSourceDisclosure   wire name, tool ID, call and result text; Copy is exact
//   Organism   ActivityResultView       selects the renderer, then adds More fields and Source
//
// Hide-secrets is applied here, when a value is drawn. It covers Source too, and Copy needs
// Reveal first. The stored record is never changed.

struct ActivityResultSource: Equatable {
    /// The tool's wire name. Empty for a result with no recorded call.
    var name: String
    var toolID: String
    /// What was tried, in plain words, for the failure renderer.
    var tried: String
    var callText: String?
    var resultText: String?
    var statusWord: String
    var failure: ActivityFailure?
    /// The state now, from the run record by exact ID. Nil when the run record does not hold it.
    var liveState: String?
    /// The stored values the service shortened: `input`, `result`.
    var cut: [String] = []

    /// One call of a line. `record` is the stored full record, once it has been read.
    init(entry: TranscriptEntry, step: ActivityStep, record: ToolDetailRecord?) {
        toolID = entry.id
        failure = step.entries.count == 1 || step.entries.last?.id == entry.id ? step.failure : nil
        liveState = nil
        cut = record?.truncated ?? []
        switch entry.kind {
        case .tool(let name, let detail, let result):
            self.name = name
            callText = record?.input.flatMap { $0.isEmpty ? nil : $0 } ?? detail
            resultText = record?.result.flatMap { $0.isEmpty ? nil : $0 } ?? result?.output
            statusWord = result == nil ? "running" : (result?.error == nil ? "completed" : ToolStatus(result: result).word)
            if failure == nil, let result, result.error != nil {
                failure = ActivityFailureWords.read(result, status: ToolStatus(result: result))
            }
            if let call = CommanderCall(entry: entry) {
                tried = call.tool.label
                liveState = call.facts?.liveOperationStatus ?? call.facts?.liveRequestStatus
            } else {
                tried = ActivityWords.provider(name: name, detail: detail).running.plain
            }
        case .output(let result):
            name = ""
            callText = nil
            resultText = result.output
            statusWord = result.error == nil ? "completed" : ToolStatus(result: result).word
            tried = "A call that was not recorded"
        default:
            name = ""
            callText = nil
            resultText = nil
            statusWord = ""
            tried = ""
        }
    }
}

// MARK: - Atoms

struct IDChip: View {
    let id: String
    var size: CGFloat = 11

    var body: some View {
        Text(verbatim: id.count > 12 ? String(id.prefix(8)) + "…" : id)
            .font(Term.font(size)).foregroundStyle(.inkSecondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5)
            .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1) }
            .help(id)
            .accessibilityLabel("ID \(id)")
    }
}

/// A path in the terminal face, cut in the middle, with its last part bright. Never opened.
struct PathText: View {
    let path: String
    var size: CGFloat = 11.5

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        (Text(verbatim: folder).foregroundColor(Palette.secondary)
         + Text(verbatim: name).fontWeight(.medium).foregroundColor(Palette.foreground))
            .font(Term.font(size))
            .lineLimit(1).truncationMode(.middle)
            .help(path)
            .accessibilityLabel(path)
    }
}

// MARK: - Molecules

struct ResultEmptyState: View {
    let sentence: String
    let metrics: PrettyMetrics

    var body: some View {
        Text(verbatim: sentence).font(.system(size: metrics.detailSize + 0.5)).foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ResultTruncationBanner: View {
    let text: String
    let metrics: PrettyMetrics

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: metrics.detailSize)).foregroundStyle(Palette.attention)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous)
                    .strokeBorder(Palette.attention.opacity(0.4), lineWidth: 1)
            }
    }
}

struct ResultQuote: View {
    let text: String
    let metrics: PrettyMetrics
    var lines: Int? = 6

    var body: some View {
        PrettyClamp(lines: lines, lineHeight: (metrics.detailSize + 0.5) * 1.4, metrics: metrics) {
            Text(verbatim: text)
                .font(.system(size: metrics.detailSize + 0.5)).foregroundStyle(Palette.foreground)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 2) }
    }
}

/// Lines in the terminal face inside a well: a file's numbered lines, or a command's output.
struct ResultWell: View {
    struct Line: Equatable { var number: String? = nil; let text: String; var isPrompt = false }

    let lines: [Line]
    let metrics: PrettyMetrics
    /// How many lines show before "Show all", and whether the end is kept (terminal output).
    var limit = 12
    var keepsEnd = false
    @State private var showsAll = false

    var body: some View {
        let hidden = showsAll ? 0 : max(0, lines.count - limit)
        let shown = hidden == 0 ? lines : (keepsEnd ? Array(lines.prefix(1).filter(\.isPrompt)) + lines.suffix(limit) : Array(lines.prefix(limit)))
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1.5) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let number = line.number {
                            Text(verbatim: number).foregroundStyle(Palette.secondary.opacity(0.7))
                                .frame(width: 26, alignment: .trailing)
                        }
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.isPrompt ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(.inkSecondary))
                            .fontWeight(line.isPrompt ? .medium : .regular)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Term.font(metrics.codeSize))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1)
            }
            if hidden > 0 {
                Button("Show all \(lines.count) lines") { showsAll = true }
                    .buttonStyle(.plain).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.focus)
            }
        }
    }

    /// A file read as numbered lines (`N⇥text` or `N→text`), or nil when the text is not one.
    static func numbered(_ text: String) -> [Line]? {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !rows.isEmpty else { return nil }
        var lines: [Line] = []
        for row in rows {
            let trimmed = row.drop { $0 == " " }
            let digits = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(digits.count)
            guard !digits.isEmpty, let separator = rest.first, separator == "\t" || separator == "→" else {
                if row.isEmpty, !lines.isEmpty { continue }
                return nil
            }
            lines.append(Line(number: String(digits), text: String(rest.dropFirst())))
        }
        return lines
    }

    static func plain(_ text: String, prompt: String? = nil) -> [Line] {
        var rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { Line(text: String($0)) }
        while let last = rows.last, last.text.isEmpty { rows.removeLast() }
        if let prompt { rows.insert(Line(text: "$ " + prompt, isPrompt: true), at: 0) }
        return rows
    }
}

/// A secret-looking value under the hide-secrets setting.
struct SecretValue: View {
    let text: String
    let metrics: PrettyMetrics
    @State private var isRevealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: isRevealed ? text : SecretValues.hidden(text))
                .font(isRevealed ? Term.font(metrics.detailSize - 0.5) : .system(size: metrics.detailSize + 0.5))
                .foregroundStyle(isRevealed ? AnyShapeStyle(Palette.foreground) : AnyShapeStyle(.inkSecondary))
            Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                .buttonStyle(.plain).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.focus)
                .accessibilityLabel(isRevealed ? "Hide this value" : "Reveal this value")
        }
    }
}

/// A quiet nested disclosure, closed by default.
struct ResultDisclosure<Content: View>: View {
    let title: String
    let metrics: PrettyMetrics
    var mono = false
    var startsOpen = false
    @ViewBuilder let content: () -> Content
    @State private var isOpen: Bool?

    var body: some View {
        let open = isOpen ?? startsOpen
        VStack(alignment: .leading, spacing: 6) {
            Button { isOpen = !open } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: title)
                        .font(mono ? Term.font(metrics.tagSize + 0.5, weight: .medium) : .system(size: metrics.detailSize))
                        .foregroundStyle(.inkSecondary)
                        .multilineTextAlignment(.leading)
                    ActivityChevron(isExpanded: open, size: metrics.detailSize)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ActivityRowButtonStyle())
            .textSelection(.disabled)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { content() }
        }
    }
}

/// The generic renderer: one labelled row per property, each value drawn by its kind.
struct ResultFieldList: View {
    let rows: [ResultField]
    let metrics: PrettyMetrics
    var hidesSecrets = false
    var depth = 0
    /// The state now, from the run record, shown beside a top-level `state` or `status`.
    var liveState: String? = nil
    /// Labels a renderer gives its own properties in place of the key's sentence case.
    var labels: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: labels[row.key] ?? row.label)
                        .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                        .frame(width: metrics.labelWidth, alignment: .leading)
                        .help(row.key)
                    value(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func value(_ row: ResultField) -> some View {
        let size = metrics.detailSize + 0.5
        switch row.kind {
        case .status:
            let word = row.value.string ?? ""
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusLamp(word: word, size: size)
                    if depth == 0, let liveState, liveState.lowercased() != word.lowercased() {
                        Text("when this call returned").font(.system(size: metrics.detailSize - 1)).foregroundStyle(.inkSecondary)
                    }
                }
                if depth == 0, let liveState, liveState.lowercased() != word.lowercased() {
                    HStack(spacing: 6) {
                        StatusLamp(word: liveState, size: size)
                        Text("now, from the run record").font(.system(size: metrics.detailSize - 1)).foregroundStyle(.inkSecondary)
                    }
                }
            }
        case .yesNo:
            Text(row.value.bool == true ? "Yes" : "No").font(.system(size: size)).foregroundStyle(Palette.foreground)
        case .empty:
            Text(row.value.string != nil || row.value.members != nil ? "empty" : "none")
                .font(.system(size: size)).foregroundStyle(.inkSecondary)
        case .id:
            IDChip(id: row.value.string ?? "", size: metrics.tagSize + 0.5)
        case .path:
            PathText(path: row.value.string ?? "", size: metrics.detailSize - 0.5)
        case .time:
            let exact = row.value.string ?? ""
            (Text(verbatim: ResultField.date(exact)?.formatted(date: .abbreviated, time: .standard) ?? exact)
                .foregroundColor(Palette.foreground)
             + Text(verbatim: "  " + exact).font(Term.font(metrics.tagSize)).foregroundColor(Palette.secondary))
                .font(.system(size: size))
        case .link:
            let text = row.value.string ?? ""
            Text(verbatim: text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                .font(.system(size: size)).foregroundStyle(Palette.focus).lineLimit(2).truncationMode(.middle)
                .help(text)
        case .number:
            Text(verbatim: row.value.scalarText ?? "").font(Term.font(metrics.detailSize)).foregroundStyle(Palette.foreground)
        case .text:
            Text(verbatim: row.value.scalarText ?? "").font(.system(size: size)).foregroundStyle(Palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
        case .longText:
            let text = row.value.string ?? ""
            // A string that is itself JSON is read and nested.
            if depth < 4, let inner = OrderedJSON.read(text.trimmingCharacters(in: .whitespacesAndNewlines))?.value,
               inner.members != nil {
                ResultFieldList(rows: ResultField.rows(inner), metrics: metrics, hidesSecrets: hidesSecrets, depth: depth + 1)
            } else {
                ResultQuote(text: text, metrics: metrics)
            }
        case .scalarList:
            let items = (row.value.items ?? []).compactMap(\.scalarText)
            if items.count <= 6 {
                Text(verbatim: items.joined(separator: ", ")).font(.system(size: size)).foregroundStyle(Palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(verbatim: "• " + item).font(.system(size: size)).foregroundStyle(Palette.foreground)
                    }
                }
            }
        case .table:
            let items = row.value.items ?? []
            if ResultShape.uniform(items), items.count > 1 {
                ResultRecordTable(items: items, metrics: metrics, hidesSecrets: hidesSecrets)
            } else if depth < 4 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if item.members != nil {
                            ResultFieldList(rows: ResultField.rows(item), metrics: metrics, hidesSecrets: hidesSecrets, depth: depth + 1)
                        } else {
                            Text(verbatim: "\(index + 1). " + (item.scalarText ?? "list")).font(.system(size: size))
                                .foregroundStyle(Palette.foreground)
                        }
                    }
                }
            } else {
                Text("Deeper values are in Source.").font(.system(size: size)).foregroundStyle(.inkSecondary)
            }
        case .object:
            let members = row.value.members ?? []
            if depth >= 4 {
                Text("Deeper values are in Source.").font(.system(size: size)).foregroundStyle(.inkSecondary)
            } else {
                // Open when it has four or fewer scalar fields.
                ResultDisclosure(title: members.count == 1 ? "1 field" : "\(members.count) fields", metrics: metrics,
                                 startsOpen: members.filter { $0.value.isScalar }.count <= 4 && members.count <= 4) {
                    ResultFieldList(rows: ResultField.rows(row.value), metrics: metrics, hidesSecrets: hidesSecrets, depth: depth + 1)
                }
            }
        case .secret:
            if hidesSecrets {
                SecretValue(text: row.value.string ?? "", metrics: metrics)
            } else {
                Text(verbatim: row.value.string ?? "").font(Term.font(metrics.detailSize - 0.5))
                    .foregroundStyle(Palette.foreground).lineLimit(3).truncationMode(.middle)
            }
        }
    }
}

/// A uniform list of records as a table: up to five columns in first-seen order, the
/// identifying one first. Other properties stay in Source.
struct ResultRecordTable: View {
    let items: [OrderedJSON]
    let metrics: PrettyMetrics
    var hidesSecrets = false
    /// Columns a renderer names. Nil picks them from the records.
    var columns: [String]? = nil
    var limit = 12
    @State private var showsAll = false

    static let identifying = ["name", "title", "id", "label", "peer", "resource"]

    static func columns(of items: [OrderedJSON]) -> [String] {
        var seen: [String] = []
        for item in items {
            for member in item.members ?? [] where member.value.isScalar && !seen.contains(member.key) {
                seen.append(member.key)
            }
        }
        if let lead = identifying.first(where: seen.contains) {
            seen.removeAll { $0 == lead }
            seen.insert(lead, at: 0)
        }
        return Array(seen.prefix(5))
    }

    var body: some View {
        let keys = columns ?? Self.columns(of: items)
        let shown = showsAll ? items : Array(items.prefix(limit))
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    ForEach(keys, id: \.self) { key in
                        Text(verbatim: ResultField.label(key)).font(.system(size: metrics.detailSize - 1, weight: .medium))
                            .foregroundStyle(.inkSecondary).lineLimit(1)
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(keys, id: \.self) { key in cell(key, item[key]) }
                    }
                }
            }
            if items.count > shown.count {
                Button("Show all \(items.count)") { showsAll = true }
                    .buttonStyle(.plain).font(.system(size: metrics.detailSize)).foregroundStyle(Palette.focus)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func cell(_ key: String, _ value: OrderedJSON?) -> some View {
        let size = metrics.detailSize
        if let value, !value.isEmpty, let text = value.scalarText {
            if ResultField.statusKeys.contains(key.lowercased()) {
                StatusLamp(word: text, size: size)
            } else if hidesSecrets, SecretValues.looksSecret(key: key, value: value) {
                Text(verbatim: SecretValues.hidden(text)).font(.system(size: size)).foregroundStyle(.inkSecondary)
            } else {
                Text(verbatim: CommanderCall.firstLine(text)).font(.system(size: size)).foregroundStyle(Palette.foreground)
                    .lineLimit(2).truncationMode(.tail)
                    .help(text)
            }
        } else {
            Text(value == nil || value?.isEmpty == true ? "none" : "…").font(.system(size: size)).foregroundStyle(.inkSecondary)
        }
    }
}

/// The quiet Source action that ends every opened view: wire name, tool ID, the call and the
/// result text. JSON is pretty-printed; Copy keeps the exact original text.
struct ResultSourceDisclosure: View {
    let source: ActivityResultSource
    let metrics: PrettyMetrics
    var hidesSecrets = false
    let copy: (String) -> Void
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.bottom, 8)
            ResultDisclosure(title: "Source", metrics: metrics, mono: true) {
                let call = part(source.callText)
                let result = part(source.resultText)
                let hidden = call.hidden + result.hidden
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        (Text(verbatim: source.name.isEmpty ? "result" : source.name).foregroundColor(Palette.foreground)
                         + Text(verbatim: "  " + source.toolID + "  " + source.statusWord))
                            .fixedSize(horizontal: false, vertical: true)
                        if let text = call.text {
                            Text("call").foregroundStyle(Palette.foreground)
                            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                        }
                        if let text = result.text {
                            Text(source.failure == nil ? "result" : "error").foregroundStyle(Palette.foreground)
                            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                        }
                        if call.isCut || result.isCut || !source.cut.isEmpty {
                            Text("The text ends here: it was cut short before it was stored.").foregroundStyle(Palette.attention)
                        }
                    }
                    .font(Term.font(metrics.codeSize - 0.5))
                    .foregroundStyle(.inkSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: metrics.chipRadius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1)
                    }
                    HStack(spacing: 12) {
                        if hidden > 0 {
                            Text(hidden == 1 ? "1 value hidden" : "\(hidden) values hidden").foregroundStyle(.inkSecondary)
                            Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                                .buttonStyle(.plain).foregroundStyle(Palette.focus)
                        }
                        let locked = hidden > 0 && !isRevealed
                        if let text = source.callText, !text.isEmpty {
                            Button("Copy call") { copy(text) }.buttonStyle(.plain).foregroundStyle(locked ? Palette.secondary.opacity(0.5) : Palette.focus)
                                .disabled(locked)
                                .help(locked ? "Reveal the hidden values before copying" : "Copy the call text exactly as sent")
                        }
                        if let text = source.resultText, !text.isEmpty {
                            Button("Copy result") { copy(text) }.buttonStyle(.plain).foregroundStyle(locked ? Palette.secondary.opacity(0.5) : Palette.focus)
                                .disabled(locked)
                                .help(locked ? "Reveal the hidden values before copying" : "Copy the result text exactly as sent")
                        }
                    }
                    .font(.system(size: metrics.detailSize))
                }
            }
        }
    }

    /// One text as Source shows it: JSON indented, secrets hidden unless revealed.
    private func part(_ text: String?) -> (text: String?, hidden: Int, isCut: Bool) {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return (nil, 0, false) }
        let formatted = PrettyJSON.format(text)
        guard hidesSecrets else { return (formatted.text, 0, formatted.isCut) }
        let masked = SecretValues.masked(text: formatted.text)
        return (isRevealed ? formatted.text : masked.text, masked.count, formatted.isCut)
    }
}

// MARK: - Organism

/// The opened line's body. In order: the typed body its shape selects, then every property the
/// renderer did not place behind "N more fields", then Source.
struct ActivityResultView: View {
    let source: ActivityResultSource
    let metrics: PrettyMetrics
    var hidesSecrets = false
    var copy: (String) -> Void = { _ in }

    var body: some View {
        let payload = ResultPayload.read(source.resultText)
        let failed = source.failure != nil
        let selection = ResultShape.select(tool: source.name, payload: payload, resultText: source.resultText, failed: failed)
        VStack(alignment: .leading, spacing: 10) {
            if !failed, payload.isCut || source.cut.contains("result") {
                ResultTruncationBanner(text: "Commander kept only the first part of this result. The end is missing.",
                                       metrics: metrics)
            }
            typed(selection, payload: payload)
            if let value = payload.value, !selection.remaining.isEmpty {
                let rows = ResultField.rows(value, keys: selection.remaining)
                let empty = rows.filter { $0.kind == .empty }.count
                ResultDisclosure(title: (rows.count == 1 ? "1 more field" : "\(rows.count) more fields")
                                 + (empty > 0 ? ", \(empty) empty" : ""), metrics: metrics) {
                    ResultFieldList(rows: rows, metrics: metrics, hidesSecrets: hidesSecrets)
                }
            }
            ResultSourceDisclosure(source: source, metrics: metrics, hidesSecrets: hidesSecrets, copy: copy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func typed(_ selection: ResultShape.Selection, payload: ResultPayload) -> some View {
        let value = payload.value ?? .null
        switch selection.shape {
        case .failure:
            failure(payload)
        case .empty(let sentence):
            ResultEmptyState(sentence: sentence, metrics: metrics)
        case .text:
            ResultQuote(text: value.string ?? (source.resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines), metrics: metrics)
        case .textFile:
            textFile
        case .terminal:
            ResultWell(lines: ResultWell.plain(source.resultText ?? "", prompt: subject(["command", "cmd", "script"])),
                       metrics: metrics, keepsEnd: true)
        case .change, .searchResults, .webResults:
            if let subject = subject(["file_path", "path", "pattern", "query", "url"]) {
                ResultFieldList(rows: [ResultField(key: selection.shape == .change ? "file" : "looked_for", value: .string(subject))],
                                metrics: metrics)
            }
            ResultWell(lines: ResultWell.plain(source.resultText ?? ""), metrics: metrics)
        case .checklist(let key):
            PrettyPlanCard(items: PlanItem.items(key.flatMap { value[$0] } ?? value) ?? [], metrics: metrics)
        case .recordTable(let key):
            ResultRecordTable(items: (key.flatMap { value[$0] } ?? value).items ?? [], metrics: metrics, hidesSecrets: hidesSecrets)
        case .messageList(let key):
            messages((key.flatMap { value[$0] } ?? value).items ?? [], truncated: value["truncated"]?.bool == true)
        case .runRoster:
            roster(value)
        case .report:
            ResultFieldList(rows: ResultField.rows(value, keys: ["id"]), metrics: metrics, labels: ["id": "Reported by"])
        case .workerCard, .questionCard, .acknowledgement, .operationReceipt, .followUp, .controlState:
            ResultFieldList(rows: ResultField.rows(value, keys: selection.placed), metrics: metrics, hidesSecrets: hidesSecrets,
                            liveState: source.liveState, labels: Self.labels(selection.shape))
        case .generic:
            if value.members != nil {
                ResultFieldList(rows: ResultField.rows(value), metrics: metrics, hidesSecrets: hidesSecrets)
            } else if let items = value.items {
                ResultFieldList(rows: [ResultField(key: "items", value: .array(items))], metrics: metrics, hidesSecrets: hidesSecrets)
            } else {
                ResultEmptyState(sentence: "This result could not be read as data. Its text is in Source.", metrics: metrics)
            }
        }
    }

    static func labels(_ shape: ResultShape) -> [String: String] {
        switch shape {
        case .workerCard: ["name": "Worker", "host": "Runs on", "client": "With", "created_at": "Created"]
        case .questionCard: ["worker_id": "Asked by"]
        case .operationReceipt: ["id": "Operation"]
        case .controlState: ["held": "Developer holds input", "messages": "Queued follow-ups"]
        default: [:]
        }
    }

    /// A value of the call's arguments, from JSON or the call's plain text.
    private func subject(_ keys: [String]) -> String? {
        guard let text = source.callText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let value = OrderedJSON.read(text)?.value, value.members != nil {
            for key in keys { if let found = value[key]?.scalarText { return found } }
            return nil
        }
        return ToolDetailText.headline(text)
    }

    private func failure(_ payload: ResultPayload) -> some View {
        let failure = source.failure
            ?? ActivityFailure(outcome: .failed, reason: payload.wrapperError ?? ActivityFailureWords.noReason,
                               exact: payload.wrapperError ?? ActivityFailureWords.noReason)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                row("Tried") { Text(verbatim: source.tried).foregroundStyle(Palette.foreground) }
                row("Outcome") {
                    HStack(spacing: 6) {
                        StatusLamp(word: failure.outcome == .blocked ? "Blocked" : "Failed", size: metrics.detailSize + 0.5)
                        Text(verbatim: failure.meaning).font(.system(size: metrics.detailSize - 1)).foregroundStyle(.inkSecondary)
                    }
                }
                row("Reason") { Text(verbatim: failure.reason).foregroundStyle(Palette.foreground) }
                if failure.exact != failure.reason {
                    row("Exact text") { Text(verbatim: failure.exact).foregroundStyle(Palette.foreground) }
                }
            }
            if let rest = failure.rest {
                // Shown as text only; nothing in it is acted on.
                ResultDisclosure(title: "Rest of the provider's message, written for the agent", metrics: metrics) {
                    ResultQuote(text: rest, metrics: metrics, lines: nil)
                }
            }
        }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label).font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                .frame(width: metrics.labelWidth, alignment: .leading)
            value().font(.system(size: metrics.detailSize + 0.5)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var textFile: some View {
        let text = source.resultText ?? ""
        let numbered = ResultWell.numbered(text)
        let lines = numbered ?? ResultWell.plain(text)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                if let path = subject(["file_path", "path", "filePath", "notebook_path", "target_file", "file"]) {
                    row("File") { PathText(path: path, size: metrics.detailSize - 0.5) }
                }
                row("Read") {
                    Text(verbatim: numbered != nil
                         ? ActivityWords.count(lines.count, "numbered line")
                            + (lines.last?.text.isEmpty == true && lines.count > 1 ? ", the last one empty" : "")
                         : ActivityWords.count(lines.count, "line"))
                        .foregroundStyle(Palette.foreground)
                }
            }
            ResultWell(lines: lines, metrics: metrics)
        }
    }

    private func roster(_ value: OrderedJSON) -> some View {
        let workers = value["workers"]?.items ?? []
        let requests = value["requests"]?.items ?? []
        return VStack(alignment: .leading, spacing: 10) {
            if source.name.isEmpty {
                ResultEmptyState(sentence: "It reads as a run status.", metrics: metrics)
            }
            ResultFieldList(rows: ResultField.rows(value, keys: ["project", "status", "path", "task"].filter { value[$0] != nil }),
                            metrics: metrics, labels: ["project": "Run", "path": "Folder"])
            if workers.isEmpty {
                ResultEmptyState(sentence: "No workers.", metrics: metrics)
            } else {
                ResultRecordTable(items: workers, metrics: metrics,
                                  columns: ["name", "role", "state", "host", "result"].filter { key in
                                      key != "result" || workers.contains { $0[key] != nil }
                                  })
            }
            if value["requests"] != nil {
                if requests.isEmpty {
                    ResultEmptyState(sentence: "No open requests.", metrics: metrics)
                } else {
                    ResultRecordTable(items: requests, metrics: metrics, columns: ["question", "status", "answer"])
                }
            }
            if let integrations = value["integrations"]?.items, !integrations.isEmpty {
                ResultFieldList(rows: [ResultField(key: "integrations", value: .array(integrations))], metrics: metrics)
            }
        }
    }

    private func messages(_ items: [OrderedJSON], truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty { ResultEmptyState(sentence: "No messages.", metrics: metrics) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    let sender = ["peer", "sender", "from", "author"].compactMap { item[$0]?.scalarText }.first
                    let time = ["receivedAt", "received_at", "time", "at"].compactMap { item[$0]?.string }.first
                    Text(verbatim: [sender, item["resource"]?.scalarText.map { "via " + $0 },
                                    time.map { ResultField.date($0)?.formatted(date: .abbreviated, time: .shortened) ?? $0 }]
                        .compactMap { $0 }.joined(separator: ", "))
                        .font(.system(size: metrics.detailSize)).foregroundStyle(.inkSecondary)
                    ResultQuote(text: item["text"]?.string ?? "", metrics: metrics)
                }
            }
            if truncated { ResultEmptyState(sentence: "Older messages were left out.", metrics: metrics) }
        }
    }
}
