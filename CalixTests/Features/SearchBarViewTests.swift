import Testing
@testable import Calix

@MainActor
@Suite("SearchBarView Tests")
struct SearchBarViewTests {
    // formatMatchCount (pure static method on SearchBarView)
    @Test("formatMatchCount: total=-1 returns empty string")
    func formatUnknownTotal() {
        #expect(SearchBarView.formatMatchCount(total: -1, selected: -1) == "")
    }

    @Test("formatMatchCount: total=0 returns No matches")
    func formatZeroTotal() {
        #expect(SearchBarView.formatMatchCount(total: 0, selected: -1) == "No matches")
    }

    @Test("formatMatchCount: selected=3, total=10 returns 3 of 10")
    func formatSelectedOfTotal() {
        #expect(SearchBarView.formatMatchCount(total: 10, selected: 3) == "3 of 10")
    }

    @Test("formatMatchCount: selected=-1, total=5 returns 5 matches")
    func formatTotalOnly() {
        #expect(SearchBarView.formatMatchCount(total: 5, selected: -1) == "5 matches")
    }

    @Test("formatMatchCount: selected=0, total=5 treated as unknown")
    func formatZeroSelected() {
        #expect(SearchBarView.formatMatchCount(total: 5, selected: 0) == "5 matches")
    }

    @Test("formatMatchCount: selected > total treated as unknown")
    func formatSelectedExceedsTotal() {
        #expect(SearchBarView.formatMatchCount(total: 3, selected: 5) == "3 matches")
    }

    @Test("formatMatchCount: single match selected")
    func formatSingleMatch() {
        #expect(SearchBarView.formatMatchCount(total: 1, selected: 1) == "1 of 1")
    }
}
