import XCTest
@testable import Calix

final class IPCConfigManagerTests: XCTestCase {

    // MARK: - IPCConfigResult.anySucceeded

    func test_anySucceeded_bothSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .success,
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_oneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_otherSuccess() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .success,
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_noneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    func test_anySucceeded_failedAndSkipped() {
        let error = NSError(domain: "test", code: 1)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    // MARK: - IPCConfigResult.anySucceeded (openCode axis)

    func test_anySucceeded_onlyOpenCode() {
        // Given: only openCode is .success, others skipped
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .success,
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when only openCode succeeded")
    }

    func test_anySucceeded_allThreeSkipped() {
        // Given: all five skipped
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when all five are skipped")
    }

    func test_anySucceeded_openCodeFailedOthersSkipped() {
        // Given: openCode failed, others skipped
        let error = NSError(domain: "test", code: 2)
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .failed(error),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when openCode failed and others skipped")
    }

    func test_anySucceeded_openCodeSuccessOthersFailed() {
        // Given: openCode success, others failed
        let error = NSError(domain: "test", code: 3)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .success,
            hermes: .failed(error),
            cursorAgent: .failed(error)
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when openCode succeeded despite other failures")
    }

    // MARK: - IPCConfigResult.anySucceeded (hermes axis)

    func test_anySucceeded_onlyHermes() {
        // Given: only hermes is .success, others skipped
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .success,
            cursorAgent: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when only hermes succeeded")
    }

    func test_anySucceeded_hermesFailedOthersSkipped() {
        // Given: hermes failed, others skipped
        let error = NSError(domain: "test", code: 4)
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .failed(error),
            cursorAgent: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when hermes failed and others skipped")
    }

    func test_anySucceeded_hermesSuccessOthersFailed() {
        // Given: hermes success, others failed
        let error = NSError(domain: "test", code: 5)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .success,
            cursorAgent: .failed(error)
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when hermes succeeded despite other failures")
    }

    // MARK: - IPCConfigResult.anySucceeded (cursorAgent axis)

    func test_anySucceeded_onlyCursorAgent() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .success
        )
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when only cursorAgent succeeded")
    }

    func test_anySucceeded_cursorAgentFailedOthersSkipped() {
        let error = NSError(domain: "test", code: 6)
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .failed(error)
        )
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when cursorAgent failed and others skipped")
    }

    func test_anySucceeded_cursorAgentSuccessOthersFailed() {
        let error = NSError(domain: "test", code: 7)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            cursorAgent: .success
        )
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when cursorAgent succeeded despite other failures")
    }

    // MARK: - ConfigStatus pattern matching

    func test_configStatus_success() {
        let status: ConfigStatus = .success
        if case .success = status {
            // pass
        } else {
            XCTFail("Expected .success")
        }
    }

    func test_configStatus_skipped() {
        let status: ConfigStatus = .skipped(reason: "not installed")
        if case .skipped(let reason) = status {
            XCTAssertEqual(reason, "not installed")
        } else {
            XCTFail("Expected .skipped")
        }
    }

    func test_configStatus_failed() {
        let error = NSError(domain: "test", code: 42)
        let status: ConfigStatus = .failed(error)
        if case .failed(let err) = status {
            XCTAssertEqual((err as NSError).code, 42)
        } else {
            XCTFail("Expected .failed")
        }
    }

    // MARK: - Preference gating (enableIPC respects AgentIPCSettings, disableIPC does not)

    private let prefsSuiteName = "com.calix.tests.IPCConfigManagerTests.prefs"

    func test_enableIPC_skipsAgentDisabledInSettings() {
        AgentIPCSettings._testUseSuite(named: prefsSuiteName)
        defer { AgentIPCSettings._testTeardownSuite(named: prefsSuiteName) }

        AgentIPCSettings.setEnabled(false, for: .codex)

        let result = IPCConfigManager.enableIPC(port: 1, token: "t")

        guard case .skipped(let reason) = result.codex else {
            XCTFail("Expected codex to be skipped when disabled in settings, got \(result.codex)")
            return
        }
        XCTAssertEqual(reason, "disabled in settings")
    }

    @MainActor
    func test_setAgentEnabled_returnsNilWhenServerNotRunning() {
        XCTAssertFalse(CalixMCPServer.shared.isRunning,
                       "Precondition: this test assumes no other test left the shared MCP server running")
        XCTAssertNil(IPCConfigManager.setAgentEnabled(.claudeCode, enabled: true))
    }

    // MARK: - IPCConfigResult.failedAgents

    func test_failedAgents_emptyWhenAllSuccessOrSkipped() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .skipped(reason: "not installed"),
            openCode: .success,
            hermes: .skipped(reason: "disabled in settings"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.failedAgents.isEmpty)
    }

    func test_failedAgents_returnsOnlyFailedEntries() {
        let claudeError = NSError(domain: "test", code: 1)
        let hermesError = NSError(domain: "test", code: 2)
        let result = IPCConfigResult(
            claudeCode: .failed(claudeError),
            codex: .success,
            openCode: .skipped(reason: "not installed"),
            hermes: .failed(hermesError),
            cursorAgent: .success
        )
        let failures = result.failedAgents
        XCTAssertEqual(failures.map(\.agent), [.claudeCode, .hermes])
        XCTAssertEqual((failures[0].error as NSError).code, 1)
        XCTAssertEqual((failures[1].error as NSError).code, 2)
    }

    func test_failedAgents_allFailed() {
        let error = NSError(domain: "test", code: 3)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            cursorAgent: .failed(error)
        )
        XCTAssertEqual(result.failedAgents.map(\.agent), IPCAgent.allCases)
    }
}
