import SwiftUI

// ATOMIC LEVEL: Organisms for the grant sheet (DESIGN.md, "Grant sheet").
//   MultiplayerGrantForm  the sheet's fields, wired to the share model's draft
//   MultiplayerGrantHost  the form with its own footer, for a view outside the tray
// The tray shows the form as one of its pages with the tray's footer. Another view presents the
// host in a sheet, a popover or a pane; it needs no tray route and never moves the tray.

/// The grant sheet's fields on the share model's draft. Both the tray and a host draw this.
struct MultiplayerGrantForm: View {
    let model: MultiplayerModel

    var body: some View {
        @Bindable var share = model.share
        let server = share.grantDraft.server
        let status = model.session(server)?.status
        MultiplayerGrantSheet(draft: $share.grantDraft, servers: share.shareServers,
                              friends: status?.friends ?? [], groups: share.teams.ownedGroups(on: server),
                              resources: status?.resources ?? [],
                              resource: share.grantResource, companions: share.grantCompanions,
                              onServer: { share.setGrantServer($0) },
                              onResourceChange: { share.reconcileGrantActions() },
                              onToggle: { share.toggleGrantAction($0) })
    }
}

/// The grant sheet for a view outside the tray. Fill the draft first with
/// `model.share.prepareGrant(on:handle:group:resourceID:actions:)`, then present this.
/// Share sends the grant and reports its result; a refusal stays on the sheet so the person can fix
/// it. The host closes the sheet from `onFinish` when the result is done, and from `onCancel`.
struct MultiplayerGrantHost: View {
    let model: MultiplayerModel
    let onCancel: () -> Void
    let onFinish: (MultiplayerActionResult) -> Void
    @State private var refusal: String?

    var body: some View {
        let share = model.share
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let refusal {
                        MultiplayerBand {
                            MultiplayerBanner(kind: .failure, message: refusal, onDismiss: { self.refusal = nil })
                        }
                    }
                    MultiplayerGrantForm(model: model)
                }
            }
            MultiplayerTrayFooter(note: model.working ?? share.grantHint) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(MultiplayerTrayButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Share") { send() }
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!share.canGrant)
            }
        }
        .background(MultiplayerTheme.panel)
    }

    private func send() {
        refusal = nil
        Task {
            let result = await model.sendGrant()
            refusal = result.reason
            if let reason = result.reason { AccessibilityNotification.Announcement(reason).post() }
            onFinish(result)
        }
    }
}
