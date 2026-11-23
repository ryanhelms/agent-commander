import SwiftUI

// ATOMIC LEVEL: Pages (window scaffold for workspace views).
// WorkspaceScreen puts one canvas page inside the same CockpitShell, NavigationRail and
// WorkspaceToolbar the cockpit uses, so every view in the window shares its chrome.

struct WorkspaceScreen<Canvas: View>: View {
    let crumbs: [String]
    let connection: CockpitModel.Connection
    let navigation: FixtureNavigation
    @Binding var sidebarExpanded: Bool
    /// Workspace search is offered only where a search action exists.
    var search: (@MainActor () -> Void)? = nil
    var toolbarAccessory: AnyView? = nil
    @ViewBuilder let canvas: Canvas

    var body: some View {
        CockpitShell {
            NavigationRail(groups: navigation.groups, footer: navigation.footer, expanded: sidebarExpanded)
        } banners: {
            EmptyView()
        } canvas: {
            canvas
        }
        .toolbar {
            WorkspaceToolbar(sidebarExpanded: $sidebarExpanded, crumbs: crumbs, connection: connection,
                             search: search, accessory: toolbarAccessory)
        }
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
