import SwiftUI

// ATOMIC LEVEL: Organisms (main-window shell, navigation template B).
// The mode rail with a context list: a narrow rail of icons switches mode, and a second column
// lists every page of that mode. Presence and server health sit in the toolbar.

/// Navigation template B: a rail of modes beside the chosen mode's pages.
struct ShellModeRail: View {
    @Environment(\.theme) private var theme
    let navigation: CommanderNavigation
    /// The keys held with a mode's number. The live window keeps ⌘1 for the coordinator, so its
    /// modes take ⌥⌘1 to ⌥⌘5.
    var modeModifiers: EventModifiers = .command
    /// The context list can be put away to give the canvas its width. The rail stays.
    var showsContext = true
    let act: (CommanderNavigationAction) -> Void

    var body: some View {
        let modes = navigation.modeItems
        let selected = modes.first(where: \.isSelected)
        HStack(spacing: 0) {
            rail(modes)
            if showsContext {
                ThemeRule(vertical: true)
                context(selected)
            }
        }
        .frame(maxHeight: .infinity)
        .shellSidebarSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func rail(_ modes: [CommanderNavigation.ModeItem]) -> some View {
        VStack(spacing: Space.s - 2) {
            ForEach(modes.filter { !$0.mode.isTrailing }) { item in
                ShellModeCell(item: item, modifiers: modeModifiers) { act(.selectMode($0)) }
            }
            Spacer(minLength: Space.s)
            ForEach(modes.filter(\.mode.isTrailing)) { item in
                ShellModeCell(item: item, modifiers: modeModifiers) { act(.selectMode($0)) }
            }
        }
        .padding(.top, theme.space.bandTop + Space.xs)
        .padding(.bottom, theme.space.bandBottom)
        .frame(width: ShellLayout.railWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modes")
    }

    private func context(_ selected: CommanderNavigation.ModeItem?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text(selected?.mode.title ?? "")
                    .themeType(theme.type.title)
                    .foregroundStyle(.theme(\.color.foreground))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let hot = selected?.hotCount, hot > 0 { ShellCount(text: "\(hot)", isHot: true) }
            }
            .padding(.horizontal, Space.s + 1)
            .frame(minHeight: ShellLayout.railCell)
            .padding(.bottom, Space.s)
            ScrollView(.vertical) {
                ShellPlaceList(sections: navigation.contextSections, omittedTitle: selected?.mode.title, act: act)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
        }
        .padding(.top, theme.space.bandTop + Space.xs)
        .padding(.horizontal, theme.navigationInset)
        .padding(.bottom, theme.space.bandBottom)
        .frame(width: ShellLayout.contextWidth)
    }
}
