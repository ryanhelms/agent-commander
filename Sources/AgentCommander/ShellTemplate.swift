import SwiftUI

// ATOMIC LEVEL: Templates (main-window shell).
// Layout only. ShellTemplate places the navigation, the toolbar's leading and trailing content and
// the canvas. It knows nothing about places, servers or requests, and any of the three navigation
// templates fits its navigation slot.
//
//   ShellTemplate       navigation | canvas on the window material, under the toolbar
//   ShellToolbarTitle   the wordmark and the breadcrumb at the toolbar's leading edge (molecule)

/// The app's name and where the person is, for the toolbar's leading edge.
struct ShellToolbarTitle: View {
    @Environment(\.theme) private var theme
    let crumbs: [String]

    var body: some View {
        HStack(spacing: Space.m) {
            Text("Agent Commander").themeType(theme.pageType.control).foregroundStyle(.theme(\.color.foreground))
            if !crumbs.isEmpty {
                ThemeRule(vertical: true).frame(height: theme.space.chipHeightMax)
                HStack(spacing: Space.s - 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: theme.type.label.size - 2, weight: .semibold))
                                .foregroundStyle(.theme(\.surface.quietInk))
                        }
                        Text(crumb)
                            .themeType(theme.pageType.meta)
                            .foregroundStyle(.theme(index == crumbs.count - 1 ? \.color.foreground : \.color.secondary))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, Space.s - 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["Agent Commander"] + crumbs).joined(separator: ", "))
    }
}

/// Where the shell's toolbar content goes.
enum ShellChrome: Sendable {
    /// Items of the window's native toolbar.
    case native
    /// A band drawn above the navigation and canvas, for a view shown without a window.
    case drawn
}

/// Window-level frame for the redesigned main window.
struct ShellTemplate<Navigation: View, Leading: View, Trailing: View, Canvas: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.usesOpaqueSurfaces) private var reduceTransparency
    var chrome = ShellChrome.native
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let toolbarLeading: Leading
    @ViewBuilder let toolbarTrailing: Trailing
    @ViewBuilder let canvas: Canvas

    private var isOpaque: Bool { reduceTransparency || theme.material.window == .opaque }

    var body: some View {
        switch chrome {
        case .native:
            frame
                .toolbar {
                    ToolbarItem(placement: .navigation) { toolbarLeading }
                    ToolbarSpacer(.flexible, placement: .automatic)
                    ToolbarItem(placement: .primaryAction) { toolbarTrailing }
                }
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        case .drawn:
            VStack(spacing: 0) {
                HStack(spacing: Space.m) {
                    toolbarLeading
                    Spacer(minLength: Space.m)
                    toolbarTrailing
                }
                .padding(.leading, ShellLayout.windowControls)
                .padding(.trailing, Space.l)
                .frame(height: Metric.toolbarHeight)
                .background { if !theme.navigationFloats { theme.color.well.color } }
                if !theme.navigationFloats { ThemeRule() }
                frame
            }
            .background(theme.material.windowFill.color)
        }
    }

    private var frame: some View {
        // A floating navigation leaves the canvas a rounded top-leading corner, as the cockpit
        // does. A docked one meets the canvas on a hairline, with square corners.
        let corner = UnevenRoundedRectangle(topLeadingRadius: theme.navigationFloats ? Radius.canvas : 0, style: .continuous)
        return HStack(spacing: 0) {
            navigation
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isOpaque {
                        theme.material.opaqueCanvasFill.color
                    } else {
                        Rectangle().fill(theme.material.canvasFill.style)
                    }
                }
                .clipShape(corner)
                .overlay {
                    if theme.navigationFloats {
                        corner.strokeBorder(.theme(\.surface.panelEdge), lineWidth: theme.line.hairline)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .topLeading, endPoint: .center))
                            .allowsHitTesting(false)
                    }
                }
        }
        .foregroundStyle(.theme(\.color.foreground))
        .background {
            // The cockpit's depth over the window glass, extended under the toolbar band.
            if !isOpaque {
                LinearGradient(colors: [Palette.depthTop, Palette.depthMid, Palette.depthBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .modifier(WindowGlass())
    }
}
