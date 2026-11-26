import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// Reads and actions a view outside the tray owns: none reads or moves the tray's route, and each
// names its target, so it works whatever page the tray is on.

@MainActor @Suite struct MultiplayerCallerOwnedReadTests {
    static let thread = MultiplayerLiveFixture.ok(#"{"comments":[{"id":"cm-1","author":"fixture-bo","authorKind":"user","at":"2026-11-25T12:00:00Z","text":"Looks right."}]}"#)
    static let audit = MultiplayerLiveFixture.ok(#"{"entries":[{"request":"rq-1","peer":"fixture-bo","resource":"res-1","action":"git.push","outcome":"ok"}]}"#)
    static let handoffs = MultiplayerLiveFixture.ok(#"{"handoffs":[{"request":"rq-1","resource":"dir-1","action":"agent.handoff","title":"Run UI tests","at":"2026-11-25T11:00:00Z","status":"ok","value":{"run":"r-1"}}]}"#)
    static let sent = MultiplayerLiveFixture.ok(#"{"sent":[{"request":"rq-3","child":"","resource":"dir-1","action":"fanout:agent.ask","title":"Where?","at":"2026-11-25T12:00:00Z","status":"ok","value":{"text":"Client."}}]}"#)

    @Test func aCallerOwnedReadLeavesTheRouteAndTheTraysOwnPagesAlone() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.thread: [Self.thread], .audit: [Self.audit],
                                                                .handoffs: [Self.handoffs], .sent: [Self.sent]])
        model.open()
        await model.settle()
        // The tray is somewhere else entirely, and stays there.
        model.go(.hosting)
        let share = model.share

        let thread = await share.loadThread("rq-1", on: "s-home")
        #expect(thread.value?.comments.map(\.text) == ["Looks right."])
        #expect(helper.lastInput(.thread) == ["request": "rq-1", "server": "s-home"])
        #expect(share.thread == .loading)    // the tray's own thread page was never filled

        let audit = await share.loadAudit("res-1", on: "s-home")
        #expect(audit.value?.map(\.request) == ["rq-1"])
        #expect(helper.lastInput(.audit) == ["resource": "res-1", "server": "s-home"])
        #expect(share.audit == .loading)
        let everything = await share.loadAudit(on: "s-home")
        #expect(everything.value?.count == 1 && helper.lastInput(.audit) == ["server": "s-home"])

        let handoff = await share.loadHandoff("rq-1", on: "s-home")
        #expect(handoff.value?.title == "Run UI tests" && handoff.value?.run == "r-1")
        let missing = await share.loadHandoff("rq-9", on: "s-home")
        #expect(missing == .failed("Commander can’t find this hand-off any more."))

        let fanout = await share.live.loadFanout("rq-3", on: "s-home")
        #expect(fanout.value?.title == "Where?" && fanout.value?.children.map(\.resource) == ["dir-1"])
        let gone = await share.live.loadFanout("rq-9", on: "s-home")
        #expect(gone.failure == "Commander can’t find this fan-out any more.")

        #expect(model.route == .hosting)
        model.close()
    }

    @Test func aFailedReadSaysWhyAndStillLeavesTheRoute() async throws {
        let refused = MultiplayerFixture.output(#"{"ok":false,"error":"relay HTTP 403: not your request"}"#)
        let (model, _) = MultiplayerShareModelTests.model([.thread: [refused], .audit: [refused]])
        model.open()
        await model.settle()
        let thread = await model.share.loadThread("rq-1", on: "s-home")
        #expect(thread.value == nil && thread.failure?.isEmpty == false)
        let audit = await model.share.loadAudit(on: "s-home")
        #expect(audit.failure == thread.failure)
        #expect(model.route == .home)
        // With no helper, a read says so and sends nothing.
        let offline = MultiplayerModel(client: nil, setupFailure: .launchFailed)
        let none = await offline.share.loadThread("rq-1", on: "s-home")
        #expect(none.failure == MultiplayerFailure.launchFailed.message)
        model.close()
    }

    @Test func theTraysOwnThreadPageUsesTheSameReadAndKeepsItOnTheModel() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.thread: [Self.thread], .comment: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        model.share.open(.thread(request: "rq-1", title: "Run UI tests"), on: "s-home")
        #expect(model.share.thread == .loading)
        await model.settle()
        #expect(model.share.thread.value?.comments.count == 1)
        // A caller's read while the tray's page is open changes neither the page nor the route.
        _ = await model.share.loadThread("rq-2", on: "s-home")
        #expect(model.route == .share("s-home", .thread(request: "rq-1", title: "Run UI tests")))
        // The tray's own comment still posts to its route's request and reads the thread again.
        model.share.commentDraft = "  Thanks.  "
        await model.share.postComment()?.value
        #expect(helper.lastInput(.comment) == ["request": "rq-1", "text": "Thanks.", "server": "s-home"])
        #expect(model.share.commentDraft.isEmpty && helper.lastInput(.thread)?["request"] == "rq-1")
        model.close()
    }

    @Test func aCertificateCheckAndAMembershipReadAreTheCallersOwn() async throws {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home, MultiplayerServerFixture.team)],
            .status: [MultiplayerServerFixture.homeStatus],
            .serverProbe: [MultiplayerServerFixture.probe(pin: MultiplayerServerFixture.newPin)],
            .membership: [MultiplayerFixture.output(#"{"ok":true,"data":{"mode":"allowlist","allowedEmails":["a@example.test"],"admins":["b@example.test"],"memberCount":2}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        let team = try #require(model.server("s-team"))
        let check = await model.checkCertificate(of: team)
        #expect(check.value?.step(.tls)?.pin == MultiplayerServerFixture.newPin)
        #expect(helper.lastInput(.serverProbe) == ["url": "https://team.example"])
        // The tray's own check is untouched, and so is its route.
        #expect(model.probe == .idle && model.route == .home && model.presentedProbe(for: team) == .idle)
        // An address the helper could never read is refused before anything is sent.
        let bad = await model.checkServer(at: "ftp://nope")
        #expect(bad.failure == "Use https, or leave the scheme out." && helper.count(.serverProbe) == 1)

        let membership = await model.loadMembership(on: "s-home")
        #expect(membership.value?.mode == "allowlist")
        #expect(model.membership == .loading && model.route == .home)
        model.close()
    }

    @Test func aCallerOwnedWatchReadsWithoutATrayPage() async throws {
        let first = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[{"kind":"message","text":"one"}],"cursor":"1","state":"running"}}"#)
        let second = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[{"kind":"message","text":"two"}],"cursor":"2","state":"running"}}"#)
        let idle = MultiplayerLiveFixture.ok(#"{"status":"ok","value":{"events":[],"cursor":"","state":"running"}}"#)
        let (model, helper) = MultiplayerLiveFixture.model([.watch: [first, second, idle]])
        model.open()
        await model.settle()
        let stream = model.share.live.stream("dir-1", on: "s-home")
        stream.begin()
        #expect(await MultiplayerLiveFixture.eventually { stream.state.events.count == 2 })
        #expect(stream.state.events.map(\.text) == ["one", "two"] && stream.state.phase == .live)
        // The tray never opened its watch page, and its own stream is empty.
        #expect(model.route == .home && model.share.live.watch.events.isEmpty)
        stream.end()
        let polls = helper.count(.watch)
        try await Task.sleep(for: .milliseconds(60))
        #expect(helper.count(.watch) == polls && stream.task == nil)
        model.close()
    }
}

