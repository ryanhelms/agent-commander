import AppKit
import SwiftUI

// ATOMIC LEVEL: Templates.
// Layout only. Templates give regions stable positions, resizing priorities and overlay anchors and
// take their content as slots. They know nothing about runs, workers or requests.
//
//   CockpitShell      navigation | (banners over canvas), on the window's glass
//   CoordinatorSplit  run header over a resizable coordinator | worker region, or the coordinator
//                     alone while the worker region is closed, with a side-panel anchor at the
//                     trailing edge and a floating anchor at the bottom trailing corner
//   TaskSheet         page header, form beside an aside, pinned footer

// MARK: - CockpitShell

/// Window-level frame. Navigation floats on the window material; the canvas is a darker sheet with
/// a rounded top-leading corner. Terminal wells and cards inside the canvas stay opaque.
struct CockpitShell<Navigation: View, Banners: View, Canvas: View>: View {
    @Environment(\.usesOpaqueSurfaces) private var reduceTransparency
    @Environment(\.theme) private var theme
    /// The theme's window material, with Reduce Transparency forcing the opaque form.
    private var isOpaque: Bool { reduceTransparency || theme.material.window == .opaque }
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let banners: Banners
    @ViewBuilder let canvas: Canvas

    var body: some View {
        HStack(spacing: 0) {
            navigation
            VStack(spacing: 0) {
                banners
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background {
                if isOpaque {
                    theme.material.opaqueCanvasFill.color
                } else {
                    Rectangle().fill(theme.material.canvasFill.style)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.canvas, style: .continuous))
            .overlay {
                // Light catches the canvas's top and leading edge and fades out below.
                UnevenRoundedRectangle(topLeadingRadius: Radius.canvas, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.02)],
                                                 startPoint: .topLeading, endPoint: .center), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(Palette.foreground)
        .background {
            // Black-violet depth over the window material, extended under the toolbar band, with an
            // illuminated hairline along the window's top edge.
            if !isOpaque {
                LinearGradient(colors: [Palette.depthTop, Palette.depthMid, Palette.depthBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Palette.windowRim.opacity(0.25), Palette.windowRim, Palette.windowRim.opacity(0.25)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 1)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .modifier(WindowGlass())
    }
}

/// Native visual-effect material behind the whole window, including the 52 pt toolbar band.
/// Reduce Transparency replaces it with the opaque chrome role.
struct WindowGlass: ViewModifier {
    @Environment(\.usesOpaqueSurfaces) private var reduceTransparency
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if reduceTransparency || theme.material.window == .opaque {
            content.containerBackground(theme.material.windowFill.color, for: .window)
        } else {
            content.containerBackground(.ultraThinMaterial, for: .window)
        }
    }
}

// MARK: - CoordinatorSplit

/// The coordinator stays in the leading pane while the trailing region switches between wall and
/// zoom. With the trailing region closed the coordinator takes the whole width and there is no
/// divider. The leading slot is the same view in both forms, so opening or closing the trailing
/// region never rebuilds it. The divider is draggable, focusable and adjustable through
/// accessibility, and reports the width as drawn. The side panel and the floating stack are
/// anchored to the region's trailing edge in both forms.
struct CoordinatorSplit<Header: View, Leading: View, Trailing: View, Floating: View, Drawer: View>: View {
    /// The coordinator's remembered share of the width. Written only when the divider is moved.
    @Binding var fraction: Double
    /// The trailing region is open.
    var showsTrailing = true
    let showsFloating: Bool
    /// The side panel is on screen, and whether it is pinned. Pinned, the pane beside it gives up
    /// the panel's width while a readable tile is left; otherwise the panel lies over the pane.
    var showsDrawer = false
    var drawerPinned = false
    @ViewBuilder let header: Header
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let floating: Floating
    @ViewBuilder let drawer: Drawer
    @State private var dragOrigin: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            GeometryReader { geo in
                let geometry = WorkspaceSplitGeometry(width: geo.size.width, fraction: fraction, showsWorkers: showsTrailing,
                                                      showsDrawer: showsDrawer, drawerPinned: drawerPinned)
                HStack(spacing: 0) {
                    leading
                        .padding(.horizontal, Metric.paneInset)
                        .padding(.bottom, Metric.paneBottom)
                        .padding(.trailing, showsTrailing ? 0 : geometry.drawerReservation)
                        .frame(width: geometry.coordinatorWidth)
                    if showsTrailing {
                        divider(geometry)
                        trailing
                            .padding(.horizontal, Metric.paneInset)
                            .padding(.bottom, Metric.paneBottom)
                            .padding(.trailing, geometry.drawerReservation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if showsDrawer { drawer }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsFloating {
                        floating
                            .frame(width: geometry.floatingWidth)
                            .padding(.trailing, Metric.pipTrailing)
                            .padding(.bottom, Metric.pipBottom)
                    }
                }
            }
        }
    }

    private func divider(_ geometry: WorkspaceSplitGeometry) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: WorkspaceSplitGeometry.divider)
            .frame(maxHeight: .infinity)
            .overlay {
                ZStack {
                    Color.clear.frame(width: Metric.dividerHitWidth).contentShape(Rectangle())
                    Capsule().fill(Color(hex: 0x5E6372))
                        .overlay { Capsule().strokeBorder(Color(hex: 0x999DAE)) }
                        .frame(width: 5, height: 36)
                }
                .frame(maxHeight: .infinity)
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            // A drag starts from where the divider is drawn, not from a remembered
                            // share this window could not show.
                            let origin = dragOrigin ?? geometry.renderedFraction
                            dragOrigin = origin
                            fraction = geometry.fraction(from: origin, movedBy: value.translation.width / max(1, geometry.width))
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
            }
            .zIndex(1)
            .focusable()
            .onMoveCommand { direction in
                if direction == .left { fraction = geometry.fraction(movedBy: -0.02) }
                if direction == .right { fraction = geometry.fraction(movedBy: 0.02) }
            }
            .help("Drag, or focus and use the arrow keys, to resize the coordinator")
            .accessibilityElement()
            .accessibilityLabel("Coordinator width")
            .accessibilityValue("\(geometry.percent) percent")
            .accessibilityAdjustableAction { direction in
                fraction = geometry.fraction(movedBy: direction == .increment ? 0.04 : -0.04)
            }
    }
}

extension CoordinatorSplit where Drawer == EmptyView {
    /// A split with no side panel.
    init(fraction: Binding<Double>, showsTrailing: Bool = true, showsFloating: Bool,
         @ViewBuilder header: () -> Header, @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder floating: () -> Floating) {
        self.init(fraction: fraction, showsTrailing: showsTrailing, showsFloating: showsFloating,
                  header: header, leading: leading, trailing: trailing, floating: floating, drawer: { EmptyView() })
    }
}

// MARK: - WorkspacePage

/// A workspace page: heading above free-flowing content, scrolling as one column.
struct WorkspacePage<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .top)
    /// What the page shows now: how far it is scrolled, and the heights of the window and the column.
    @State private var viewport = PageReveal.Viewport()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                header
                content
            }
            .padding(.top, theme.space.pageInset - 6)
            .padding(.horizontal, theme.space.pageInset)
            .padding(.bottom, theme.space.pageInset - 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Something that opens below the fold asks to be brought into view (`shellRevealed`). It
            // may sit inside the bands' own sideways scroll, where a reader's `scrollTo` moves that
            // inner scroll view and leaves the page where it is. So the page measures the view in
            // its own column and scrolls itself to the offset that shows it.
            .overlayPreferenceValue(PageRevealKey.self, alignment: .topLeading) { targets in
                GeometryReader { geometry in
                    ForEach(targets, id: \.id) { target in
                        Color.clear.frame(width: 1, height: 1)
                            .onAppear { reveal(geometry[target.bounds], anchor: target.anchor) }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: PageReveal.Viewport.self) { geometry in
            PageReveal.Viewport(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                height: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom,
                                content: geometry.contentSize.height)
        } action: { _, next in viewport = next }
    }

    private func reveal(_ frame: CGRect, anchor: UnitPoint?) {
        // After this layout pass, so the column has grown to hold the view.
        DispatchQueue.main.async {
            guard let y = PageReveal.offset(showing: frame, in: viewport, anchor: anchor, margin: theme.space.pageInset - 8) else { return }
            withAnimation(reduceMotion ? nil : theme.motion.animation(theme.motion.standard)) { position.scrollTo(y: y) }
        }
    }
}

/// How a part of the page is brought into view.
enum PageReveal {
    /// What a page shows: how far its column is scrolled, the height it shows and the column's height.
    struct Viewport: Equatable {
        var offset: CGFloat = 0
        var height: CGFloat = 0
        var content: CGFloat = 0
    }

    /// The offset that shows `frame`, a view's place in the page's column. Nil when it already
    /// shows, or when the page hasn't been measured. With no anchor the page moves the least that
    /// shows the view with `margin` around it; a view taller than the page, or one anchored to the
    /// top, is put with its top edge at the top.
    static func offset(showing frame: CGRect, in viewport: Viewport, anchor: UnitPoint?, margin: CGFloat) -> CGFloat? {
        guard viewport.height > 0 else { return nil }
        // The column is at least as tall as the view it holds, whatever was last measured.
        let limit = max(0, max(viewport.content, frame.maxY + margin) - viewport.height)
        let top = frame.minY - margin, bottom = frame.maxY + margin
        var target = viewport.offset
        if anchor == .top || bottom - top > viewport.height {
            target = top
        } else if bottom > viewport.offset + viewport.height {
            target = bottom - viewport.height
        } else if top < viewport.offset {
            target = top
        }
        target = min(max(0, target), limit)
        return abs(target - viewport.offset) < 0.5 ? nil : target
    }
}

/// A view that asked to be revealed: where it is, and which edge to hold when it is taller than
/// the window. With no anchor the page moves the least that shows it.
struct PageRevealTarget: Equatable {
    let id: String
    let bounds: Anchor<CGRect>
    let anchor: UnitPoint?
}

struct PageRevealKey: PreferenceKey {
    static var defaultValue: [PageRevealTarget] { [] }
    static func reduce(value: inout [PageRevealTarget], nextValue: () -> [PageRevealTarget]) { value += nextValue() }
}

extension View {
    /// Scrolls the page until this view shows, once, when it appears: a confirmation or a form that
    /// opened in answer to a press. Eased, or at once with Reduce Motion. `anchor` puts that edge of
    /// a view taller than the window at the same edge of the page.
    func shellRevealed(_ id: String, anchor: UnitPoint? = nil) -> some View {
        anchorPreference(key: PageRevealKey.self, value: .bounds) { [PageRevealTarget(id: id, bounds: $0, anchor: anchor)] }
    }
}

// MARK: - CollectionInspector

/// A collection beside the inspector for its selection. The collection keeps a stable width and
/// the inspector takes the remaining room.
struct CollectionInspector<Collection: View, Inspector: View>: View {
    var collectionWidth: CGFloat = 380
    var spacing: CGFloat = 20
    /// When set, the inspector keeps this width at the trailing edge and the collection is flexible.
    var inspectorWidth: CGFloat? = nil
    @ViewBuilder let collection: Collection
    @ViewBuilder let inspector: Inspector

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            if let inspectorWidth {
                collection.frame(maxWidth: .infinity, alignment: .topLeading)
                inspector.frame(width: inspectorWidth, alignment: .topLeading)
            } else {
                collection.frame(width: collectionWidth, alignment: .topLeading)
                inspector.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - WeightedRow

/// Lays its children out in columns whose widths follow fixed weights, so a table's header and
/// rows line up without measuring content.
struct WeightedRow: Layout {
    let weights: [CGFloat]
    var spacing: CGFloat = 14

    private func widths(for total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let used = (0..<count).map { $0 < weights.count ? max(0.01, weights[$0]) : 1 }
        let sum = used.reduce(0, +)
        let available = max(0, total - spacing * CGFloat(count - 1))
        return used.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? 640
        let total = proposed.isFinite ? proposed : 640
        let columns = widths(for: total, count: subviews.count)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: columns[index], height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(for: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let cell = ProposedViewSize(width: columns[index], height: nil)
            let size = subview.sizeThatFits(cell)
            subview.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), anchor: .topLeading, proposal: cell)
            x += columns[index] + spacing
        }
    }
}

// MARK: - TaskSheet

/// A task page: heading, a form beside an aside, and a footer that stays pinned. The aside drops
/// below the form when the canvas is narrow.
struct TaskSheet<Header: View, FormContent: View, Aside: View, Footer: View>: View {
    /// When set, the leading column keeps this width and the aside takes the remaining room
    /// (a result list beside a wide inspector). Otherwise the aside has the fixed sheet width.
    var formWidth: CGFloat? = nil
    @ViewBuilder let header: Header
    @ViewBuilder let form: FormContent
    @ViewBuilder let aside: Aside
    @ViewBuilder let footer: Footer
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let wide = geo.size.width >= 2 * theme.space.pageInset + Metric.sheetAsideWidth + 30 + 420
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: theme.space.sectionGap + 3) {
                        header
                        if wide, let formWidth {
                            HStack(alignment: .top, spacing: 30) {
                                form.frame(width: formWidth, alignment: .topLeading)
                                aside.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else if wide {
                            HStack(alignment: .top, spacing: 30) {
                                form.frame(maxWidth: .infinity, alignment: .topLeading)
                                aside.frame(width: Metric.sheetAsideWidth)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 24) {
                                form.frame(maxWidth: .infinity, alignment: .topLeading)
                                aside.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.top, theme.space.pageInset - 6)
                    .padding(.horizontal, theme.space.pageInset)
                    .padding(.bottom, theme.space.pageInset - 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            ThemeRule()
            footer
                .padding(.horizontal, theme.space.pageInset)
                .frame(maxWidth: .infinity, minHeight: Metric.sheetFooterHeight, maxHeight: Metric.sheetFooterHeight)
        }
    }
}
