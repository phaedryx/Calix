// Tab.swift
// Calyx
//
// Represents a single terminal tab with its split layout.

import Foundation

enum TabContent: Sendable {
    case terminal
    case browser(url: URL)
    case diff(source: DiffSource)
}

@MainActor @Observable
class Tab: Identifiable {
    let id: UUID
    var title: String
    var titleOverride: String?
    var pwd: String?
    /// Current branch of the repository at `pwd`, resolved asynchronously
    /// by `CalyxWindowController.handleSetPwdNotification` whenever `pwd`
    /// changes. `nil` while unresolved or when `pwd` isn't inside a git
    /// repository. Ported from cmux's per-workspace sidebar git metadata.
    var gitBranch: String?
    var splitTree: SplitTree
    var content: TabContent
    var unreadNotifications: Int = 0
    var lastNotificationTime: Date?
    /// Bumped to request that whichever tab UI (`TabItemButton` or
    /// `TabRowItemView`) is currently displaying this tab enter inline
    /// rename mode, mirroring what a double-click does. Set by the
    /// `prompt_tab_title`/`prompt_surface_title` keybind handler in
    /// `CalyxWindowController`, since that fires from AppKit with no
    /// direct handle on the SwiftUI view's local `isEditing` state.
    var renameRequestID: UUID?
    let registry: SurfaceRegistry
    /// calyx-session references for this tab's persistent-session
    /// leaves, keyed by leaf (surface) UUID. Empty for a tab with no
    /// persistent sessions. Mirrored to `TabSnapshot.sessionRefs` by
    /// `Tab.snapshot()` (as `nil` when empty) and restored back by
    /// `Tab.init(snapshot:)`.
    var sessionRefs: [UUID: SessionRef]

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        titleOverride: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        content: TabContent = .terminal,
        registry: SurfaceRegistry = SurfaceRegistry(),
        sessionRefs: [UUID: SessionRef] = [:]
    ) {
        self.id = id
        self.title = title
        self.titleOverride = titleOverride
        self.pwd = pwd
        self.splitTree = splitTree
        self.content = content
        self.registry = registry
        self.sessionRefs = sessionRefs
    }

    func clearUnreadNotifications() {
        unreadNotifications = 0
        lastNotificationTime = nil
    }
}

extension Tab {
    /// Drops any `sessionRefs` entries whose key is not a leaf
    /// currently present in `splitTree` — call after a restore that
    /// couldn't bring back every leaf (either a partial
    /// `AppDelegate.restoreTabSurfaces` failure, or
    /// `fallbackCreateSurface`'s single fresh leaf replacing the whole
    /// tree), so a `SessionRef` pointing at a leaf that no longer
    /// exists doesn't linger in the tab — and doesn't get written back
    /// out, orphaned, by the next snapshot.
    ///
    func pruneSessionRefs() {
        let liveLeafIDs = Set(splitTree.allLeafIDs())
        sessionRefs = sessionRefs.filter { liveLeafIDs.contains($0.key) }
    }
}
