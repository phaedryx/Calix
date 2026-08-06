// AccessibilityID.swift
// Calix
//
// Stable accessibility identifiers for XCUITest element lookup.

import Foundation

enum AccessibilityID {
    enum Sidebar {
        static let container = "calix.sidebar"
        static let newGroupButton = "calix.sidebar.newGroupButton"
        static let agentModeButton = "calix.sidebar.agentModeButton"
        static func group(_ id: UUID) -> String { "calix.sidebar.group.\(id.uuidString)" }
        static func tab(_ id: UUID) -> String { "calix.sidebar.tab.\(id.uuidString)" }
        static func groupNameTextField(_ id: UUID) -> String { "calix.sidebar.groupNameTextField.\(id.uuidString)" }
        static func groupCollapseButton(_ id: UUID) -> String { "calix.sidebar.groupCollapseButton.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calix.sidebar.tab.\(id.uuidString).closeButton" }
        static func groupCloseAllButton(_ id: UUID) -> String { "calix.sidebar.group.\(id.uuidString).closeAllButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calix.sidebar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ groupID: UUID, _ index: Int) -> String {
            "calix.sidebar.group.\(groupID.uuidString).tab.index.\(index)"
        }
        static func agentRow(id: UUID) -> String { "calix.sidebar.agentRow.\(id.uuidString)" }
        static let agentHooksIssuesBanner = "calix.sidebar.agentHooksIssuesBanner"
    }
    enum TabBar {
        static let container = "calix.tabBar"
        static let newTabButton = "calix.tabBar.newTabButton"
        static func tab(_ id: UUID) -> String { "calix.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calix.tabBar.tab.\(id.uuidString).closeButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calix.tabBar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ index: Int) -> String { "calix.tabBar.tab.index.\(index)" }
    }
    enum CommandPalette {
        static let container = "calix.commandPalette"
        static let searchField = "calix.commandPalette.searchField"
        static let resultsTable = "calix.commandPalette.resultsTable"
    }
    enum Compose {
        static let container = "calix.compose"
        static let textView = "calix.compose.textView"
        static let placeholder = "calix.compose.placeholder"
    }
    enum Search {
        static let container = "calix.search"
        static let searchField = "calix.search.searchField"
        static let matchCount = "calix.search.matchCount"
        static let previousButton = "calix.search.previousButton"
        static let nextButton = "calix.search.nextButton"
        static let closeButton = "calix.search.closeButton"
    }
    enum Browser {
        static let toolbar = "calix.browser.toolbar"
        static let backButton = "calix.browser.backButton"
        static let forwardButton = "calix.browser.forwardButton"
        static let reloadButton = "calix.browser.reloadButton"
        static let urlDisplay = "calix.browser.urlDisplay"
        static let errorBanner = "calix.browser.errorBanner"
    }
    enum Git {
        static let changesContainer = "calix.git.changes"
        static let refreshButton = "calix.git.refreshButton"
        static let modeToggle = "calix.git.modeToggle"
        /// Task 5: closes a single changes-list pane leaf.
        static let closePaneButton = "calix.git.closePaneButton"
        static let stagedSection = "calix.git.staged"
        static let unstagedSection = "calix.git.unstaged"
        static let untrackedSection = "calix.git.untracked"
        static let branchDeltaSection = "calix.git.branchDelta"
        static func fileEntry(_ path: String) -> String { "calix.git.file.\(path)" }
    }
    /// Sessions pane of the Settings window
    /// (Calix/Features/Settings/SettingsWindowController.swift). Applied
    /// to the four toggle NSSwitch controls so an XCUITest suite can
    /// locate a specific switch by a stable identifier instead of an
    /// ordinal position (`app.switches.firstMatch`), which silently
    /// breaks the moment a row is reordered or another switch is added
    /// above it.
    enum Settings {
        static let persistentSessionsSwitch = "calix.settings.sessions.persistentSessionsSwitch"
        static let historyPersistenceSwitch = "calix.settings.sessions.historyPersistenceSwitch"
        static let agentResumeSwitch = "calix.settings.sessions.agentResumeSwitch"
        static let agentResumeAutoExecuteSwitch = "calix.settings.sessions.agentResumeAutoExecuteSwitch"
        static let commandTrackingSwitch = "calix.settings.sessions.commandTrackingSwitch"
        static let smoothScrollingSwitch = "calix.settings.appearance.smoothScrollingSwitch"
        static let lspAutoInstallSwitch = "calix.settings.lsp.lspAutoInstallSwitch"
        static let lspRequireConfirmationSwitch = "calix.settings.lsp.lspRequireConfirmationSwitch"
        static let cockpitAutoApproveSwitch = "calix.settings.sessions.cockpitAutoApproveSwitch"
        static let agentHookApprovalSwitch = "calix.settings.sessions.agentHookApprovalSwitch"
    }
    enum SessionBrowser {
        static func row(_ id: String) -> String { "calix.sessionBrowser.row.\(id)" }
        static func attachButton(_ id: String) -> String { "calix.sessionBrowser.row.\(id).attachButton" }
        static func killButton(_ id: String) -> String { "calix.sessionBrowser.row.\(id).killButton" }
        static func remoteHostRow(_ host: String) -> String { "calix.sessionBrowser.remoteHost.\(host)" }
        static func remoteHostAttachButton(_ host: String) -> String { "calix.sessionBrowser.remoteHost.\(host).attachButton" }
        static func remoteHostInstallButton(_ host: String) -> String { "calix.sessionBrowser.remoteHost.\(host).installButton" }
    }
    /// Chrome-style in-app "your previous session was preserved" bar,
    /// shown at the top of a window when AppDelegate
    /// .hasPreservedSessionSnapshot is true (see RecoveryBarModel,
    /// Calix/Features/Persistence/). Deliberately `calix.recoveryBar.*`
    /// (a container + two per-window action buttons), not the bare
    /// `calix.recoveryBar` some other single-container enums here use
    /// (e.g. Sidebar.container == "calix.sidebar"), since this bar's own
    /// two buttons need distinguishable identifiers alongside it.
    enum RecoveryBar {
        static let container = "calix.recoveryBar.container"
        static let restoreButton = "calix.recoveryBar.restoreButton"
        static let dismissButton = "calix.recoveryBar.dismissButton"
    }
    /// Cockpit approval banner, shown at the top of a window when
    /// ApprovalBannerModel.current is non-nil (see ApprovalBannerModel,
    /// Calix/Features/ApprovalInbox/). Same `calix.approvalBanner.*`
    /// shape as RecoveryBar (a container + its action buttons), plus a
    /// `payload` identifier so an XCUITest suite can assert the rendered
    /// (control-character-escaped) command text. Stage E adds a compact
    /// cross-actions menu (`crossActionsMenu`), shown only for an
    /// `.agentHook`-sourced request, with two items
    /// (`allowAllPendingItem`/`alwaysAllowAllPanesItem`) -- see
    /// ApprovalBannerView. Queue navigation adds `previousButton`/
    /// `nextButton`/`positionLabel`, shown only while more than one
    /// request is queued for this window (see
    /// ApprovalBannerModel.positionInfo).
    enum ApprovalBanner {
        static let container = "calix.approvalBanner.container"
        static let allowButton = "calix.approvalBanner.allowButton"
        static let denyButton = "calix.approvalBanner.denyButton"
        static let alwaysAllowButton = "calix.approvalBanner.alwaysAllowButton"
        static let payload = "calix.approvalBanner.payload"
        static let crossActionsMenu = "calix.approvalBanner.crossActionsMenu"
        static let allowAllPendingItem = "calix.approvalBanner.allowAllPendingItem"
        static let alwaysAllowAllPanesItem = "calix.approvalBanner.alwaysAllowAllPanesItem"
        static let previousButton = "calix.approvalBanner.previousButton"
        static let nextButton = "calix.approvalBanner.nextButton"
        static let positionLabel = "calix.approvalBanner.positionLabel"
    }
    enum Diff {
        static let container = "calix.diff"
        static let toolbar = "calix.diff.toolbar"
        static let content = "calix.diff.content"
        static let lineNumberGutter = "calix.diff.lineNumbers"
        /// Task 5: closes a single diff pane leaf.
        static let closeButton = "calix.diff.closeButton"
    }
    enum DiffReview {
        static let submitButton = "calix.diff.review.submitButton"
        static let discardButton = "calix.diff.review.discardButton"
        static let commentBadge = "calix.diff.review.commentBadge"
        static let commentPopover = "calix.diff.review.commentPopover"
        static let submitAllButton = "calix.diff.review.submitAllButton"
        static let discardAllButton = "calix.diff.review.discardAllButton"
    }
}
