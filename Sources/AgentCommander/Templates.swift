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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
                if reduceTransparency {
                    Palette.window
                } else {
                    LinearGradient(colors: [Palette.canvasTop, Palette.canvasMid, Palette.canvasBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
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
            if !reduceTransparency {
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.containerBackground(Palette.opaqueChrome, for: .window)
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

// MARK: - TaskSheet

/// A task page: heading, a form beside an aside, and a footer that stays pinned. The aside drops
/// below the form when the canvas is narrow.
struct TaskSheet<Header: View, FormContent: View, Aside: View, Footer: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let form: FormContent
    @ViewBuilder let aside: Aside
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let wide = geo.size.width >= 2 * Metric.sheetInset + Metric.sheetAsideWidth + 30 + 420
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 27) {
                        header
                        if wide {
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
                    .padding(.top, 30)
                    .padding(.horizontal, Metric.sheetInset)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Hairline()
            footer
                .padding(.horizontal, Metric.sheetInset)
                .frame(maxWidth: .infinity, minHeight: Metric.sheetFooterHeight, maxHeight: Metric.sheetFooterHeight)
        }
    }
}
