import SwiftUI

// ATOMIC LEVEL: The live page (main-window Teams pages).
// The only file that will bind the Teams pages to the Teams model.

/// A Teams place in the live window, until the pages are bound.
struct LiveTeamsPlaceholder: View {
    let place: String
    let crumbs: [String]
    let title: String
    var openPanel: (() -> Void)? = nil

    var body: some View {
        ShellPlaceholderPage(crumbs: crumbs, title: title, note: "This page is not bound yet.",
                             actionTitle: openPanel == nil ? nil : "Open network panel", action: { openPanel?() })
    }
}
