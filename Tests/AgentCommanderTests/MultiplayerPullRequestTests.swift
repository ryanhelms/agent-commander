import Foundation
import Synchronization
import Testing
@testable import AgentCommander

// Increment 5 demo defect D9: a pull-request workspace lists its repository's open pull requests.
// Every handle, repository and address here is made up. No test reaches a network, `gh` or the real helper.

@Suite struct MultiplayerPullRequestContractTests {
    static let reply = #"""
    {"workspace":"ws-2","repository":"example/commander-ios","pullRequests":[
      {"number":212,"title":"Add the first-run flow","url":"https://github.com/example/commander-ios/pull/212","author":"fixture-bo","state":"open","branch":"onboarding/first-run"},
      {"number":209,"title":"Remember the last screen","url":"http://github.com/example/commander-ios/pull/209","author":"","state":"open","branch":""},
      {"title":"No number"},{"number":0,"title":"Zero"},7]}
    """#

    @Test func theVerbAndTheReplyAreReadLeniently() throws {
        #expect(MultiplayerVerb.workspacePRs.arguments == ["tray", "workspace-prs"])
        let list = MultiplayerPullRequestList(try MultiplayerLiveFixture.json(Self.reply), workspace: "asked")
        #expect(list.workspace == "ws-2" && list.repository == "example/commander-ios" && !list.isCapped)
        #expect(list.pullRequests.map(\.number) == [212, 209])
        let first = list.pullRequests[0]
        #expect(first.reference == "#212" && first.link?.absoluteString == "https://github.com/example/commander-ios/pull/212")
        #expect(first.spoken == "Pull request 212, Add the first-run flow, branch onboarding/first-run, by fixture-bo")
        // Only an https address is opened.
        #expect(list.pullRequests[1].link == nil && list.pullRequests[1].spoken == "Pull request 209, Remember the last screen")
        #expect(MultiplayerPullRequest(number: 1, title: "t", url: "file:///etc/passwd").link == nil)
        #expect(MultiplayerPullRequest(number: 1, title: "t", url: "javascript:alert(1)").link == nil)

        // A reply that names no workspace belongs to the one that was asked for.
        #expect(MultiplayerPullRequestList(.null, workspace: "asked") == MultiplayerPullRequestList(workspace: "asked"))
        let full = MultiplayerPullRequestList(workspace: "w", pullRequests: (1...50).map { MultiplayerPullRequest(number: $0, title: "t") })
        #expect(full.isCapped)
        #expect(MultiplayerPullRequestList.problem("pull requests can only be listed for GitHub repositories, not /Users/me/relay")
                == "Couldn’t list the pull requests. Pull requests can only be listed for GitHub repositories, not /Users/me/relay.")
        #expect(MultiplayerIntegration.pullRequest.explanation.contains("lists the open ones"))
    }
}

@MainActor @Suite struct MultiplayerPullRequestModelTests {
    private let home = MultiplayerTeamsFixture.home

    nonisolated static let workspaces = #"""
    {"workspaces":[
      {"id":"ws-1","owner":"u-ada","group":"grp-1","name":"Reconnect","goal":"Survive renewals","repository":"github.com/example/relay","base":"main","integration":"queue","claims":[]},
      {"id":"ws-2","owner":"u-bo","group":"grp-1","name":"Onboarding","goal":"Ship first run","repository":"github.com/example/commander-ios","base":"develop","integration":"pull_request","claims":[]}]}
    """#

    private func model(_ pullRequests: @escaping @Sendable () -> String) async -> (MultiplayerModel, RoutedMultiplayerHelper) {
        await MultiplayerTeamsFixture.model { call in
            if call.verb == .relay, call.method == "GET", call.path == "/v1/workspaces" { return Self.workspaces }
            if call.verb == .relay, call.method == "GET", call.path == "/v1/workspaces/ws-2/cards" { return #"{"cards":[]}"# }
            return call.verb == .workspacePRs ? pullRequests() : nil
        }
    }

    private func reads(_ helper: RoutedMultiplayerHelper) -> Int { helper.all.filter { $0.verb == .workspacePRs }.count }

    @Test func aPullRequestWorkspaceReadsItsPullRequestsOnlyWhileItsPageIsOpen() async {
        let (model, helper) = await model { MultiplayerPullRequestContractTests.reply }
        let teams = model.share.teams
        #expect(reads(helper) == 0 && teams.pullRequests == .loading)    // nothing is read before the page opens

        // A merge-queue workspace asks for nothing.
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        #expect(reads(helper) == 0)

        model.go(.home)
        model.share.open(.workspace("ws-2"), on: home)
        #expect(teams.pullRequests == .loading)
        await model.settle()
        #expect(reads(helper) == 1)
        #expect(helper.last(.workspacePRs)?.input["workspace"] == .string("ws-2"))
        #expect(helper.last(.workspacePRs)?.input["server"] == .string(home))
        #expect(teams.pullRequests.value?.pullRequests.map(\.number) == [212, 209])
        #expect(teams.pullRequests.value?.repository == "example/commander-ios")

        // The page's Refresh reads again and keeps the list on screen meanwhile.
        model.share.reloadPage()
        #expect(teams.pullRequests.value != nil)
        await model.settle()
        #expect(reads(helper) == 2)
        model.close()
    }

    @Test func aRefusalIsShownAsASentenceAndTryAgainReadsAgain() async {
        let refuse = Mutex(true)
        let (model, helper) = await model {
            refuse.withLock { $0 }
                ? "!gh could not list pull requests for example/commander-ios; check that gh is installed and signed in"
                : #"{"workspace":"ws-2","repository":"example/commander-ios","pullRequests":[]}"#
        }
        let teams = model.share.teams
        model.share.open(.workspace("ws-2"), on: home)
        await model.settle()
        #expect(teams.pullRequests.failure
                == "Couldn’t list the pull requests. Check that gh is installed on this Mac and signed in to GitHub.")
        #expect(teams.cards.value == [])    // the board is read all the same

        refuse.withLock { $0 = false }
        model.share.reloadPage()
        await model.settle()
        #expect(teams.pullRequests.value?.pullRequests.isEmpty == true && reads(helper) == 2)
        model.close()
    }
}

@MainActor @Suite struct MultiplayerPullRequestFixtureTests {
    private var client: MultiplayerClient {
        MultiplayerClient(helper: MultiplayerProcessHelper(executable: MultiplayerRenderTests.fixture)).scoped(to: "s-fixture-home")
    }

    @Test func theReviewFixtureAnswersWorkspacePRs() async throws {
        let list = try await client.pullRequests(in: "ws-ios")
        #expect(list.workspace == "ws-ios" && list.repository == "example/commander-ios")
        #expect(list.pullRequests.map(\.number) == [212, 209, 207])
        #expect(list.pullRequests[0].link?.absoluteString == "https://github.com/example/commander-ios/pull/212")
        #expect(list.pullRequests.allSatisfy { $0.state == "open" && !$0.branch.isEmpty && !$0.author.isEmpty })

        await #expect(throws: MultiplayerFailure.rejected("unknown workspace ws-none")) { _ = try await client.pullRequests(in: "ws-none") }
    }
}