@MainActor @Suite struct MultiplayerExplicitActionTests {
    @Test func aCommentAnAccessRequestAndARenameWorkWhileTheTrayIsElsewhere() async throws {
        let renamed = MultiplayerServerFixture.server("s-home", name: "harbor", favorite: true, state: "online",
                                                      pin: MultiplayerServerFixture.pin, signedIn: true)
        let (model, helper) = MultiplayerShareModelTests.model([.comment: [MultiplayerShareFixture.empty],
                                                                .relay: [MultiplayerShareFixture.empty],
                                                                .serverUpdate: [MultiplayerLiveFixture.ok(renamed)]])
        model.open()
        await model.settle()
        model.go(.hosting)

        let comment = await model.postComment("  Thanks.  ", to: "rq-1", on: "s-home")
        #expect(comment == .done(id: "rq-1", server: "s-home", message: nil))
        #expect(helper.lastInput(.comment) == ["request": "rq-1", "text": "Thanks.", "server": "s-home"])
        let blank = await model.postComment("   ", to: "rq-1", on: "s-home")
        #expect(blank.reason == "Couldn’t post the comment. Write a comment first." && helper.count(.comment) == 1)

        var draft = MultiplayerAccessDraft()
        let unchosen = await model.sendAccessRequest(draft, for: "dir-2", on: "s-home")
        #expect(unchosen.reason == "Couldn’t send the request. Choose at least one action.")
        draft.actions = ["issue.read"]
        let asked = await model.sendAccessRequest(draft, for: "dir-2", on: "s-home")
        #expect(asked.isDone && asked.id == "dir-2")
        #expect(asked.message == "Request sent. fixture-cy decides whether to share cy-docs.")
        let unknown = await model.sendAccessRequest(draft, for: "dir-9", on: "s-home")
        #expect(unknown.reason == "Couldn’t send the request. That resource is no longer in the shared directory.")
        // The tray's own form was never involved.
        #expect(model.share.accessDraft == MultiplayerAccessDraft())

        let home = try #require(model.server("s-home"))
        let same = await model.rename(home, to: " home ")
        #expect(same.reason == "Couldn’t rename the server. That is already its name." && helper.count(.serverUpdate) == 0)
        let done = await model.rename(home, to: " harbor ")
        #expect(done == .done(id: "s-home", server: "s-home", message: nil))
        #expect(helper.lastInput(.serverUpdate) == ["server": "s-home", "name": "harbor"])

        #expect(model.route == .hosting)
        model.close()
    }

