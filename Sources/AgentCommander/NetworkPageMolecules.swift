import SwiftUI

// ATOMIC LEVEL: Foundations, molecules and the page template (main-window network pages).
// What the full-size network pages share. Each reads `\.theme`, takes values and emits one
// targeted action. The tray's atoms and molecules (lamp, state label, swatch, avatar, mark, badge,
// hash chip, agent chip, verb strip, countdown) are used as they are; the pieces here are the ones
// a 400 pt tray never needed.
//
//   NetworkLayout        widths of the pages' regions and columns (foundation)
//   ShellBandHeading     a band's name, its count and one trailing action (molecule)
//   ShellAlertBand       what the network is doing, what it confirmed or why it failed (molecule)
//   ShellColumn          one column of a data table: title, width, alignment (value)
//   ShellTableHeader     mono header cells on the well (molecule)
//   ShellTableRow        one hairline row: selectable cells, then the row's verbs (molecule)
//   ShellTable           header and rows on one panel, or its empty note (molecule)
//   ShellServerTag       a server's swatch and name (molecule)
//   ShellNote            a lamp and one sentence inside a panel (molecule)
//   ShellPersonCell      a person and the server they are on (molecule)
//   NetworkInspector     the panel beside a collection: title, an embedded tray organism, footer (organism)
//   NetworkSplit         a collection beside its inspector, or over it when both don't fit (template)
//   NetworkFitWidth      a page's bands at the window's width, or their own least width (template)
//   NetworkPageScaffold  header, telemetry strip, alert band, then the page's bands (template)

enum NetworkLayout {
    /// The inspector beside a collection. The tray's organisms were drawn for 400 pt, so they sit
    /// in it at their own measure.
    static let inspectorWidth: CGFloat = 420
    /// The least an inspector narrows to beside a collection: the tray's own width.
    static let inspectorMinimum: CGFloat = 400
    /// A narrow collection beside a wide detail (fan-out, threads).
    static let listWidth: CGFloat = 340
    /// The network model's grant sheet scrolls inside itself, so its inspector gives it a height.
    static let grantHeight: CGFloat = 560
    /// The least a column without a width of its own is given.
    static let flexibleColumn: CGFloat = 132
    static let stateColumn: CGFloat = 132
    static let serverColumn: CGFloat = 116
    static let figureColumn: CGFloat = 72
    static let timeColumn: CGFloat = 84
    static let personColumn: CGFloat = 132
    /// The least width of one person's cell in the people grid.
    static let personCell: CGFloat = 248
    /// The least width of one answer in the compare columns.
    static let answerColumn: CGFloat = 248
}

// MARK: - Molecules

/// A band's heading: its name in secondary ink, its count in full ink, and at most one action.
struct ShellBandHeading<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var count: String? = nil
    /// One line beside the heading, in `sub`.
    var note: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                ThemeHeading(text: title)
                if let count {
                    Text(count).themeType(theme.type.heading).textCase(nil).monospacedDigit()
                        .foregroundStyle(.theme(\.color.foreground))
                        .contentTransition(.numericText())
                        .animation(theme.motion.animation(theme.motion.standard), value: count)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
            if let note {
                Text(note).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            trailing
        }
        .frame(minHeight: theme.space.controlHeight)
    }
}

extension ShellBandHeading where Trailing == EmptyView {
    init(title: String, count: String? = nil, note: String? = nil) {
        self.init(title: title, count: count, note: note) { EmptyView() }
    }
}

/// One sentence about the network's last action, across the page: in progress, confirmed or failed.
struct ShellAlertBand: View {
    enum Kind: Equatable { case progress, success, failure }

