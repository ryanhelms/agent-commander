import AppKit
import SwiftUI

// ATOMIC LEVEL: Templates.
// Layout only. Templates give regions stable positions, resizing priorities and overlay anchors and
// take their content as slots. They know nothing about runs, workers or requests.
//
//   CockpitShell      navigation | (banners over canvas), on the window's glass
//   CoordinatorSplit  run header over a resizable coordinator | worker region, with a floating
//                     anchor at the bottom trailing corner of the worker region
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
/// zoom. The divider is draggable, focusable and adjustable through accessibility.
struct CoordinatorSplit<Header: View, Leading: View, Trailing: View, Floating: View>: View {
    @Binding var fraction: Double
    let showsFloating: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let floating: Floating
    @State private var dragOrigin: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            GeometryReader { geo in
                let width = geo.size.width
                let left = leadingWidth(in: width)
                HStack(spacing: 0) {
                    leading
                        .padding(.horizontal, Metric.paneInset)
                        .padding(.bottom, Metric.paneBottom)
                        .frame(width: max(0, left - 1))
                    divider(totalWidth: width)
                    ZStack(alignment: .bottomTrailing) {
                        trailing
                            .padding(.horizontal, Metric.paneInset)
                            .padding(.bottom, Metric.paneBottom)
                        if showsFloating {
                            floating
                                .frame(width: min(Metric.pipWidth, max(250, width - left - 2 * Metric.paneInset)))
                                .padding(.trailing, Metric.pipTrailing)
                                .padding(.bottom, Metric.pipBottom)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func leadingWidth(in width: CGFloat) -> CGFloat {
        let preferred = max(Metric.minimumCoordinatorWidth, width * fraction)
        return max(220, min(preferred, width - Metric.minimumWorkerRegionWidth))
    }

    private func clamp(_ value: Double) -> Double { min(0.6, max(0.2, value)) }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1)
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
                            let origin = dragOrigin ?? fraction
                            dragOrigin = origin
                            fraction = clamp(origin + value.translation.width / max(1, totalWidth))
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
            }
            .zIndex(1)
            .focusable()
            .onMoveCommand { direction in
                if direction == .left { fraction = clamp(fraction - 0.02) }
                if direction == .right { fraction = clamp(fraction + 0.02) }
            }
            .help("Drag, or focus and use the arrow keys, to resize the coordinator")
            .accessibilityElement()
            .accessibilityLabel("Coordinator width")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                fraction = clamp(fraction + (direction == .increment ? 0.04 : -0.04))
            }
    }
}

// MARK: - WorkspacePage

/// A workspace page: heading above free-flowing content, scrolling as one column.
struct WorkspacePage<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space.sectionGap) {
                    header
                    content
                }
                .padding(.top, theme.space.pageInset - 6)
                .padding(.horizontal, theme.space.pageInset)
                .padding(.bottom, theme.space.pageInset - 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Something that opens below the fold asks the page to bring it into view (`shellRevealed`).
            .environment(\.pageReveal, PageReveal { id, anchor, animation in
                withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) }
            })
        }
    }
}

/// Brings a part of the page into view, by its ID.
struct PageReveal {
    /// With no anchor the page moves the least that shows the view.
    var scroll: (_ id: String, _ anchor: UnitPoint?, _ animation: Animation?) -> Void = { _, _, _ in }
}

private struct PageRevealKey: EnvironmentKey {
    static var defaultValue: PageReveal { PageReveal() }
}

extension EnvironmentValues {
    /// The page's own scroll, for a view that opens in answer to a press and may be below the fold.
    var pageReveal: PageReveal {
        get { self[PageRevealKey.self] }
        set { self[PageRevealKey.self] = newValue }
    }
}

/// Scrolls the page until this view shows, once, when it appears: a confirmation or a form that
/// opened in answer to a press. Eased, or at once with Reduce Motion.
private struct ShellRevealed: ViewModifier {
    @Environment(\.pageReveal) private var reveal
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    var anchor: UnitPoint? = nil

    func body(content: Content) -> some View {
        content.id(id).onAppear {
            // After this layout pass, so the view has its place in the page.
            DispatchQueue.main.async { reveal.scroll(id, anchor, reduceMotion ? nil : theme.motion.animation(theme.motion.standard)) }
        }
    }
}

extension View {
    /// `anchor` puts that edge of a view taller than the window at the same edge of the page.
    func shellRevealed(_ id: String, anchor: UnitPoint? = nil) -> some View { modifier(ShellRevealed(id: id, anchor: anchor)) }
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
