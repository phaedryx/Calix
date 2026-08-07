//
//  AgentIPCSettingsTests.swift
//  CalixTests
//
//  TDD Red Phase for AgentIPCSettings: per-IPCAgent preference store
//  gating IPCConfigManager.enableIPC. Defaults true for every agent --
//  shipping this must not change behavior until the user unchecks
//  something.
//

import XCTest
@testable import Calix

final class AgentIPCSettingsTests: XCTestCase {

    private let suiteName = "com.calix.tests.AgentIPCSettingsTests"

    override func setUp() {
        super.setUp()
        AgentIPCSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        AgentIPCSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_isEnabled_defaultsTrueForEveryAgent_whenKeyNeverWritten() {
        for agent in IPCAgent.allCases {
            XCTAssertTrue(AgentIPCSettings.isEnabled(agent),
                         "\(agent) must default to enabled when its key has never been written")
        }
    }

    func test_setEnabled_falseThenTrue_roundTrips() {
        AgentIPCSettings.setEnabled(false, for: .codex)
        XCTAssertFalse(AgentIPCSettings.isEnabled(.codex))

        AgentIPCSettings.setEnabled(true, for: .codex)
        XCTAssertTrue(AgentIPCSettings.isEnabled(.codex))
    }

    func test_setEnabled_isIndependentPerAgent() {
        AgentIPCSettings.setEnabled(false, for: .hermes)

        XCTAssertFalse(AgentIPCSettings.isEnabled(.hermes))
        for agent in IPCAgent.allCases where agent != .hermes {
            XCTAssertTrue(AgentIPCSettings.isEnabled(agent),
                         "Disabling hermes must not affect \(agent)")
        }
    }

    func test_testStoreIsolation_neverTouchesStandardDefaults() {
        AgentIPCSettings.setEnabled(false, for: .claudeCode)

        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(rawSuite.bool(forKey: "calix.ipc.claudeCodeEnabled"),
                      "Setting must actually persist into the isolated test suite")

        let otherSuiteName = suiteName + ".other"
        AgentIPCSettings._testUseSuite(named: otherSuiteName)
        XCTAssertTrue(AgentIPCSettings.isEnabled(.claudeCode),
                     "A fresh isolated suite must read the default (true), not leak state from a previously-used suite")
        AgentIPCSettings._testTeardownSuite(named: otherSuiteName)
    }
}