    @Environment(\.theme) private var theme
    let kind: Kind
    let text: String
    var dismiss: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
        HStack(spacing: Space.s) {
            switch kind {
            case .progress: MultiplayerSpinner()
            case .success: MultiplayerLamp(kind: .on)
            case .failure: MultiplayerLamp(kind: .error)
            }
            Text(text).themeType(theme.type.body).foregroundStyle(.theme(\.color.foreground))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if let dismiss, kind != .progress {
                SymbolButton(symbol: "xmark", label: "Dismiss", size: 10, action: dismiss)
                    .foregroundStyle(.theme(\.color.secondary))
            }
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: theme.space.fieldHeight)
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(edge, lineWidth: theme.line.hairline) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("network-alert-\(kind)")
    }

    private var fill: Color {
        kind == .failure ? theme.color.failure.opacity(0.12).color : theme.color.well.color
    }

    private var edge: Color {
        kind == .failure ? theme.color.failure.opacity(0.45).color : theme.color.hair.color
    }
}

/// One column of a data table.
struct ShellColumn: Identifiable, Equatable {
    let title: String
    /// Nil shares the room the fixed columns leave.
    var width: CGFloat? = nil
    var alignment: Alignment = .leading

    var id: String { title }

    static func == (left: ShellColumn, right: ShellColumn) -> Bool {
        left.title == right.title && left.width == right.width
    }
}

extension View {
    /// Sizes a cell to its column, so header and rows line up without measuring content.
    func shellCell(_ column: ShellColumn) -> some View {
        frame(width: column.width, alignment: column.alignment)
            .frame(minWidth: column.width == nil ? NetworkLayout.flexibleColumn : nil,
                   maxWidth: column.width == nil ? .infinity : nil, alignment: column.alignment)
    }
}

/// A table's header: column names in `label` on the header fill.
struct ShellTableHeader: View {
    @Environment(\.theme) private var theme
    let columns: [ShellColumn]
    /// Room kept at the trailing edge for the rows' verbs.
    var trailing: CGFloat = 0

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(columns) { column in
                Text(column.title).themeType(theme.type.label).textCase(nil)
                    .foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                    .shellCell(column)
            }
            if trailing > 0 { Color.clear.frame(width: trailing, height: 1) }
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: theme.space.controlHeightLarge)
        .background(theme.surface.headerFill.color)
        .accessibilityHidden(true)
    }
}

/// One row of a table. The cells are one button that selects the row; the verbs sit after them
/// and are their own buttons.
struct ShellTableRow<Cells: View, Verbs: View>: View {
    @Environment(\.theme) private var theme
    var isSelected = false
    /// What VoiceOver says for the cells.
    let spoken: String
    var hint = "Opens the detail"
    /// Nil draws the cells as text.
    var select: (() -> Void)? = nil
    var trailing: CGFloat = 0
    @ViewBuilder var cells: Cells
    @ViewBuilder var verbs: Verbs

    var body: some View {
        HStack(spacing: Space.m) {
            if let select {
                Button(action: select) { row }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken)
                    .accessibilityHint(hint)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                row.accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel(spoken)
            }
            // The room is kept even when a row has no verb, so every row's cells line up with the header.
            if trailing > 0 {
                ZStack(alignment: .trailing) {
                    Color.clear.frame(width: trailing, height: 1)
                    verbs
                }
            }
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: theme.space.rowHeight)
        .modifier(ShellSelectable(isSelected: isSelected))
    }

    private var row: some View {
        HStack(spacing: Space.m) { cells }
            .frame(maxWidth: .infinity, minHeight: theme.space.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension ShellTableRow where Verbs == EmptyView {
    init(isSelected: Bool = false, spoken: String, hint: String = "Opens the detail", select: (() -> Void)? = nil,
         @ViewBuilder cells: () -> Cells) {
        self.init(isSelected: isSelected, spoken: spoken, hint: hint, select: select, trailing: 0, cells: cells) { EmptyView() }
    }
}

/// A data table: the header and the rows on one panel, ruled off by hairlines. With no rows, one note.
struct ShellTable<Item: Identifiable, Row: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let columns: [ShellColumn]
    var trailing: CGFloat = 0
    let items: [Item]
    /// What the table says when it has nothing.
    let empty: String
    var emptyLamp: MultiplayerLamp.Kind = .off
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ShellTableHeader(columns: columns, trailing: trailing)
            if items.isEmpty {
                ThemeRule()
                ShellNote(text: empty, lamp: emptyLamp)
            }
            ForEach(items) { item in
                ThemeRule()
                row(item)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -theme.motion.travel)))
            }
        }
        .themePanel()
        .animation(theme.motion.animation(theme.motion.standard), value: items.map { "\($0.id)" })
    }
}

