import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Increment 5 demo defects (design/demos/increment-5/demo.md): D4 second presses, D5 error
// sentences, D6 the back button, D7 accessibility, D8 DESIGN.md conformance, plus the merge queue's
// Remove action and extra arguments only where a host's command allows them.

@Suite struct MultiplayerSentenceTests {
    @Test func joinsALeadInAndAReasonAsTwoSentences() {
        let join = MultiplayerSentence.join
        #expect(join("Couldn’t claim it.", "already claimed by fixture-sam/sam-agent")
                == "Couldn’t claim it. Already claimed by fixture-sam/sam-agent.")
        #expect(join("Couldn’t suspend fixture-nobody.", "not found") == "Couldn’t suspend fixture-nobody. Not found.")
        // The transport prefix goes; what the relay said stays.
        #expect(join("Couldn’t claim it.", "relay HTTP 409: overlapping claim held by fixture-bo/bo-agent")
                == "Couldn’t claim it. Overlapping claim held by fixture-bo/bo-agent.")
        #expect(join("Couldn’t add fixture-cy.", "relay HTTP 404") == "Couldn’t add fixture-cy. Relay HTTP 404.")
        // A sentence that is already one is left alone.
        #expect(join("Couldn’t run the command.", "The network helper didn’t answer in time.")
                == "Couldn’t run the command. The network helper didn’t answer in time.")
        #expect(join("Couldn’t save the policy", "Is it “open”?") == "Couldn’t save the policy. Is it “open”?")
        // A handle, a path or a command at the start keeps its case.
        #expect(join("Couldn’t add them.", "fixture-sam isn’t a friend") == "Couldn’t add them. fixture-sam isn’t a friend.")
        #expect(join("Couldn’t queue the branch.", "/tmp/relay is not a checkout") == "Couldn’t queue the branch. /tmp/relay is not a checkout.")
        #expect(join("Couldn’t release the claim.", "  ") == "Couldn’t release the claim.")
    }

    @Test func countsTakeTheSingular() {
        #expect(MultiplayerPlural.count(1, "claim") == "1 claim")
        #expect(MultiplayerPlural.count(0, "claim") == "0 claims")
        #expect(MultiplayerPlural.count(2, "branch", "branches") == "2 branches")
        #expect(MultiplayerHostRun(command: "x", exitCode: 1, seconds: 41).spoken == "Exit 1, 41 seconds")
        #expect(MultiplayerHostRun(command: "x", exitCode: 0, seconds: 1).spoken == "Exit 0, 1 second")
    }

    @Test func aHostsCommandsSayWhetherTheyTakeArguments() throws {
        let published = try JSONDecoder().decode(MultiplayerCapabilities.self, from: Data(#"""
        {"tools":["ui-tests","build"],"environments":["ios-simulator"],
         "commands":[{"name":"ui-tests","allowArgs":true,"environment":"ios-simulator"},{"name":"build"},{"allowArgs":true},7]}
        """#.utf8))
        #expect(published.commandNames == ["ui-tests", "build"])
        #expect(published.allowsArguments("ui-tests") == true && published.allowsArguments("build") == false)
        #expect(published.allowsArguments("unknown") == false)
        #expect(published.command("ui-tests")?.environment == "ios-simulator")

        // An older device publishes only tools: nothing is known, so the owner's Mac decides.
        let older = try JSONDecoder().decode(MultiplayerCapabilities.self, from: Data(#"{"tools":["ui-tests"]}"#.utf8))
        #expect(older.commands == nil && older.commandNames == ["ui-tests"] && older.allowsArguments("ui-tests") == nil)

        let draft = MultiplayerHostRunDraft(command: "build", argumentText: "--only Onboarding")
        #expect(draft.payload(allowingArguments: false) == .object(["command": .string("build")]))
        #expect(draft.payload == .object(["command": .string("build"), "args": .array([.string("--only"), .string("Onboarding")])]))
    }

    @MainActor @Test func theReputationMeterIsTheSixteenCellAtom() {
        #expect(MultiplayerMeter(used: 3, limit: 4, isGood: true).cells == 16)
        #expect(Tone.working.lamp == .on && Tone.attention.lamp == .busy && Tone.failure.lamp == .error && Tone.neutral.lamp == .off)
    }
}

@MainActor @Suite(.serialized) struct MultiplayerIncrement5FixesTests {
    private let home = MultiplayerTeamsFixture.home

    // MARK: D4 and the queue's Remove

    @Test func aQueuedBranchIsRemovedOnlyAfterASecondPress() async {
        let after = #"{"queue":[{"workspace":"ws-1","branch":"collab/b","checkout":"/tmp/relay","test":["swift","test"],"added":"2026-11-25T11:30:00Z","state":"queued"}]}"#
        let (model, helper) = await MultiplayerTeamsFixture.model { call in call.verb == .queueRemove ? after : nil }
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        let merged = teams.queue(for: "ws-1")[0]
        #expect(merged.state == "merged")
        #expect(teams.removeQueued(merged, on: home) == nil && helper.last(.queueRemove) == nil)
        teams.ask(.removeQueued(merged.id))
        await teams.removeQueued(merged, on: home)?.value
        let sent = helper.last(.queueRemove)?.input
        #expect(sent?["server"] == .string(home) && sent?["workspace"] == .string("ws-1") && sent?["branch"] == .string("collab/a"))
        #expect(teams.queue(for: "ws-1").map(\.branch) == ["collab/b"] && teams.confirming == nil)
        #expect(model.notice == "Removed collab/a from the queue. The branch itself is untouched.")
        model.close()
    }

    @Test func aRefusedRemovalSaysWhyInASentence() async {
        let (model, _) = await MultiplayerTeamsFixture.model { call in call.verb == .queueRemove ? "!no queued branch collab/a in that workspace" : nil }
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        let entry = teams.queue(for: "ws-1")[0]
        teams.ask(.removeQueued(entry.id))
        await teams.removeQueued(entry, on: home)?.value
        #expect(model.failure == "Couldn’t remove collab/a from the queue. No queued branch collab/a in that workspace.")
        #expect(teams.queue(for: "ws-1").count == 2)
        model.close()
    }

    @Test func aHeldCardIsReleasedOnlyAfterASecondPressAndReopeningADoneCardIsNot() async {
        let (model, helper) = await MultiplayerTeamsFixture.model()
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        await model.settle()
        let held = teams.card("card-2")!
        #expect(teams.move(held, in: "ws-1", on: home, to: .open) == nil && helper.relays("PUT").isEmpty)
        teams.ask(.releaseCard("card-2"))
        await teams.move(held, in: "ws-1", on: home, to: .open)?.value
        #expect(helper.relays("PUT").last?.path == "/v1/workspaces/ws-1/cards/card-2")
        #expect(helper.relays("PUT").last?.body == .object(["state": .string("open")]) && teams.confirming == nil)
        await teams.move(teams.card("card-3")!, in: "ws-1", on: home, to: .open)?.value
        #expect(helper.relays("PUT").last?.path == "/v1/workspaces/ws-1/cards/card-3")
        model.close()
    }

    @Test func aConfirmationEndsWhenThePageIsLeft() async {
        let (model, _) = await MultiplayerTeamsFixture.model()
        let teams = model.share.teams
        model.share.open(.workspace("ws-1"), on: home)
        teams.ask(.releaseClaim("cl-2"))
        model.share.back()
        #expect(teams.confirming == nil)
        model.close()
    }

    // MARK: Extra arguments

    @Test func extraArgumentsAreSentOnlyToACommandThatAllowsThem() async {
        let status = MultiplayerTeamsFixture.status.replacingOccurrences(
            of: #""capabilities":{"tools":["ui-tests","build"],"environments":["ios-simulator"]}"#,
            with: #""capabilities":{"tools":["ui-tests","build"],"environments":["ios-simulator"],"commands":[{"name":"ui-tests","allowArgs":true,"environment":"ios-simulator"},{"name":"build","allowArgs":false}]}"#)
        #expect(status != MultiplayerTeamsFixture.status)
        let (model, helper) = await MultiplayerTeamsFixture.model { call in
            call.verb == .status ? status
                : call.verb == .send ? #"{"request":"rq-9","status":"ok","value":{"command":"build","exitCode":0,"output":"ok","seconds":3}}"# : nil
        }
        let teams = model.share.teams
        teams.startHostRun("dir-h", on: home)
        teams.hostDraft.command = "ui-tests"
        teams.hostDraft.argumentText = "--only Onboarding"
        #expect(teams.hostAllowsArguments("dir-h", on: home) == true)
        await teams.runOnHost("dir-h", on: home)?.value
        #expect(helper.last(.send)?.input["payload"] == .object(["command": .string("ui-tests"),
                                                                 "args": .array([.string("--only"), .string("Onboarding")])]))
        // The typed arguments stay in the draft, but a command that takes none is sent without them.
        teams.hostDraft.command = "build"
        #expect(teams.hostAllowsArguments("dir-h", on: home) == false)
        await teams.runOnHost("dir-h", on: home)?.value
        #expect(helper.last(.send)?.input["payload"] == .object(["command": .string("build")]))
        // A host that doesn't publish its commands leaves it to the owner's Mac, as before.
        #expect(teams.hostAllowsArguments("dir-g", on: home) == nil)
        model.close()
    }

    // MARK: D6

    @Test func backNamesTheTabOrThePageThePersonCameFrom() async {
        let (model, _) = await MultiplayerTeamsFixture.model()
        let share = model.share
        model.tab = .people
        share.open(.group("grp-1"), on: home)
        #expect(share.backTitle == "People")
        model.go(.home)
        model.tab = .agents
        share.open(.workspace("ws-1"), on: home)
        #expect(share.backTitle == "Agents")
        share.open(.claim(workspace: "ws-1"), on: home)
        #expect(share.backTitle == "Workspace")
        share.back()
        share.back()
        #expect(model.route == .home && model.tab == .agents)
        model.go(.home)
        model.tab = .network
        model.go(.server(home))
        share.open(.groups, on: home)
        #expect(share.backTitle == "home")    // the server's page, by its name
        model.close()
    }

    // MARK: D7

    private func nodes(_ model: MultiplayerModel) async throws -> ([MultiplayerAXNode], String) {
        await model.settle()
        let nodes = try await MultiplayerAX.nodes(of: MultiplayerPanel(model: model))
        return (nodes, nodes.map(\.description).joined(separator: "\n"))
    }

    @Test func theTeamsPagesOfferNothingUnnamedAndNothingFalselySelected() async throws {
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("inc5-ax")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let home = MultiplayerFixesTests.home
        let share = model.share, teams = model.share.teams

        // A knowledge item: its Markdown list is a named group of static texts.
        share.open(.knowledgeItem("kn-skill"), on: home)
        var (found, dump) = try await nodes(model)
        #expect(!found.contains { $0.role == "AXUnknown" }, "\(dump)")
        let list = try #require(found.firstIndex { $0.label.hasPrefix("Numbered list, ") || $0.label.hasPrefix("List, ") }, "\(dump)")
        let items = found[(list + 1)...].prefix { $0.depth > found[list].depth }
        #expect(!items.isEmpty && items.allSatisfy { $0.role == "AXStaticText" }, "\(dump)")
        #expect(found[list].label.hasSuffix("\(items.count) item\(items.count == 1 ? "" : "s")"), "\(dump)")

        // Hosts: the Granted check and the endorsement chips are words, never "Selected".
        model.go(.home)
        share.open(.hosts, on: home)
        (found, dump) = try await nodes(model)
        #expect(!found.contains { $0.role == "AXUnknown" }, "\(dump)")
        #expect(found.contains { ($0.label + $0.value).contains("Granted") }, "\(dump)")
        #expect(!found.contains { $0.selected || $0.label == "Selected" || $0.value == "Selected" }, "\(dump)")

        // Reputation: endorsement chips again, beside who vouched.
        model.go(.home)
        teams.startReputation("dir-sam-agent", on: home)
        (found, dump) = try await nodes(model)
        #expect(!found.contains { $0.selected || $0.label == "Selected" }, "\(dump)")

        // A run's exit code and time are one readout.
        model.go(.home)
        teams.startHostRun("dir-jonas-mini", on: home)
        teams.hostDraft.command = "run-ios-ui-tests"
        teams.hostDraft.argumentText = "--fail-fast"
        await teams.runOnHost("dir-jonas-mini", on: home)?.value
        (found, dump) = try await nodes(model)
        #expect(found.filter { ($0.label + $0.value).contains("Exit 1, 41 seconds") }.count == 1, "\(dump)")
        #expect(!found.contains { $0.label == "41 s" || $0.value == "41 s" || $0.label == "exit 1" || $0.value == "exit 1" }, "\(dump)")
        #expect(found.contains { $0.label == "Extra arguments" }, "\(dump)")
        // A command that takes no arguments offers no field for them.
        teams.hostDraft.command = "build-release"
        (found, dump) = try await nodes(model)
        #expect(!found.contains { $0.label == "Extra arguments" }, "\(dump)")
        // A host that publishes only tools keeps the field.
        model.go(.home)
        teams.startHostRun("dir-mei-gpu", on: home)
        teams.hostDraft.command = "train-eval"
        (found, dump) = try await nodes(model)
        #expect(found.contains { $0.label == "Extra arguments" }, "\(dump)")

        // A success notice's tick isn't selected, and its sentence says it is done.
        model.go(.home)
        share.open(.workspace("ws-relay"), on: home)
        await model.settle()
        model.post(notice: "Released card-2.")
        (found, dump) = try await nodes(model)
        #expect(!found.contains { $0.selected && $0.role != "AXRadioButton" && $0.role != "AXButton" }, "\(dump)")
        #expect(found.contains { ($0.label + $0.value).contains("Done: Released card-2.") }, "\(dump)")
        // The second press arrives under the row, named for what it does.
        #expect(found.contains { $0.role == "AXButton" && $0.label.hasPrefix("Release ") }, "\(dump)")
        #expect(found.contains { $0.role == "AXButton" && $0.label.hasPrefix("Remove collab/") && $0.label.hasSuffix("from the merge queue") }, "\(dump)")
        teams.ask(.releaseClaim("cl-2"))
        (found, dump) = try await nodes(model)
        #expect(found.contains { $0.role == "AXButton" && $0.label == "Release claim" }, "\(dump)")
        #expect(found.contains { $0.role == "AXButton" && $0.label == "Keep claim" }, "\(dump)")

        // One claim is "1 claim".
        model.go(.home)
        share.open(.workspaces, on: home)
        (found, dump) = try await nodes(model)
        #expect(found.contains { $0.label.hasSuffix(", 1 claim") }, "\(dump)")
        #expect(!found.contains { $0.label.contains("1 claims") }, "\(dump)")
    }

    // MARK: Pictures

    @Test(.enabled(if: multiplayerRenderDirectory != nil)) func drawsTheIncrement5Fixes() async throws {
        let folder = URL(fileURLWithPath: try #require(multiplayerRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, defaults, suite) = try await MultiplayerFixesTests.fixtureModel("inc5-render")
        defer { model.close(); defaults.removePersistentDomain(forName: suite) }
        let home = MultiplayerFixesTests.home
        let share = model.share, teams = model.share.teams
        func draw(_ name: String) async throws {
            await model.settle()
            try await MultiplayerRenderTests.write(model, "inc5-\(name)", to: folder)
        }

        // D4 and D6: a group opened from People, with Remove member waiting for its second press.
        model.tab = .people
        share.open(.group("grp-relay"), on: home)
        teams.ask(.removeMember(group: "grp-relay", handle: "fixture-sam"))
        try await draw("d4-remove-member-confirm")

        // D4: Release claim and the queue's Remove, each under its row. D6: back says Agents.
        model.go(.home)
        model.tab = .agents
        share.open(.workspace("ws-relay"), on: home)
        await model.settle()
        teams.ask(.releaseClaim("cl-2"))
        try await draw("d4-release-claim-confirm")
        if let entry = teams.queue(for: "ws-relay").first(where: { $0.state == "failed" }) {
            teams.ask(.removeQueued(entry.id))
            try await draw("queue-remove-confirm")
            await teams.removeQueued(entry, on: home)?.value
            try await draw("queue-removed")
        }
        if let card = teams.card("card-2") {
            teams.openCard(card, in: "ws-relay", on: home)
            teams.ask(.releaseCard("card-2"))
            try await draw("d4-release-card-confirm")
        }

        // D5: the refusal as two sentences.
        model.go(.home)
        share.open(.workspace("ws-relay"), on: home)
        await model.settle()
        teams.startClaim(in: "ws-relay", on: home)
        teams.claimDraft.kind = .paths
        teams.claimDraft.key = "Sources/Relay/Lease.swift"
        await teams.sendClaim(in: "ws-relay", on: home)?.value
        try await draw("d5-claim-conflict")
        model.go(.home)
        share.open(.policy, on: home)
        await model.settle()
        teams.policyDraft.member = "fixture-nobody"
        teams.ask(.suspend("fixture-nobody"))
        await teams.setSuspended(true, on: home)?.value
        try await draw("d5-suspend-unknown")

        // Extra arguments: offered, withheld, and offered when the host doesn't say.
        model.go(.home)
        teams.startHostRun("dir-jonas-mini", on: home)
        teams.hostDraft.command = "run-ios-ui-tests"
        teams.hostDraft.argumentText = "--fail-fast"
        await teams.runOnHost("dir-jonas-mini", on: home)?.value
        try await draw("run-args-allowed-and-d7-result")
        teams.hostDraft.command = "build-release"
        try await draw("run-args-not-allowed")

        // D8: the 16-cell meter, and the hand-off's state with its lamp and mono times.
        model.go(.home)
        teams.startReputation("dir-sam-agent", on: home)
        try await draw("d8-reputation-meter")
        model.go(.home)
        share.open(.handoffDetail(request: "rq-handoff-1"), on: home)
        if let row = share.handoff("rq-handoff-1", on: home) { await share.check(row, on: home, result: true)?.value }
        try await draw("d8-handoff-detail")

        // D7 and D9: the knowledge item's list, and a pull-request workspace.
        model.go(.home)
        share.open(.knowledgeItem("kn-skill"), on: home)
        try await draw("d7-knowledge-item")
        model.go(.home)
        share.open(.workspace("ws-ios"), on: home)
        try await draw("d9-pull-request-workspace")
    }
}
