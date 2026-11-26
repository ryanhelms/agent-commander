import SwiftUI

// ATOMIC LEVEL: Organisms (main-window shell, navigation template A).
// The grouped sidebar: every place in one list, under workspace, projects, network and teams.
// Presence and server health are not here; the shell puts them in the toolbar.
//
//   ShellPlaceList       groups of place rows, shared by all three navigation templates
//   ShellSidebarGrouped  heading + ShellPlaceList + footer places

extension Theme {
    /// Space between the navigation surface's edge and its rows.
    var navigationInset: CGFloat { navigationFloats ? ShellLayout.floatingInset : ShellLayout.dockedInset }
}

/// Groups of places: a heading, then the group's rows. A docked sidebar rules its groups off with
/// hairlines; a floating one separates them with space.
struct ShellPlaceList: View {
    @Environment(\.theme) private var theme
    let sections: [CommanderNavigation.Section]
    /// A heading that would repeat the title above the list is left out.
    var omittedTitle: String? = nil
    let act: (CommanderNavigationAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    if theme.navigationFloats {
                        Color.clear.frame(height: theme.space.sectionGap - Space.s)
                    } else {
                        ThemeRule().padding(.vertical, Space.s)
                    }
                }
                if section.group.title != omittedTitle {
                    ShellGroupHeading(title: section.group.title,
                                      count: section.isCollapsed ? section.hotCount : 0,
                                      isCollapsed: section.group.isCollapsible ? section.isCollapsed : nil,
                                      toggle: { act(.toggleGroup(section.group.id)) })
                        .padding(.bottom, Space.xs)
                }
                if !section.isCollapsed {
                    VStack(spacing: 2) {
                        ForEach(section.items) { item in
                            ShellPlaceRow(item: item) { act(.select($0)) }
                        }
                    }
                }
            }
        }
        .animation(theme.motion.animation(theme.motion.standard), value: sections.map(\.isCollapsed))
    }
}

/// Navigation template A: one grouped list of every place.
struct ShellSidebarGrouped: View {
    @Environment(\.theme) private var theme
    let navigation: CommanderNavigation
    let act: (CommanderNavigationAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellBrandHeader()
                .padding(.horizontal, Space.s + 1)
                .padding(.bottom, theme.space.sectionGap - Space.xs)
            ScrollView(.vertical) {
                ShellPlaceList(sections: navigation.sections(pinningInbox: false, folding: false), act: act)
            }
            .scrollIndicators(.never)
            Spacer(minLength: Space.s)
            ShellSidebarFooter(items: navigation.footerItems, act: act)
        }
        .padding(.top, theme.space.bandTop + Space.xs)
        .padding(.horizontal, theme.navigationInset)
        .padding(.bottom, theme.space.bandBottom)
        .frame(width: ShellLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .shellSidebarSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }
}

/// The places pinned to the foot of a list sidebar, under a hairline.
struct ShellSidebarFooter: View {
    let items: [CommanderNavigation.Item]
    let act: (CommanderNavigationAction) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 2) {
                ThemeRule().padding(.bottom, Space.s - 2)
                ForEach(items) { item in
                    ShellPlaceRow(item: item) { act(.select($0)) }
                }
            }
        }
    }
}