/// A server as a cell: its swatch and its name.
struct ShellServerTag: View {
    @Environment(\.theme) private var theme
    let id: String
    let name: String

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            MultiplayerSwatch(color: MultiplayerTheme.swatch(for: id))
            Text(name).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary))
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("on \(name)")
    }
}

/// A person as a cell: the avatar, the handle, and under it the server they are on.
struct ShellPersonCell: View {
    let name: String
    let serverID: String
    let serverName: String

    var body: some View {
        HStack(spacing: Space.s) {
            MultiplayerAvatar(image: nil, name: name, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                ShellCellFigure(text: name)
                ShellServerTag(id: serverID, name: serverName)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) on \(serverName)")
    }
}

/// A lamp and one sentence inside a panel: what is being read, why it couldn't be, or that there is nothing.
struct ShellNote: View {
    @Environment(\.theme) private var theme
    let text: String
    var lamp: MultiplayerLamp.Kind = .off

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            MultiplayerLamp(kind: lamp)
            Text(text).themeType(theme.type.body).foregroundStyle(.theme(\.color.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, theme.space.bandTop)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(text)
    }
}

/// The first line of a table cell over its second: a name, then one line about it.
struct ShellCellText: View {
    @Environment(\.theme) private var theme
    let title: String
    var detail: String? = nil
    /// The title is data (an ID, a branch, a handle) and is drawn in mono.
    var isData = false
    /// The detail reports how an action ended: `working` for done, `failure` for why it failed.
    var detailTone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).themeType(isData ? theme.type.data : theme.type.name).foregroundStyle(.theme(\.color.foreground))
                .lineLimit(1).truncationMode(.tail)
            if let detail, !detail.isEmpty {
                Text(detail).themeType(theme.type.sub)
                    .foregroundStyle(.theme(detailTone == .neutral ? \.color.secondary : detailTone.role))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// A row's answers, or how the answer just given ended: a spinner while it runs, then "Done" for a
/// moment. After a failure the answers stay, and the row's own text says why.
struct NetworkRowVerbs: View {
    let isRunning: Bool
    let result: NetworkActionResult?
    let verbs: [MultiplayerRowVerb]

    var body: some View {
        if isRunning {
            MultiplayerSpinner().accessibilityLabel("In progress")
        } else if result?.isDone == true {
            MultiplayerStateLabel(lamp: .on, text: "Done", tone: .working)
                .accessibilityIdentifier("network-row-done")
        } else {
            MultiplayerVerbStrip(verbs: verbs)
        }
    }
}

extension NetworkActionResult {
    /// What a row says under its title once an action ended, in place of its usual detail.
    var rowText: String? { isDone ? message : reason }
    var rowTone: Tone { isDone ? .working : .failure }
}

/// A figure or a time in a table cell.
struct ShellCellFigure: View {
    @Environment(\.theme) private var theme
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text).themeType(theme.type.data).monospacedDigit().lineLimit(1)
            .foregroundStyle(.theme(tone == .neutral ? \.color.foreground : tone.role))
    }
}

// MARK: - Organisms

