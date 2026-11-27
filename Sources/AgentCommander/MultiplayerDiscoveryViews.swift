import SwiftUI

// RELAYS NEARBY (design/COMMANDER-NETWORK-DISCOVERY.md, "The tray"; DESIGN.md, "Relays nearby").
// The band at the top of the Network tab and of Add server, and the join checklist under the
// relay that is chosen. Every view here takes values and emits one targeted action; the discovery
// model (MultiplayerDiscovery.swift) owns the verbs.
//
// ATOMIC LEVELS in this file:
//   atoms      reused: MultiplayerMark, MultiplayerBadge, MultiplayerLamp, MultiplayerStepMark,
//              MultiplayerFingerprintText, MultiplayerSpinner, the tray button and switch styles
//   molecules  reused: MultiplayerRelayRow (MultiplayerTailnet.swift), MultiplayerProbeStepRow,
//              MultiplayerWell, MultiplayerBandHeading, MultiplayerStateLabel,
//              MultiplayerRequestAccess (MultiplayerMembershipRequests.swift)
//              new: MultiplayerJoinChecklistView
//   organism   MultiplayerRelaysNearbyBand

// MARK: - Row values

extension MultiplayerDiscoveredRelay {
    /// Where the relay stands, as its row's lamp and word.
    var rowState: (lamp: MultiplayerLamp.Kind, text: String, tone: Tone) {
        switch step {
        case .unreachable, .unknown: (.off, "Unreachable", .neutral)
        case .confirm: (.waiting, "Confirm to join", .attention)
        case .add: (.on, "Ready to join", .working)
        case .signIn: (.waiting, "Sign in", .focus)
        case .done: (.on, "Joined", .working)
        }
    }

    /// The row's state once the relay turned the sign-in away: where the request to join stands.
    static func rowState(asked request: MultiplayerMembershipRequestStatus) -> (lamp: MultiplayerLamp.Kind, text: String, tone: Tone) {
        switch request.phase {
        case .requestable: (.waiting, "Request access", .attention)
        case .sending: (.waiting, "Sending…", .focus)
        case .pending, .denied, .full: (request.lamp, request.title ?? "", request.tone)
        case .approved: (.waiting, "Sign in", .focus)
        }
    }

    /// New, then how the relay admits people.
    var rowTags: [MultiplayerRelayRow.Tag] {
        var tags: [MultiplayerRelayRow.Tag] = []
        if isNew { tags.append(.init(text: "New", tone: .focus)) }
        if let title = membership.title { tags.append(.init(text: title)) }
        return tags
    }
}

extension MultiplayerRelayRow {
    /// A relay found nearby, in the Relays nearby band. Choosing it opens its join checklist.
    init(relay: MultiplayerDiscoveredRelay, isChosen: Bool, request: MultiplayerMembershipRequestStatus? = nil,
         onChoose: @escaping () -> Void) {
        let state = request.map(MultiplayerDiscoveredRelay.rowState(asked:)) ?? relay.rowState
        let unreachable = relay.step == .unreachable
        self.init(name: relay.displayName, address: relay.host, source: relay.source.title, tags: relay.rowTags,
                  lamp: state.lamp, state: state.text, tone: state.tone,
                  isDimmed: unreachable, note: unreachable ? relay.unreachableReason : nil,
                  isChosen: isChosen, isEnabled: true,
                  help: isChosen ? "Hide the steps to join \(relay.displayName)" : "Show the steps to join \(relay.displayName)",
                  hint: isChosen ? "Hides the steps to join this relay" : "Shows the steps to join this relay",
                  onChoose: onChoose)
    }
}

// MARK: - Molecule

