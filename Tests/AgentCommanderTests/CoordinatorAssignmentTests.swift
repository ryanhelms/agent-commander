import Testing
@testable import AgentCommander

@Suite struct CoordinatorAssignmentTests {
    @Test func buttonIsOfferedOnlyForAnAssignmentWithText() {
        #expect(CoordinatorAssignmentButton.isOffered(for: "Plan the retry policy."))
        #expect(!CoordinatorAssignmentButton.isOffered(for: ""))
        #expect(!CoordinatorAssignmentButton.isOffered(for: " \n\t"))
    }

    @Test func buttonIsNamedForWhatItShows() {
        #expect(CoordinatorAssignmentButton.label == "Show coordinator assignment")
    }

    @Test func sheetGrowsWithTheTextThenScrolls() {
        #expect(CoordinatorAssignmentSheet.wellHeight(forText: 0) == 56)
        #expect(CoordinatorAssignmentSheet.wellHeight(forText: 180.2) == 181)
        #expect(CoordinatorAssignmentSheet.wellHeight(forText: 9_000) == CoordinatorAssignmentSheet.maxWellHeight)
    }

    @Test func sheetAttributesTheAssignment() {
        #expect(CoordinatorAssignmentSheet.attribution(startedAt: "14:08:02") == "From you, 14:08:02")
        #expect(CoordinatorAssignmentSheet.attribution(startedAt: nil) == "From you")
        #expect(CoordinatorAssignmentSheet.attribution(startedAt: "") == "From you")
    }
}
