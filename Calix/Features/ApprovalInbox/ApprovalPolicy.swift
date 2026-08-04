// ApprovalPolicy.swift
// Calix
//
// Decides whether a gated Cockpit action requires a human approval-inbox
// round trip before proceeding. Gated solely by
// CockpitSettings.autoApproveEnabled: approval is required unless
// auto-approve has been explicitly turned on -- see
// CalixTests/ApprovalInbox/ApprovalPolicyTests.swift.

import Foundation

enum ApprovalPolicy {
    @MainActor
    static func requiresApproval() -> Bool {
        !CockpitSettings.autoApproveEnabled
    }
}