    @Test func theTraysRouteBoundCallsStillRefuseOffTheirPage() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.comment: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        model.share.commentDraft = "Thanks."
        #expect(model.share.postComment() == nil && model.share.sendAccessRequest() == nil)
        #expect(model.share.live.sendFanout() == nil && model.share.live.confirmPost() == nil)
        #expect(model.rename() == nil && model.saveProfile() == nil)
        #expect(helper.count(.comment) == 0)
        model.close()
    }

    @Test func aFanoutAReviewAndItsPostNameTheirTargets() async throws {
        let fanout = #"{"request":"rq-3","children":{"id":"rq-3","children":[{"id":"c-1","resource":"dir-1","action":"agent.ask","status":"ok","result":{"text":"Client."}},{"id":"c-2","resource":"dir-2","action":"agent.ask","status":"pending"}]}}"#
        let review = #"{"request":"rq-7","id":"c-7","status":"ok","value":\#(MultiplayerLiveFixture.review)}"#
        let (model, helper) = MultiplayerLiveFixture.model([
            .fanout: [MultiplayerLiveFixture.ok(fanout)],
            .send: [MultiplayerLiveFixture.ok(review)],
            .reviewPost: [MultiplayerLiveFixture.ok(#"{"posted":"https://example.test/a/b/pull/4"}"#)]])
        model.open()
        await model.settle()
        model.go(.addServer)
        let live = model.share.live

        var draft = MultiplayerFanoutDraft(targets: ["dir-1"], prompt: "Where?")
        let few = await model.sendFanout(draft, on: "s-home")
        #expect(few.reason == "Couldn’t send the fan-out. Choose at least 2 workers and write a prompt.")
        draft.targets = ["dir-1", "dir-2"]
        let sent = await model.sendFanout(draft, on: "s-home")
        #expect(sent == .done(id: "rq-3", server: "s-home", message: nil))
        #expect(live.fanout("rq-3", on: "s-home")?.children.count == 2 && live.fanoutDraft == MultiplayerFanoutDraft())

        var request = MultiplayerReviewDraft()
        request.title = "Bound the wait"
        request.pr = "https://example.test/a/b/pull/4"
        let asked = await model.sendReview(request, to: "dir-1", on: "s-home")
        #expect(asked.isDone && asked.id == "rq-7" && asked.message == "bo-agent finished the review.")
        #expect(live.reviewLink("rq-7") == "https://example.test/a/b/pull/4" && live.reviewDraft == MultiplayerReviewDraft())

        let unnamed = await model.postReview("rq-7", on: "s-home", to: " ")
        #expect(unnamed.reason == "Couldn’t post the review. Name the pull request to post to." && helper.count(.reviewPost) == 0)
        let posted = await model.postReview("rq-7", on: "s-home", to: " https://example.test/a/b/pull/4 ")
        #expect(posted == .done(id: "rq-7", server: "s-home",
                                message: "Posted to the pull request as a review comment from your GitHub login."))
        #expect(helper.lastInput(.reviewPost) == ["request": "rq-7", "pr": "https://example.test/a/b/pull/4", "server": "s-home"])
        #expect(live.posted["rq-7"] == "https://example.test/a/b/pull/4" && !live.confirmingPost)

        #expect(model.route == .addServer)
        model.close()
    }

    @Test func aConsultAHandoffAndASuggestionBringBackWhatTheyMade() async throws {
        let consult = MultiplayerLiveFixture.ok(#"{"request":"rq-4","id":"c-4","status":"ok","value":{"text":"In the client."}}"#)
        let handoff = MultiplayerLiveFixture.ok(#"{"request":"rq-5","id":"c-5","status":"ok","value":{"run":"r-5"}}"#)
        let suggestion = MultiplayerLiveFixture.ok(#"{"request":"rq-6","id":"c-6","status":"pending"}"#)
        let (model, helper) = MultiplayerLiveFixture.model([.send: [consult, handoff, suggestion]])
        model.open()
        await model.settle()
        model.go(.hosting)

        let reply = await model.sendConsult(MultiplayerConsultDraft(prompt: "Where is the retry?"), to: "dir-1", on: "s-home")
        #expect(reply.value?.request == "rq-4" && model.share.consultReply == nil)
        let empty = await model.sendConsult(MultiplayerConsultDraft(), to: "dir-1", on: "s-home")
        #expect(empty.failure == "Couldn’t send the prompt. Write a prompt first." && helper.count(.send) == 1)

        let made = await model.sendHandoff(MultiplayerHandoffDraft(title: "Run UI tests", task: "Run them."), to: "dir-1", on: "s-home")
        #expect(made.isDone && made.id == "rq-5" && made.message == "Handed off. bo-agent started a run for it.")
        #expect(model.share.handoff("rq-5", on: "s-home")?.title == "Run UI tests")

        let nudge = await model.sendSuggestion(" Pin the clock. ", to: "dir-1", on: "s-home")
        #expect(nudge.value?.request == "rq-6" && model.share.live.suggestReply == nil)
        #expect(model.notice == "Sent. fixture-bo approves each suggestion before the worker sees it.")

        #expect(model.route == .hosting)
        model.close()
    }

    @Test func aProfileAnInviteAndMembershipAreSavedFromTheCallersDrafts() async throws {
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .status: [MultiplayerServerFixture.homeStatus],
            .me: [MultiplayerFixture.output(#"{"ok":true,"data":{"admin":true,"mode":"allowlist"}}"#)],
            .profile: [MultiplayerShareFixture.empty],
            .inviteCreate: [MultiplayerFixture.output(#"{"ok":true,"data":{"link":"agentcommander://join?server=a.example","code":"c"}}"#)],
            .membershipSet: [MultiplayerFixture.output(#"{"ok":true,"data":{"mode":"invite","allowedEmails":[],"admins":["a@example.test"],"memberCount":1}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        model.go(.hosting)

        var profile = try #require(model.profileDraft(on: "s-home"))
        #expect(profile.handle == "fixture-ada" && !profile.hasChanges)
        let unchanged = await model.saveProfile(profile, on: "s-home")
        #expect(unchanged.reason == "Couldn’t save your profile. Nothing changed yet." && helper.count(.profile) == 0)
        profile.statusMessage = "Reviewing"
        let saved = await model.saveProfile(profile, on: "s-home")
        #expect(saved == .done(id: "s-home", server: "s-home", message: "Profile saved."))
        #expect(helper.count(.profile) == 1 && model.profileDraft == MultiplayerProfileDraft())

        let invite = await model.createInvite(MultiplayerInviteDraft(), on: "s-home")
        #expect(invite.value?.code == "c" && model.invite == nil)

        var membership = MultiplayerMembershipDraft()
        membership.admins = "not-an-address"
        let bad = await model.saveMembership(membership, on: "s-home")
        #expect(bad.failure == "Couldn’t save membership. “not-an-address” isn’t an email address.")
        membership.mode = "invite"
        membership.admins = "a@example.test"
        let kept = await model.saveMembership(membership, on: "s-home")
        #expect(kept.value?.mode == "invite" && model.membership == .loading)

        #expect(model.route == .hosting)
        model.close()
    }

    @Test func aServerIsSavedFromTheCallersDraftAndItsOwnCheck() async throws {
        let added = MultiplayerServerFixture.server("s-lab", name: "lab")
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.home)],
            .status: [MultiplayerServerFixture.homeStatus],
            .serverProbe: [MultiplayerServerFixture.probe()],
            .serverAdd: [MultiplayerLiveFixture.ok(added)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        model.go(.hosting)

        var draft = MultiplayerServerDraft(address: "lab.example:8443")
        let check = try #require(await model.checkServer(at: draft.address).value)
        // The certificate isn't one macOS trusts, so the save waits for the fingerprint check.
        let waiting = await model.saveServer(draft, checked: check)
        #expect(waiting.reason == "Couldn’t save the server. Confirm the fingerprint to finish." && helper.count(.serverAdd) == 0)
        draft.pinConfirmed = true
        let saved = await model.saveServer(draft, checked: check)
        #expect(saved == .done(id: "s-lab", server: "s-lab", message: "Added lab."))
        #expect(helper.lastInput(.serverAdd) == ["url": "lab.example:8443", "pin": MultiplayerServerFixture.pin])
        // The tray's own form and check were never involved, and it did not move.
        #expect(model.serverDraft == MultiplayerServerDraft() && model.probe == .idle && model.route == .hosting)
        model.close()
    }

    @Test func aNewCertificateIsTrustedOnlyWhenAFreshCheckShowsTheConfirmedKey() async throws {
        let trusted = MultiplayerServerFixture.server("s-team", name: "team", pin: MultiplayerServerFixture.newPin)
        let helper = ScriptedMultiplayerHelper([
            .servers: [MultiplayerServerFixture.servers(MultiplayerServerFixture.team)],
            .serverProbe: [MultiplayerServerFixture.probe(pin: MultiplayerServerFixture.newPin)],
            .serverTrust: [MultiplayerLiveFixture.ok(trusted)],
            .status: [MultiplayerFixture.output(#"{"ok":true,"data":{"online":false,"signedIn":false}}"#)],
        ])
        let model = MultiplayerServerFixture.model(helper)
        model.open()
        await model.settle()
        let team = try #require(model.server("s-team"))
        // A key other than the one the server shows now is refused, and so is the pinned one.
        let other = await model.trust(team, confirming: "sha256/other")
        #expect(other.reason == "Couldn’t trust the new certificate. The server no longer shows the certificate you confirmed. Check it again.")
        #expect(helper.count(.serverTrust) == 0)
        let done = await model.trust(team, confirming: MultiplayerServerFixture.newPin)
        #expect(done.isDone && done.message == "team is pinned to its new certificate.")
        #expect(helper.lastInput(.serverTrust) == ["server": "s-team", "pin": MultiplayerServerFixture.newPin])
        #expect(model.route == .home && model.confirmingTrust == nil)
        model.close()
    }

    @Test func aGrantIsRevokedByValueWithoutTheServersPageOrItsConfirmStep() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.revoke: [MultiplayerFixture.ok]])
        model.open()
        await model.settle()
        model.go(.hosting)
        let session = try #require(model.session("s-home"))
        // The server's own page is on another editor, and stays there.
        session.startAddFriend()
        let grant = try #require(session.status?.grants.first)
        let result = await model.revoke(grant, on: "s-home")
        #expect(result == .done(id: "g-1", server: "s-home", message: "Revoked fixture-bo’s access to relay."))
        #expect(helper.lastInput(.revoke) == ["id": "g-1", "server": "s-home"])
        #expect(session.route == .addFriend && model.route == .hosting)

        let refused = MultiplayerFixture.output(#"{"ok":false,"error":"relay HTTP 404: no such grant"}"#)
        let (failing, _) = MultiplayerShareModelTests.model([.revoke: [refused]])
        failing.open()
        await failing.settle()
        let failed = await failing.revoke(grant, on: "s-home")
        #expect(failed == .failed(id: "g-1", server: "s-home", reason: "Couldn’t revoke access. No such grant."))
        let nowhere = await failing.revoke(grant, on: "s-nowhere")
        #expect(nowhere.reason == "Couldn’t revoke access. Sign in to that server first.")
        model.close()
        failing.close()
    }

    @Test func aFriendRequestIsSentOnlyAfterAnExactLookupAndKeepsTheServersPage() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([
            .search: [MultiplayerFixture.output(#"{"ok":true,"data":{"handle":"Fixture-Dee"}}"#),
                      MultiplayerFixture.output(#"{"ok":true,"data":{"handle":"fixture-dee"}}"#)],
            .request: [MultiplayerFixture.ok]])
        model.open()
        await model.settle()
        let session = try #require(model.session("s-home"))
        session.startGrant()
        session.friendDraft = "someone-else"
        let mismatch = await model.sendFriendRequest(to: "fixture-dee", on: "s-home")
        #expect(mismatch.reason == "Couldn’t send the friend request. The network matched a different handle, so nothing was sent. Check the exact spelling.")
        #expect(helper.count(.request) == 0)
        let sent = await model.sendFriendRequest(to: " fixture-dee ", on: "s-home")
        #expect(sent.isDone && sent.id == "fixture-dee" && helper.lastInput(.request)?["handle"] == "fixture-dee")
        // The server's own page keeps its editor, its field and its lookup.
        #expect(session.route == .grant && session.friendDraft == "someone-else" && session.lookup == .idle)
        #expect(model.route == .home)
        model.close()
    }
}

@MainActor @Suite struct MultiplayerHostTests {
    /// Lays a host out off screen and returns the height it asks for.
    static func height<Host: View>(of host: Host, width: CGFloat = MultiplayerLayout.width) -> CGFloat {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: host.frame(width: width))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    /// Whether a host, laid out in an off-screen window, holds a scroll view of its own.
    static func scrolls<Host: View>(_ host: Host) -> Bool {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: host.frame(width: MultiplayerLayout.width, height: 560))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: MultiplayerLayout.width, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        func find(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: find) }
        return find(view)
    }

    @Test func aHostThatDoesNotScrollTakesItsFullHeight() async throws {
        let (model, _) = MultiplayerShareModelTests.model([:])
        model.open()
        await model.settle()
        #expect(model.share.prepareGrant(on: "s-home", handle: "fixture-bo", resourceID: "res-1"))
        // By default the host scrolls its form. Without, it has no scroll view and asks for all of itself.
        #expect(Self.scrolls(MultiplayerGrantHost(model: model, onCancel: {}, onFinish: { _ in })))
        #expect(!Self.scrolls(MultiplayerGrantHost(model: model, scrolls: false, onCancel: {}, onFinish: { _ in })))
        let full = Self.height(of: MultiplayerGrantHost(model: model, scrolls: false, onCancel: {}, onFinish: { _ in }))
        #expect(full > 300)
        let composer = Self.height(of: MultiplayerHandoffHost(model: model, server: "s-home", resource: "dir-1", scrolls: false,
                                                              onCancel: {}, onFinish: { _ in }))
        #expect(composer > 200)
        // Hosting a form never moves the tray.
        #expect(model.route == .home)
        model.close()
    }

    @Test func everyHostDrawsWithoutATrayPage() async throws {
        let (model, _) = MultiplayerShareModelTests.model([:])
        model.open()
        await model.settle()
        model.go(.hosting)
        let cancel = {}, finish: (MultiplayerActionResult) -> Void = { _ in }
        let hosts: [AnyView] = [
            AnyView(MultiplayerConsultHost(model: model, server: "s-home", resource: "dir-1", scrolls: false,
                                           onCancel: cancel, onFinish: finish, onThread: { _ in })),
            AnyView(MultiplayerHandoffHost(model: model, server: "s-home", resource: "dir-1", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerReviewRequestHost(model: model, server: "s-home", resource: "dir-1", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerWatchHost(model: model, server: "s-home", resource: "dir-1", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerAddFriendHost(model: model, server: "s-home", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerInviteHost(model: model, server: "s-home", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerMembershipHost(model: model, server: "s-home", scrolls: false, onCancel: cancel, onFinish: finish)),
            AnyView(MultiplayerAddServerHost(model: model, scrolls: false, onCancel: cancel, onFinish: finish, onOpenExisting: { _ in })),
        ]
        for host in hosts { #expect(Self.height(of: host) > 60) }
        #expect(model.route == .hosting)
        model.close()
    }
}
