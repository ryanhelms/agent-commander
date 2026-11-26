import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// Answers a view outside the tray can await: decline, per-request results, the hosted grant sheet
// and a friend request's arrival time.

@Suite struct MultiplayerActionContractTests {
    @Test func declineNamesTheHandle() {
        #expect(MultiplayerVerb.decline.arguments == ["tray", "decline"])
        let command = MultiplayerCommand.decline(handle: "fixture-dee")
        #expect(command.verb == .decline && command.payload == ["handle": "fixture-dee"])
        #expect(command.confirmation == "Declined fixture-dee’s friend request.")
        #expect(command.failureTitle == "Couldn’t decline the request.")
    }

    @Test func anIncomingRequestReadsItsArrivalTimeWhenTheRelayGivesOne() throws {
        let status = try #require(try MultiplayerEnvelope.decode(MultiplayerStatus.self, from: MultiplayerFixture.output(#"""
        {"ok":true,"data":{"online":true,"signedIn":true,"handle":"fixture-ada","incoming":[
          {"id":"fixture-bo","handle":"fixture-bo","requestedAt":"2026-11-23T11:55:00Z"},
          {"id":"fixture-cy","handle":"fixture-cy","requestedAt":"2026-11-23T11:59:40.250Z"},
          {"id":"fixture-dee","handle":"fixture-dee"},
          {"id":"fixture-eli","handle":"fixture-eli","requestedAt":""},
          {"id":"fixture-fay","handle":"fixture-fay","requestedAt":7}]}}
        """#)))
        let now = MultiplayerFixtureClock.start
        #expect(status.incoming.map(\.handle) == ["fixture-bo", "fixture-cy", "fixture-dee", "fixture-eli", "fixture-fay"])
        #expect(status.incoming[0].requestedAt == now.addingTimeInterval(-300))
        #expect(status.incoming[1].requestedAt != nil)
        #expect(status.incoming[2...].allSatisfy { $0.requestedAt == nil })

        // Relative to the moment given, not to the wall clock.
        // The system words the span ("5m ago", "5 min. ago"), so the test asks it the same way.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let fiveMinutes = formatter.localizedString(for: now.addingTimeInterval(-300), relativeTo: now)
        #expect(fiveMinutes.contains("5"))
        #expect(status.incoming[0].arrival(now: now) == fiveMinutes)
        #expect(status.incoming[1].arrival(now: now) == "just now")
        #expect(status.incoming[2].arrival(now: now) == nil)
        // A time that hasn't happened yet is not shown.
        #expect(status.incoming[0].arrival(now: now.addingTimeInterval(-3600)) == nil)

        #expect(MultiplayerNeedsYou.friendDetail(status.incoming[0], server: "home", now: now) == "On home, \(fiveMinutes)")
        #expect(MultiplayerNeedsYou.friendDetail(status.incoming[2], server: "home", now: now) == "On home")
    }
}

@MainActor @Suite struct MultiplayerActionModelTests {
    static let refused = MultiplayerFixture.output(#"{"ok":false,"error":"relay HTTP 404: no pending request"}"#)

    @Test func decliningAFriendRequestSendsTheHandleAndReportsThatRequest() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.status: [MultiplayerServerFixture.homeStatus],
                                                                .decline: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let request = try #require(model.friendGroups.first?.incoming.first)
        let result = await model.declineFriend(request, on: "s-home")
        #expect(helper.lastInput(.decline) == ["handle": "fixture-dee", "server": "s-home"])
        #expect(result == .done(id: "in-1", server: "s-home", message: "Declined fixture-dee’s friend request."))
        #expect(result.isDone && result.reason == nil)
        // The tray's own text is unchanged: the server's session still shows the confirmation.
        #expect(model.session("s-home")?.notice == "Declined fixture-dee’s friend request.")
        model.close()
    }

    @Test func theTraysDeclineIsOnePress() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.status: [MultiplayerServerFixture.homeStatus],
                                                                .decline: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let request = try #require(model.friendGroups.first?.incoming.first)
        model.decline(request, on: "s-home")
        await model.settle()
        #expect(helper.count(.decline) == 1)
        model.close()
    }

    @Test func aRefusedAnswerToAFriendRequestSaysWhyAsASentence() async throws {
        let (model, _) = MultiplayerShareModelTests.model([.status: [MultiplayerServerFixture.homeStatus],
                                                           .decline: [Self.refused], .accept: [Self.refused]])
        model.open()
        await model.settle()
        let request = try #require(model.friendGroups.first?.incoming.first)
        let declined = await model.declineFriend(request, on: "s-home")
        #expect(declined == .failed(id: "in-1", server: "s-home", reason: "Couldn’t decline the request. No pending request."))
        let accepted = await model.acceptFriend(request, on: "s-home")
        #expect(accepted == .failed(id: "in-1", server: "s-home", reason: "Couldn’t accept the request. No pending request."))
        #expect(accepted.id == "in-1" && accepted.server == "s-home" && !accepted.isDone && accepted.message == nil)
        // A server with no session is refused before anything is sent.
        let elsewhere = await model.acceptFriend(request, on: "s-nowhere")
        #expect(elsewhere.reason == "Couldn’t accept the request. Sign in to that server first.")
        model.close()
    }

    @Test func acceptingReportsTheNewFriendship() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.status: [MultiplayerServerFixture.homeStatus],
                                                                .accept: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let request = try #require(model.friendGroups.first?.incoming.first)
        let result = await model.acceptFriend(request, on: "s-home")
        #expect(helper.lastInput(.accept) == ["id": "in-1", "server": "s-home"])
        #expect(result == .done(id: "in-1", server: "s-home", message: "You and fixture-dee are now friends."))
        model.close()
    }

    @Test func decidingAnApprovalReportsThatApproval() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.approvals: [MultiplayerShareFixture.approvals],
                                                                .approve: [MultiplayerShareFixture.empty],
                                                                .deny: [MultiplayerFixture.output(#"{"ok":false,"error":"no such request"}"#)]])
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        let denied = await model.decide(pending.item, on: "s-home", approve: false)
        #expect(denied == .failed(id: "ap-1", server: "s-home", reason: "Couldn’t deny the request. No such request."))
        // The tray's banner carries the same sentence.
        #expect(model.failure == denied.reason)
        #expect(model.share.approvals["s-home"]?.count == 1)

        let approved = await model.decide(pending.item, on: "s-home", approve: true)
        #expect(helper.lastInput(.approve) == ["id": "ap-1", "server": "s-home"])
        #expect(approved == .done(id: "ap-1", server: "s-home", message: "Approved. It runs on this Mac now."))
        #expect(model.failure == nil && model.share.approvals["s-home"]?.isEmpty == true)
        model.close()
    }

    @Test func anAnswerThatCannotStartSaysSoAndSendsNothing() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.approvals: [MultiplayerShareFixture.approvals],
                                                                .approve: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let pending = try #require(model.share.pendingApprovals.first)
        let first = try #require(model.share.decide(pending.item, on: "s-home", approve: true))
        let second = await model.decide(pending.item, on: "s-home", approve: false)
        #expect(second == .failed(id: "ap-1", server: "s-home",
                                  reason: "Couldn’t deny the request. Another network action is still running. Try again when it finishes."))
        await first.value
        #expect(helper.count(.deny) == 0 && helper.count(.approve) == 1)
        model.close()
    }

    @Test func removingAnAccessRequestReportsThatRequest() async throws {
        let request = MultiplayerAccessRequest(id: "ar-1", resource: "res-1", owner: "fixture-ada", requester: "fixture-bo",
                                               actions: ["issue.read"])
        let (model, helper) = MultiplayerShareModelTests.model([.relay: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        let declined = await model.remove(request, on: "s-home", declining: true)
        #expect(helper.lastInput(.relay) == ["server": "s-home", "method": "DELETE", "path": "/v1/access-requests/ar-1"])
        #expect(declined == .done(id: "ar-1", server: "s-home", message: "Declined fixture-bo’s request."))
        model.close()

        let (failing, _) = MultiplayerShareModelTests.model([.relay: [Self.refused]])
        failing.open()
        await failing.settle()
        let withdrawn = await failing.remove(request, on: "s-home", declining: false)
        #expect(withdrawn == .failed(id: "ar-1", server: "s-home", reason: "Couldn’t withdraw the request. No pending request."))
        failing.close()
    }

    @Test func aHostedGrantSheetSharesWithoutMovingTheTray() async throws {
        let (model, helper) = MultiplayerShareModelTests.model([.grant: [MultiplayerShareFixture.empty]])
        model.open()
        await model.settle()
        #expect(!model.share.prepareGrant(on: "s-nowhere"))
        #expect(model.share.prepareGrant(on: "s-home", handle: "fixture-bo"))
        #expect(model.route == .home)
        #expect(model.share.grantDraft.server == "s-home" && model.share.grantDraft.resourceID == "res-1")

        // Nothing is sent while the sheet can't be shared, and the reason is the sheet's own hint.
        let early = await model.sendGrant()
        #expect(early == .failed(id: "res-1", server: "s-home", reason: "Couldn’t share it. Choose at least one action."))
        #expect(helper.count(.grant) == 0)

        model.share.toggleGrantAction("git.push")
        let result = await model.sendGrant()
        #expect(helper.count(.grant) == 1)
        #expect(result.isDone && result.id == "res-1" && result.server == "s-home")
        #expect(result.message?.hasPrefix("fixture-bo can use relay until ") == true)
        #expect(model.route == .home && model.share.grantDraft == MultiplayerShareDraft())
        model.close()
    }

    @Test func aRefusedHostedGrantKeepsTheDraft() async throws {
        let (model, _) = MultiplayerShareModelTests.model([.grant: [MultiplayerFixture.output(#"{"ok":false,"error":"not friends"}"#)]])
        model.open()
        await model.settle()
        model.share.prepareGrant(on: "s-home", handle: "fixture-bo", actions: ["git.push"])
        let result = await model.sendGrant()
        #expect(result == .failed(id: "res-1", server: "s-home", reason: "Couldn’t share relay. Not friends."))
        #expect(model.share.grantDraft.handle == "fixture-bo" && model.share.grantDraft.actions == ["git.push"])
        #expect(model.route == .home)

        // The host draws from the same draft with no tray route behind it.
        let host = NSHostingView(rootView: MultiplayerGrantHost(model: model, onCancel: {}, onFinish: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        model.close()
    }
}

/// The review fixture, as a process: the request carries its time and leaves once declined.
@MainActor @Suite struct MultiplayerActionFixtureTests {
    @Test func theFixtureDatesItsFriendRequestAndDropsItWhenDeclined() async throws {
        let model = try await MultiplayerRemoteTests.fixtureModel("decline")
        let home = MultiplayerRemoteTests.home
        let request = try #require(model.friendGroups.first { $0.id == home }?.incoming.first)
        #expect(request.handle == "fixture-priya" && request.id == "fixture-priya")
        let requestedAt = try #require(request.requestedAt)
        #expect(abs(Date().timeIntervalSince(requestedAt) - 720) < 120)
        #expect(model.server(home)?.incoming == 1)

        let result = await model.declineFriend(request, on: home)
        #expect(result == .done(id: "fixture-priya", server: home, message: "Declined fixture-priya’s friend request."))
        model.refreshAll()
        await model.settle()
        #expect(model.friendGroups.first { $0.id == home }?.incoming.isEmpty == true)
        #expect(model.server(home)?.incoming == 0)

        // It is gone, so a second answer is refused with the fixture's reason.
        let again = await model.acceptFriend(request, on: home)
        #expect(again.reason == "Couldn’t accept the request. No pending friend request from fixture-priya.")
        model.close()
    }
}
