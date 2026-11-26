import SwiftUI

// ATOMIC LEVEL: Molecules and organisms (main-window shell, navigation template C).
// Needs you first: the combined inbox is pinned at the top with its total, the queues it stands in
// for are left out of the list, the groups under the workspace fold, and the person's profile and
// presence sit in the footer.
//
//   ShellInboxCell         the pinned inbox: mark, name, one line of where requests come from, total
//   ShellNeedsYouSidebar   ShellInboxCell + ShellPlaceList + footer places + ShellProfileRow

/// The pinned inbox. While something waits it is tinted in the attention role and shows the total
/// as a figure; with nothing waiting it says so beside a lit lamp.
struct ShellInboxCell: View {
    @Environment(\.theme) private var theme
    let item: CommanderNavigation.Item
    var summary: String? = nil
    let select: (String) -> Void

    private var isWaiting: Bool { item.place.count > 0 }

    var body: some View {
        let shape = theme.rowShape
        Button { select(item.place.id) } label: {
            HStack(alignment: .center, spacing: Space.s + 1) {
                ShellPlaceMark(mark: item.place.mark, isSelected: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.place.title).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                    if isWaiting {
                        if let summary {
                            Text(summary).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(spacing: Space.xs + 1) {
                            MultiplayerLamp(kind: .on, size: 8)
                            Text("Nothing is waiting for you").themeType(theme.type.sub)
                                .foregroundStyle(.theme(\.color.secondary)).lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: Space.xs)
                if isWaiting {
                    Text("\(item.place.count)")
                        .themeType(theme.type.figure)
                        .monospacedDigit()
                        .foregroundStyle(.theme(\.color.attention))
                        .contentTransition(.numericText())
                        .animation(theme.motion.animation(theme.motion.standard), value: item.place.count)
                }
            }
            .padding(.horizontal, Space.s + 1)
            .padding(.vertical, Space.s + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isWaiting, !item.isSelected { shape.fill(theme.surface.attentionFill.color) }
            }
            .overlay {
                if !item.isSelected {
                    if isWaiting {
                        shape.strokeBorder(.theme(\.surface.attentionEdge), lineWidth: theme.line.hairline)
                    } else {
                        shape.strokeBorder(.theme(\.color.hair), lineWidth: theme.line.hairline)
                    }
                }
            }
        }
        .buttonStyle(ShellRowButtonStyle(isSelected: item.isSelected))
        .shellShortcut(item.shortcut)
        .help(item.shortcut.map { "\(item.place.title) (⌘\($0))" } ?? item.place.title)
        .accessibilityLabel(isWaiting ? "\(item.place.title), \(item.place.count) waiting" : "\(item.place.title). Nothing is waiting for you")
        .accessibilityValue(item.isSelected ? "Selected" : "")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityIdentifier("shell-inbox")
    }
}

/// Navigation template C: the inbox first, then the workspace and folding groups, then the person.
struct ShellNeedsYouSidebar: View {
    @Environment(\.theme) private var theme
    let navigation: CommanderNavigation
    let act: (CommanderNavigationAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellBrandHeader()
                .padding(.horizontal, Space.s + 1)
                .padding(.bottom, theme.space.sectionGap - Space.xs)
            if let inbox = navigation.inboxItem {
                ShellInboxCell(item: inbox, summary: navigation.inbox?.summary) { act(.select($0)) }
                    .padding(.bottom, theme.space.sectionGap - Space.xs)
            }
            ScrollView(.vertical) {
                ShellPlaceList(sections: navigation.sections(pinningInbox: true), act: act)
            }
            .scrollIndicators(.never)
            Spacer(minLength: Space.s)
            ShellSidebarFooter(items: navigation.footerItems, act: act)
            if let profile = navigation.profile {
                ThemeRule().padding(.top, Space.s - 2)
                ShellProfileRow(profile: profile) { act(.setPresence($0)) }
            }
        }
        .padding(.top, theme.space.bandTop + Space.xs)
        .padding(.horizontal, theme.navigationInset)
        .padding(.bottom, theme.space.bandBottom - Space.xs)
        .frame(width: ShellLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .shellSidebarSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }
}
