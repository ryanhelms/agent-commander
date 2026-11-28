import Foundation
import Testing
@testable import AgentCommander

@Suite struct NeedsYouRequestLinkTests {
    @Test(arguments: ["Q-021", "approval:relay/request", "access:relay/café&more=50%+ok#1", "A%2FB"])
    func preservesExactRequestID(_ id: String) throws {
        let link = try #require(NeedsYouRequestLink(id: id))
        #expect(link.url.scheme == "agentcommander")
        #expect(link.url.host == "needs-you")
        #expect(NeedsYouRequestLink(url: link.url)?.id == id)
    }

    @Test(arguments: [
        "https://needs-you?request=Q-021",
        "agentcommander://join?request=Q-021",
        "agentcommander://needs-you/?request=Q-021",
        "agentcommander://needs-you/approval?request=Q-021",
        "agentcommander://user:password@needs-you?request=Q-021",
        "agentcommander://needs-you:9?request=Q-021",
        "agentcommander://needs-you?request=Q-021#other",
        "agentcommander://needs-you",
        "agentcommander://needs-you?request",
        "agentcommander://needs-you?request=",
        "agentcommander://needs-you?item=Q-021",
        "agentcommander://needs-you?request=Q-021&request=Q-022",
        "agentcommander://needs-you?request=Q-021&answer=approve",
        "agentcommander://needs-you?request=Q-021%0A"
    ])
    func rejectsOtherRoutesAndAmbiguousRequests(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(NeedsYouRequestLink(url: url) == nil)
    }

    @Test func rejectsInvalidIDs() {
        #expect(NeedsYouRequestLink(id: "") == nil)
        #expect(NeedsYouRequestLink(id: " Q-021") == nil)
        #expect(NeedsYouRequestLink(id: "Q-\u{0000}021") == nil)
        #expect(NeedsYouRequestLink(id: String(repeating: "é", count: 513)) == nil)
    }
}