/// The four steps to join one relay, each with its mark and what was found. The step the
/// checklist stands at carries the one action; the line under the steps names what is left.
struct MultiplayerJoinChecklistView: View {
    let checklist: MultiplayerJoinChecklist
    /// Whether an action can start now.
    let canAct: Bool
    /// The checklist's action is the page's primary action. Add server keeps Save server as its own.
    var isProminent = true
    let onConfirm: () -> Void
    let onSignIn: () -> Void
    let onOpenServer: (String) -> Void
    /// Nil where the Join a tailnet form is already on the page.
    var onJoinTailnet: (() -> Void)? = nil
    /// The note that goes with Request access, and the instant its ages are measured from.
    var note: Binding<String> = .constant("")
    var now = Date()
    var onRequestAccess: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(checklist.steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                MultiplayerProbeStepRow(number: index + 1, title: step.stage.title, passed: step.mark.passed,
                                        detail: step.detail) {
                    extra(for: step)
                }
            }
            Text(checklist.hint)
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xs)
        }
    }

    @ViewBuilder private func extra(for step: MultiplayerJoinChecklist.Step) -> some View {
        if step.stage == .certificate, let fingerprint = checklist.fingerprint {
            MultiplayerWell {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("SHA-256 fingerprint to pin")
                        .font(MultiplayerTheme.sub)
                        .foregroundStyle(.inkSecondary)
                    MultiplayerFingerprintText(fingerprint: fingerprint)
                    if let matches = checklist.advertisedMatches {
                        // A hint from an untrusted record: it informs the check, it never replaces it.
                        Text(matches ? "The relay advertises the same fingerprint on the local network. That is a hint, not proof."
                                     : "The relay advertises a different fingerprint on the local network. Don’t confirm until its admin has checked.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(matches ? MultiplayerTheme.secondary : MultiplayerTheme.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, Space.xs)
        }
        if step.stage == .signIn, checklist.offersSignInAgain {
            Button("Sign in again", action: onSignIn)
                .buttonStyle(MultiplayerTrayButtonStyle())
                .disabled(!canAct)
                .accessibilityHint("Opens your browser to sign in, with this or another account")
                .padding(.top, Space.xs)
        }
        if step.stage == .membership, let request = checklist.request {
            // The step's own line says where the request stands; this adds its state and the form.
            MultiplayerRequestAccess(status: request, contact: checklist.contact, now: now, note: note, canAct: canAct,
                                     isProminent: isProminent, showsDetail: false, onRequest: onRequestAccess)
                .padding(.top, Space.xs)
        }
        if step.stage == checklist.action?.stage { action }
    }

    @ViewBuilder private var action: some View {
        switch checklist.action {
        case .joinTailnet:
            if let onJoinTailnet {
                button(MultiplayerJoinChecklist.Action.joinTailnet.title, hint: "Opens Add server, where you can join a tailnet",
                       perform: onJoinTailnet)
            } else {
                Text("Use the Tailnet section below to join one.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .confirmFingerprint:
            button(MultiplayerJoinChecklist.Action.confirmFingerprint.title,
                   hint: "Pins this certificate and adds the relay to your servers", perform: onConfirm)
        case .signIn:
            button(MultiplayerJoinChecklist.Action.signIn.title, hint: "Opens your browser to sign in", perform: onSignIn)
        case .requestAccess:
            // MultiplayerRequestAccess holds the button, under the note it sends.
            EmptyView()
        case .openServer(let id):
            Button(MultiplayerJoinChecklist.Action.openServer(id).title) { onOpenServer(id) }
                .buttonStyle(MultiplayerTrayButtonStyle())
                .padding(.top, Space.xs)
        case nil:
            EmptyView()
        }
    }

    private func button(_ title: String, hint: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(MultiplayerTrayButtonStyle(role: isProminent ? .primary : .standard))
            .disabled(!canAct)
            .accessibilityHint(hint)
            .padding(.top, Space.xs)
    }
}

// MARK: - Organism

/// Relays nearby: every relay this Mac found that isn't in the server list yet, and the join
/// checklist under the one that is chosen. On the Network tab it also holds the switch for
/// notifications about new relays.
struct MultiplayerRelaysNearbyBand: View {
    let relays: [MultiplayerDiscoveredRelay]
    /// The relay whose checklist is open, with that checklist.
    let selected: String?
    let checklist: MultiplayerJoinChecklist?
    let hasLoaded: Bool
    let isReading: Bool
    let failure: String?
    let canAct: Bool
    /// "Notify me about relays nearby", where the band offers it.
    var notifies: Binding<Bool>? = nil
    var isProminent = true
    /// The note for the chosen relay's Request access, and the instant ages are measured from.
    var note: Binding<String> = .constant("")
    var now = Date()
    /// A listed relay's request to join, once it is in the server list and turned the sign-in away.
    var request: (MultiplayerDiscoveredRelay) -> MultiplayerMembershipRequestStatus? = { _ in nil }
    let onSelect: (String) -> Void
    let onConfirm: (MultiplayerDiscoveredRelay) -> Void
    let onSignIn: (MultiplayerDiscoveredRelay) -> Void
    let onOpenServer: (String) -> Void
    var onJoinTailnet: (() -> Void)? = nil
    var onRequestAccess: (MultiplayerDiscoveredRelay) -> Void = { _ in }
    @Environment(\.theme) private var theme

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Relays nearby", count: relays.isEmpty ? nil : "\(relays.count)") {
                    if isReading, relays.isEmpty { MultiplayerSpinner().accessibilityLabel("Looking for relays") }
                }
                if relays.isEmpty {
                    if let failure {
                        Text(failure)
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(MultiplayerTheme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        note(hasLoaded ? "No relays nearby. One shows here when it advertises on your tailnet or your local network."
                                       : "Looking on your tailnet and your local network…")
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(relays.enumerated()), id: \.element.id) { index, relay in
                            if index > 0 {
                                Rectangle().fill(MultiplayerTheme.hair).frame(height: 1).padding(.horizontal, Space.s)
                            }
                            MultiplayerRelayRow(relay: relay, isChosen: relay.id == selected, request: request(relay)) { onSelect(relay.id) }
                            if relay.id == selected, let checklist {
                                MultiplayerJoinChecklistView(checklist: checklist, canAct: canAct, isProminent: isProminent,
                                                             onConfirm: { onConfirm(relay) }, onSignIn: { onSignIn(relay) },
                                                             onOpenServer: onOpenServer, onJoinTailnet: onJoinTailnet,
                                                             note: note, now: now, onRequestAccess: { onRequestAccess(relay) })
                                    .padding(.horizontal, Space.s)
                                    .padding(.bottom, Space.s)
                                    // The chosen row's marker runs on beside its steps.
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(MultiplayerTheme.focus).frame(width: theme.line.selectedMarker)
                                    }
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, -Space.s)
                    .animation(MultiplayerTheme.Motion.ease(), value: selected)
                    if selected == nil { note("Choose a relay to see what joining it takes.") }
                }
                if let notifies {
                    HStack(spacing: Space.s) {
                        Text("Notify me about relays nearby")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                        Toggle("Notify me about relays nearby", isOn: notifies)
                            .toggleStyle(MultiplayerSwitchStyle())
                    }
                    .frame(minHeight: theme.space.controlHeight)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(MultiplayerTheme.sub)
            .foregroundStyle(.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