/// The panel beside a collection. Its body is usually one of the tray's organisms, used as it is.
struct NetworkInspector<Content: View, Footer: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var serverID: String? = nil
    var serverName: String? = nil
    var state: (lamp: MultiplayerLamp.Kind, text: String, tone: Tone)? = nil
    /// One line of context at the foot, beside the actions.
    var note: String? = nil
    var close: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.s) {
                if let serverID { MultiplayerSwatch(color: MultiplayerTheme.swatch(for: serverID)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).themeType(theme.type.title).foregroundStyle(.theme(\.color.foreground))
                        .lineLimit(1).truncationMode(.middle).accessibilityAddTraits(.isHeader)
                    if let serverName {
                        Text(serverName).themeType(theme.type.fingerprint).foregroundStyle(.theme(\.color.secondary)).lineLimit(1)
                    }
                }
                Spacer(minLength: Space.s)
                if let state { MultiplayerStateLabel(lamp: state.lamp, text: state.text, tone: state.tone) }
                if let close {
                    SymbolButton(symbol: "xmark", label: "Close \(title)", size: 10, action: close)
                        .foregroundStyle(.theme(\.color.secondary))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, theme.space.sectionInset)
            .frame(minHeight: theme.space.tabHeight + Space.s)
            ThemeRule()
            content
            if Footer.self != EmptyView.self || note != nil {
                HStack(spacing: Space.s) {
                    if let note {
                        Text(note).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, theme.space.sectionInset)
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface.footerFill.color)
            }
        }
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("network-inspector")
    }
}

extension NetworkInspector where Footer == EmptyView {
    init(title: String, serverID: String? = nil, serverName: String? = nil,
         state: (lamp: MultiplayerLamp.Kind, text: String, tone: Tone)? = nil, note: String? = nil,
         close: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, serverID: serverID, serverName: serverName, state: state, note: note, close: close,
                  content: content) { EmptyView() }
    }
}

/// An inspector with nothing chosen: one sentence saying what choosing a row shows.
struct NetworkInspectorNote: View {
    let text: String
    var lamp: MultiplayerLamp.Kind = .off

    var body: some View {
        ShellNote(text: text, lamp: lamp).themePanel().accessibilityIdentifier("network-inspector-empty")
    }
}

// MARK: - Templates

/// A collection beside its inspector, on the main window's `CollectionInspector`. When the window
/// is too narrow for both, the inspector goes under the collection at its own measure.
struct NetworkSplit<Collection: View, Inspector: View>: View {
    @ViewBuilder var collection: Collection
    @ViewBuilder var inspector: Inspector

    var body: some View {
        NetworkSplitLayout {
            VStack(alignment: .leading, spacing: 0) { collection }
            VStack(alignment: .leading, spacing: 0) { inspector }
        }
    }
}

/// Places a collection beside its inspector when both fit, and the inspector under the
/// collection when they don't. It asks the collection for the least width it can take, so a
/// wide table never pushes the inspector, or the page, past the window's edge.
///   beside   the inspector at 420 pt, or down to 400 pt (the tray's own measure) when that is
///            what lets the collection fit
///   under    the collection at full width, the inspector at up to 540 pt
struct NetworkSplitLayout: Layout {
    var spacing = Space.l
    var inspectorWidth = NetworkLayout.inspectorWidth
    var inspectorMinimum = NetworkLayout.inspectorMinimum
    var stackedInspector = NetworkLayout.inspectorWidth + 120

    struct Arrangement: Equatable {
        var beside: Bool
        var collection: CGFloat
        var inspector: CGFloat
    }

    /// How a width is shared, given the least the collection can take.
    func arrangement(width: CGFloat, collectionMinimum: CGFloat) -> Arrangement {
        let room = width - spacing - collectionMinimum
        if room >= inspectorMinimum {
            let inspector = min(inspectorWidth, room)
            return Arrangement(beside: true, collection: width - spacing - inspector, inspector: inspector)
        }
        return Arrangement(beside: false, collection: max(width, collectionMinimum), inspector: min(stackedInspector, width))
    }

