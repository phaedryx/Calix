//
//  SessionBinaryResolverTests.swift
//  CalixTests
//
//  TDD Red Phase for SessionBinaryResolver: a single injectable
//  resolver contract that SessionSpawnPlanner and SessionDaemonClient
//  must both consume, so they always agree on which calix-session
//  binary they're talking about (fix round, item 4).
//
//  Coverage:
//  - Given the same resolver instance, SessionDaemonClient's resolved
//    path and SessionSpawnPlanner's synthesized command must embed the
//    identical path
//  - A resolver returning nil must make the planner fall back to
//    .passthrough (not a hardcoded "calix-session" literal) and the
//    client report every query as .unreachable
//

import XCTest
@testable import Calix

private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionBinaryResolverTests: XCTestCase {

    private let settingsSuiteName = "com.calix.tests.SessionBinaryResolverTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
        SessionSettings.persistentSessionsEnabled = true
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    func test_resolverResolvesAPath_plannerAndClientAgreeOnSamePath() {
        let resolver = FakeBinaryResolver(path: "/opt/calix-fixture/bin/calix-session")

        let client = SessionDaemonClient(resolver: resolver)
        XCTAssertEqual(client.resolvedBinaryPath, "/opt/calix-fixture/bin/calix-session",
                       "SessionDaemonClient must store exactly what the injected resolver resolves")

        let plan = SessionSpawnPlanner.plan(for: SessionSpawnContext(cwd: "/tmp"), resolver: resolver)
        guard case .persistent(_, let command, _) = plan else {
            XCTFail("With persistent sessions enabled, plan(for:) must produce .persistent, got \(plan)")
            return
        }
        XCTAssertTrue(
            command.contains(ShellEscape.escape("/opt/calix-fixture/bin/calix-session")),
            "SessionSpawnPlanner's synthesized command must embed the SAME path the injected resolver " +
            "produced — both consumers must agree, not resolve independently"
        )
    }

    func test_resolverReturnsNil_plannerFallsBackToPassthrough_clientReturnsUnreachable() async {
        let resolver = FakeBinaryResolver(path: nil)

        let plan = SessionSpawnPlanner.plan(for: SessionSpawnContext(cwd: "/tmp"), resolver: resolver)
        XCTAssertEqual(plan, .passthrough,
                       "With no binary resolvable, plan(for:) must fall back to .passthrough entirely, " +
                       "not synthesize a command around a hardcoded \"calix-session\" literal that may not exist on PATH")

        let client = SessionDaemonClient(resolver: resolver)
        let result = await client.sessionState(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertEqual(result, .unreachable, "With no binary resolvable, every query must report .unreachable")
    }
}
