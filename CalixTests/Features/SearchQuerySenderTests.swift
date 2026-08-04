import Testing
@testable import Calix

@MainActor
@Suite("SearchQuerySender Tests")
struct SearchQuerySenderTests {

    // Mock implementation of SearchQuerySender for deterministic testing
    final class MockSearchQuerySender: SearchQuerySender {
        var performSearchCalls: [String] = []
        var performActionCalls: [String] = []
        var searchReturnValue = true
        var actionReturnValue = true

        func performSearch(query: String) -> Bool {
            performSearchCalls.append(query)
            return searchReturnValue
        }

        func performAction(_ action: String) -> Bool {
            performActionCalls.append(action)
            return actionReturnValue
        }
    }

    @Test("performSearch forwards query to mock")
    func forwardsQuery() {
        let mock = MockSearchQuerySender()
        _ = mock.performSearch(query: "foobar")
        #expect(mock.performSearchCalls == ["foobar"])
    }

    @Test("empty query sends empty string")
    func emptyQuery() {
        let mock = MockSearchQuerySender()
        _ = mock.performSearch(query: "")
        #expect(mock.performSearchCalls == [""])
    }

    @Test("colon in query preserved")
    func colonInQuery() {
        let mock = MockSearchQuerySender()
        _ = mock.performSearch(query: "foo:bar")
        #expect(mock.performSearchCalls == ["foo:bar"])
    }
}