    private func arrangement(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Arrangement {
        let least = subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        // With no width on offer, the layout asks for the two side by side.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? least + spacing + inspectorWidth
        return arrangement(width: width, collectionMinimum: least)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let plan = arrangement(proposal, subviews)
        let collection = subviews[0].sizeThatFits(ProposedViewSize(width: plan.collection, height: nil))
        let inspector = subviews[1].sizeThatFits(ProposedViewSize(width: plan.inspector, height: nil))
        return plan.beside
            ? CGSize(width: plan.collection + spacing + plan.inspector, height: max(collection.height, inspector.height))
            : CGSize(width: plan.collection, height: collection.height + spacing + inspector.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let plan = arrangement(ProposedViewSize(width: bounds.width, height: nil), subviews)
        let collection = ProposedViewSize(width: plan.collection, height: nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: collection)
        let inspector = ProposedViewSize(width: plan.inspector, height: nil)
        if plan.beside {
            subviews[1].place(at: CGPoint(x: bounds.minX + plan.collection + spacing, y: bounds.minY), anchor: .topLeading, proposal: inspector)
        } else {
            let height = subviews[0].sizeThatFits(collection).height
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + height + spacing), anchor: .topLeading, proposal: inspector)
        }
    }
}

/// Gives its one child the container's width, or the least width the child can take when that
/// is more. Inside a sideways scroll area it keeps a page at the window's width until the page
/// can't shrink any further, and only then lets it scroll.
struct NetworkFitWidth: Layout {
    /// The width of the room the page has. Zero before the first layout.
    var container: CGFloat

    private func width(_ subviews: Subviews) -> CGFloat {
        max(container, subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = width(subviews)
        return CGSize(width: width, height: child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width(subviews), height: nil))
    }
}

private struct NetworkPageScrollsSidewaysKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// A network page scrolls sideways when the window is narrower than the least it can take.
    /// A test turns this off to measure that least width.
    var networkPageScrollsSideways: Bool {
        get { self[NetworkPageScrollsSidewaysKey.self] }
        set { self[NetworkPageScrollsSidewaysKey.self] = newValue }
    }
}

/// A network page: the header with its one action, the telemetry strip, what the network is
/// doing now, then the page's bands. Without a helper or a server it says so instead of the bands.
struct NetworkPageScaffold<Actions: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let place: String
    let pages: NetworkPages
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @Environment(\.networkPageScrollsSideways) private var scrollsSideways
    /// The width the page's bands have. Zero until the first layout.
    @State private var width: CGFloat = 0

    var body: some View {
        let state = pages.content
        WorkspacePage {
            PageHeader(kicker: NetworkPlace.kicker(place), title: NetworkPlace.title(place), subtitle: state.summary(for: place)) {
                actions
            }
        } content: {
            VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                if state.isUnavailable || state.servers.isEmpty {
                    ShellLoadNote(text: state.isUnavailable
                                  ? "Commander can’t reach the network helper, so there is nothing to show here."
                                  : "Add a server in the network panel. Its \(NetworkPlace.title(place).lowercased()) show here once you sign in.",
                                  lamp: state.isUnavailable ? .error : .off)
                    if let open = pages.actions.openPanel {
                        Button("Open network panel", action: open).buttonStyle(ThemeButtonStyle())
                    }
                } else {
                    ShellReadoutStrip(cells: state.readouts(for: place), large: true)
                    if let working = state.working {
                        ShellAlertBand(kind: .progress, text: working)
                    } else if let failure = state.failure {
                        ShellAlertBand(kind: .failure, text: failure, dismiss: pages.actions.dismissFailure)
                    } else if let notice = state.notice {
                        ShellAlertBand(kind: .success, text: notice, dismiss: pages.actions.dismissNotice)
                    }
                    bands
                }
            }
        }
        .accessibilityIdentifier("network-page-\(place)")
    }

    /// The page's bands at the page's width. In a window too narrow for the least they can take,
    /// they scroll sideways instead of pushing the navigation off the window.
    @ViewBuilder private var bands: some View {
        let stack = VStack(alignment: .leading, spacing: theme.space.sectionGap) { content }
        if scrollsSideways {
            ScrollView(.horizontal) {
                NetworkFitWidth(container: width) { stack }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            stack
        }
    }
}

extension NetworkPageScaffold where Actions == EmptyView {
    init(place: String, pages: NetworkPages, @ViewBuilder content: () -> Content) {
        self.init(place: place, pages: pages, actions: { EmptyView() }, content: content)
    }
}
