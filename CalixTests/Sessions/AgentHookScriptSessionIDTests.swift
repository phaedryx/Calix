//
//  AgentHookScriptSessionIDTests.swift
//  CalixTests
//
//  TDD Red Phase for AgentHookScript.scriptBody's calix-session
//  awareness: a persistent-session pane's identity survives ghostty
//  surface re-creation (reconnect), while its CALIX_SURFACE_ID does
//  not — so the hook must send whichever is stable, preferring
//  CALIX_SESSION_ID over CALIX_SURFACE_ID when both are set.
//
//  Coverage:
//  - scriptBody references CALIX_SESSION_ID at all
//  - The value posted in the X-Calix-Surface-ID header uses the
//    standard POSIX sh fallback expression `${CALIX_SESSION_ID:-
//    $CALIX_SURFACE_ID}`, so a persistent-session pane's calix-session
//    ID is preferred whenever it is set, falling back to the existing
//    CALIX_SURFACE_ID otherwise
//  - Fix round (review, item 5): the guard must fail-open (exit 0)
//    only when BOTH CALIX_SURFACE_ID and CALIX_SESSION_ID are unset —
//    not just CALIX_SURFACE_ID as before. A real /bin/sh execution test
//    (AgentHookScriptSessionIDPipelineTests) proves this end to end
//    with only CALIX_SESSION_ID set.
//

import XCTest
@testable import Calix

final class AgentHookScriptSessionIDTests: XCTestCase {

    func test_scriptBody_referencesCalixSessionID() {
        XCTAssertTrue(AgentHookScript.scriptBody.contains("CALIX_SESSION_ID"),
                     "scriptBody must reference CALIX_SESSION_ID so a persistent-session pane's stable " +
                     "identity can be forwarded instead of its surface ID")
    }

    func test_scriptBody_headerValue_prefersSessionIDOverSurfaceIDViaShFallback() {
        XCTAssertTrue(
            AgentHookScript.scriptBody.contains("${CALIX_SESSION_ID:-$CALIX_SURFACE_ID}"),
            "The value sent in the X-Calix-Surface-ID header must be the standard POSIX sh fallback " +
            "expression `${CALIX_SESSION_ID:-$CALIX_SURFACE_ID}`, preferring CALIX_SESSION_ID (stable " +
            "across reconnect) over CALIX_SURFACE_ID (not stable across reconnect) whenever it is set"
        )
    }

    // Fix round (review, item 5): replaces the original contract's
    // "guard only checks CALIX_SURFACE_ID" test. The corrected guard
    // must fail-open only when NEITHER variable is set, so that a
    // future call site which sets CALIX_SESSION_ID without
    // CALIX_SURFACE_ID (not possible today, but the guard must not
    // silently rely on that invariant holding forever) still gets its
    // event forwarded. See AgentHookScriptSessionIDPipelineTests for
    // the real end-to-end proof via an actual /bin/sh execution.
    func test_scriptBody_guardExitsOnlyWhenBothSurfaceIDAndSessionIDAreUnset() {
        let body = AgentHookScript.scriptBody
        XCTAssertTrue(
            body.contains("[ -z \"$CALIX_SURFACE_ID\" ]") && body.contains("[ -z \"$CALIX_SESSION_ID\" ]"),
            "The guard must test both CALIX_SURFACE_ID and CALIX_SESSION_ID for emptiness, not just " +
            "CALIX_SURFACE_ID as before"
        )
        XCTAssertTrue(body.contains("exit 0"), "The fail-open exit-0 contract must be preserved")
    }
}
