// GitChangesController.swift
// Calix
//
// Git Changes sidebar + diff-tab orchestration, extracted from
// CalixWindowController: sidebar visibility/monitoring, diff-tab
// open/close lifecycle, and review-comment submit/discard. A thin
// orchestrator over GitChangesMonitor/GitService/DiffParser/
// DiffReviewStore -- those stay unchanged.
//
// `windowSession` is held by reference (WindowSession is a class), so
// mutations here are visible to CalixWindowController without any
// forwarding. `refresh` wraps CalixWindowController.refreshHostingView()
// -- imperative, not Observable-driven, so every mutation site below
// must call it explicitly, exactly as it did before the move.
// `switchToTab`/`deactivateCurrentTab` are tab-activation machinery that
// stays owned by CalixWindowController; `sendToAgent` wraps
// `sendReviewToAgent(_:)`, which also stays put (shared with
// `sendComposeText`'s compose-overlay flow).

import AppKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calix.terminal",
    category: "GitChangesController"
)

@MainActor
final class GitChangesController {
    private let windowSession: WindowSession
    private let refresh: () -> Void
    private let switchToTab: (UUID) -> Void
    private let deactivateCurrentTab: () -> Void
    private let sendToAgent: (String) -> ReviewSendResult

    private var diffStates: [UUID: DiffLoadState] = [:]
    private var diffTasks = KeyedTaskRegistry<UUID>()
    private var refreshTask: Task<Void, Never>?
    private var gitChangesMonitor: GitChangesMonitor?
    private var gitMonitorStopTask: Task<Void, Never>?
    private var reviewStores: [UUID: DiffReviewStore] = [:]

    init(
        windowSession: WindowSession,
        refresh: @escaping () -> Void,
        switchToTab: @escaping (UUID) -> Void,
        deactivateCurrentTab: @escaping () -> Void,
        sendToAgent: @escaping (String) -> ReviewSendResult
    ) {
        self.windowSession = windowSession
        self.refresh = refresh
        self.switchToTab = switchToTab
        self.deactivateCurrentTab = deactivateCurrentTab
        self.sendToAgent = sendToAgent
    }

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    /// `true` exactly when the ACTIVE tab has its changes panel open --
    /// i.e. one of its own `splitTree` leaves is a `.gitChanges` entry in
    /// its `paneContent`, as put there by `toggleChangesPanel()` below.
    /// Replaces the window-level `showSidebar && sidebarMode == .changes`
    /// this used to read, deleted in Task 8 along with that sidebar mode:
    /// git changes are per-tab now, so another tab's open panel must not
    /// make this true.
    ///
    /// Gates background git-status monitoring (`startMonitoring`/
    /// `stopMonitoring` below) plus `CalixWindowController`'s automatic
    /// `refreshStatus()` calls on tab activation and on `cd`. Renamed from
    /// `isSidebarVisible`, which named a UI concept that no longer exists.
    var isChangesPanelVisible: Bool {
        guard let tab = activeTab else { return false }
        return tab.paneContent.values.contains(.gitChanges)
    }

    /// The ACTIVE tab's own open diff panes that currently hold
    /// unsubmitted review comments. Single source of truth for
    /// `submitAllDiffReviews`/`discardAllDiffReviews` and for the counts
    /// that label and gate them (`DiffContainerView`'s "Submit All (N in M
    /// files)" button, the `review.submitAll` palette command's
    /// `isAvailable`), so the number the user is shown can never disagree
    /// with the set actually acted on.
    ///
    /// Both filters matter: `reviewStores` is keyed by leaf ID but is not
    /// itself partitioned by tab, and a store can outlive its
    /// `paneContent` entry, so membership in the active tab's `splitTree`
    /// alone is not enough.
    private var activeTabReviewEntries: [(source: DiffSource, store: DiffReviewStore)] {
        guard let tab = activeTab else { return [] }
        let tabLeafIDs = Set(tab.splitTree.allLeafIDs())
        return reviewStores.compactMap { leafID, store in
            guard tabLeafIDs.contains(leafID), store.hasUnsubmittedComments else { return nil }
            guard case .diff(let source) = tab.paneContent[leafID] else { return nil }
            return (source: source, store: store)
        }
    }

    var totalReviewCommentCount: Int {
        activeTabReviewEntries.reduce(0) { $0 + $1.store.comments.count }
    }

    var reviewFileCount: Int {
        activeTabReviewEntries.count
    }

    func reviewStore(for tabID: UUID) -> DiffReviewStore? {
        reviewStores[tabID]
    }

    /// Per-key diff load state, for callers that render a specific diff
    /// rather than "the active tab's" one (`SplitContainerView`'s diff
    /// panes, keyed by split-tree leaf ID).
    func diffState(for id: UUID) -> DiffLoadState? {
        diffStates[id]
    }

    /// The `DiffSource` a given leaf was opened with, looked up from the
    /// active tab's `paneContent` -- there is no longer a single "the
    /// active diff", since a tab can have multiple open diff panes.
    func diffSource(for leafID: UUID) -> DiffSource? {
        guard case .diff(let source) = activeTab?.paneContent[leafID] else { return nil }
        return source
    }

    // MARK: - Sidebar / Monitoring

    func refreshStatus(showsLoadingState: Bool = true) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            guard let tab = self.activeTab else { return }

            let workDir = self.findWorkDir()
            guard let workDir else {
                self.stopMonitoring(cancelRefresh: false)
                tab.gitChangesState = .error("No working directory found")
                self.refresh()
                return
            }

            if showsLoadingState {
                tab.gitChangesState = .loading
                self.refresh()
            }

            do {
                let repository = try await GitService.repositoryLocation(workDir: workDir)
                guard !Task.isCancelled else { return }

                tab.repoRoot = repository.workTree
                await self.startMonitoring(repository: repository)
                guard !Task.isCancelled else { return }

                // Only fetch on user-visible refreshes (initial load, manual
                // refresh, tab/sidebar becoming visible again) -- not on every
                // FSEvents-triggered silent refresh, which would otherwise hit
                // the network on every file save.
                if showsLoadingState {
                    _ = try? await GitService.fetchOrigin(workDir: repository.workTree)
                }
                guard !Task.isCancelled else { return }

                async let statusResult = GitService.gitStatus(workDir: repository.workTree)
                async let deltaResult = self.loadBranchDelta(workDir: repository.workTree)
                let (entries, delta) = try await (statusResult, deltaResult)
                guard !Task.isCancelled else { return }

                tab.gitEntries = entries
                tab.branchDeltaBase = delta.base
                tab.branchDeltaEntries = delta.entries
                tab.gitChangesState = .loaded
                self.refresh()
            } catch let error as GitService.GitError {
                guard !Task.isCancelled else { return }
                self.stopMonitoring(cancelRefresh: false)
                if case .notARepository = error {
                    tab.gitChangesState = .notRepository
                } else {
                    tab.gitChangesState = .error(error.localizedDescription)
                }
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.stopMonitoring(cancelRefresh: false)
                tab.gitChangesState = .error(error.localizedDescription)
                self.refresh()
            }
        }
    }

    /// Best-effort: no origin remote (or a failed lookup) just means
    /// nothing to compare against, not a fatal error for the whole tab.
    private func loadBranchDelta(workDir: String) async -> (base: String?, entries: [BranchDiffEntry]) {
        guard let base = try? await GitService.defaultRemoteBranch(workDir: workDir) else {
            return (nil, [])
        }
        let entries = (try? await GitService.branchDeltaFiles(workDir: workDir, base: base)) ?? []
        return (base, entries)
    }

    private func startMonitoring(repository: GitRepositoryLocation) async {
        if let stopTask = gitMonitorStopTask {
            await stopTask.value
        }
        guard !Task.isCancelled, isChangesPanelVisible else { return }

        let monitor: GitChangesMonitor
        if let existingMonitor = gitChangesMonitor {
            monitor = existingMonitor
        } else {
            monitor = GitChangesMonitor { @MainActor [weak self] _ in
                guard let self, self.isChangesPanelVisible else { return }
                self.refreshStatus(showsLoadingState: false)
            }
            gitChangesMonitor = monitor
        }

        do {
            try await monitor.watch(repository: repository)
        } catch {
            logger.error("Failed to start Git Changes monitor: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopMonitoring(cancelRefresh: Bool = true) {
        if cancelRefresh {
            refreshTask?.cancel()
        }
        guard let monitor = gitChangesMonitor else { return }
        let previousStopTask = gitMonitorStopTask
        gitMonitorStopTask = Task {
            if let previousStopTask {
                await previousStopTask.value
            }
            await monitor.stop()
        }
    }

    // MARK: - Changes Panel

    /// Opens or closes the ACTIVE tab's git-changes panel: exactly one
    /// `.gitChanges` leaf inserted beside (or removed from) that tab's own
    /// `splitTree`. This is the replacement for the window-level `.changes`
    /// sidebar mode deleted in Task 8 -- each tab's panel is independent,
    /// showing that tab's own repo (`Tab.repoRoot`, resolved from its
    /// `pwd`).
    ///
    /// Driven by the `git.showChanges` palette command and the tab bar's
    /// changes-panel button, both via
    /// `CalixWindowController.toggleGitChangesPanel()`, which additionally
    /// re-asserts AppKit first responder afterwards (see its comment).
    func toggleChangesPanel() {
        guard let tab = activeTab else { return }
        // A browser tab renders `BrowserContainerView`, not
        // `SplitContainerView`, so a pane inserted into its `splitTree`
        // would be invisible and unclosable.
        guard case .terminal = tab.content else { return }

        if let existingLeafID = tab.paneContent.first(where: { $0.value == .gitChanges })?.key {
            tab.paneContent.removeValue(forKey: existingLeafID)
            // `remove` re-points `focusedLeafID` at the closed leaf's
            // sibling for us; the caller turns that into an actual
            // first-responder change.
            tab.splitTree = tab.splitTree.remove(existingLeafID).tree
            // `isChangesPanelVisible` is false from here, so the FSEvents
            // monitor could only fire refreshes that immediately bail --
            // stop watching instead of leaving the stream alive for the
            // window's lifetime. `cancelRefresh: false` lets an in-flight
            // status load finish writing to `tab` harmlessly rather than
            // being torn down mid-flight.
            stopMonitoring(cancelRefresh: false)
        } else {
            guard let anchorLeafID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first else { return }
            let (newTree, newLeafID) = tab.splitTree.insert(at: anchorLeafID, direction: .horizontal)
            tab.splitTree = newTree
            // Same reasoning as `openDiffTab` below: `insert` focuses the
            // leaf it just created, but a `.gitChanges` pane has no ghostty
            // surface, so leaving `focusedLeafID` on it makes
            // `focusActiveTabImmediately`/`attemptFocusRestore`
            // (CalixWindowController) and `CockpitAppAccess.listPanes`'s
            // `isFocused` all wrong until the user clicks the terminal.
            // When `anchorLeafID` was a fallback for an empty tree, `insert`
            // built a fresh single-leaf tree instead and there is nothing
            // else to focus -- leave what `insert` set.
            if tab.splitTree.allLeafIDs().contains(anchorLeafID) {
                tab.splitTree.focusedLeafID = anchorLeafID
            }
            tab.paneContent[newLeafID] = .gitChanges
            // Load the panel's data and (re-)arm the monitor the close
            // branch above stops. `showsLoadingState` only on a tab that
            // has never resolved its repo: a re-open already has last-good
            // `gitEntries` cached on the tab, so it refreshes silently in
            // the background rather than flashing a spinner over them.
            refreshStatus(showsLoadingState: tab.repoRoot == nil)
        }
        refresh()
    }

    // MARK: - Diff Tabs

    func handleWorkingFileSelected(_ entry: GitFileEntry) {
        guard let repoRoot = activeTab?.repoRoot else { return }

        let source: DiffSource
        if entry.isStaged {
            source = .staged(path: entry.path, workDir: repoRoot)
        } else if entry.status == .untracked {
            source = .untracked(path: entry.path, workDir: repoRoot)
        } else {
            source = .unstaged(path: entry.path, workDir: repoRoot)
        }

        openDiffTab(source: source)
    }

    func handleBranchDeltaFileSelected(_ entry: BranchDiffEntry) {
        guard let repoRoot = activeTab?.repoRoot, let base = activeTab?.branchDeltaBase else { return }

        let source: DiffSource = .branchDelta(path: entry.path, base: base, workDir: repoRoot)
        openDiffTab(source: source)
    }

    private func openDiffTab(source: DiffSource) {
        guard let group = windowSession.activeGroup, let tab = group.activeTab else { return }

        // Dedup: check if this source is already open as a pane in this tab.
        // Deliberately does NOT touch `focusedLeafID` -- see the note below
        // on why the fresh-insertion path restores focus to the terminal
        // leaf; the same reasoning applies here, and there's no existing
        // leaf to refocus onto that has a ghostty surface anyway.
        if tab.paneContent.contains(where: {
            if case .diff(let existingSource) = $0.value { return existingSource == source }
            return false
        }) {
            refresh()
            return
        }

        // The leaf the diff pane is being inserted next to -- almost always
        // the terminal leaf the user was focused on. Restored below so
        // keyboard focus stays on the terminal: `focusedLeafID` is read as
        // "the leaf with keyboard focus" by `focusActiveTabImmediately`/
        // `attemptFocusRestore` (CalixWindowController) and surfaced over
        // MCP as `isFocused` by `CockpitAppAccess.listPanes`. A diff pane
        // has no ghostty surface, so leaving focus on it (as `insert`
        // otherwise does) makes all three readers wrong until the user
        // manually clicks the terminal.
        let insertionLeafID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first ?? UUID()
        let (newTree, newLeafID) = tab.splitTree.insert(
            at: insertionLeafID,
            direction: .horizontal
        )
        tab.splitTree = newTree
        if tab.splitTree.allLeafIDs().contains(insertionLeafID) {
            // Normal case: the terminal leaf we split against still exists
            // in the resulting tree -- keep it focused.
            tab.splitTree.focusedLeafID = insertionLeafID
        }
        // Else: `insertionLeafID` was a fallback (no terminal leaf existed
        // to split against, e.g. a tab with an empty splitTree), so `insert`
        // built a fresh tree with only `newLeafID` in it. Leave
        // `focusedLeafID` as `insert` set it (the new leaf) -- there's
        // nothing else to focus.
        tab.paneContent[newLeafID] = .diff(source: source)

        diffStates[newLeafID] = .loading
        let reviewStore = DiffReviewStore()
        reviewStore.onCommentsChanged = { [weak self] in self?.refresh() }
        reviewStores[newLeafID] = reviewStore
        refresh()

        diffTasks[newLeafID] = Task { [weak self] in
            guard let self else { return }
            do {
                let rawDiff = try await GitService.fileDiff(source: source)
                guard !Task.isCancelled else { return }

                let path: String
                switch source {
                case .unstaged(let p, _), .staged(let p, _), .branchDelta(let p, _, _), .untracked(let p, _):
                    path = p
                }
                let parsed = DiffParser.parse(rawDiff, path: path)
                guard !Task.isCancelled else { return }

                guard tab.paneContent[newLeafID] != nil else { return }
                self.diffStates[newLeafID] = .success(parsed)
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.diffStates[newLeafID] = .error(error.localizedDescription)
                self.refresh()
            }
        }
    }

    /// Removes a diff/changes pane's controller-owned state (task,
    /// load-state, review store) for `leafID`, and drops it from the
    /// ACTIVE tab's `paneContent` if it's there. Callers closing a pane
    /// belonging to a tab that may not be the active one (e.g. a whole
    /// background tab/group closing) must additionally remove it from
    /// that tab's own `paneContent` themselves -- see
    /// `CalixWindowController.closePane`/`closeTab`/`closeActiveGroup`/
    /// `closeAllTabsInGroup`. Unsent-review-comment confirmation stays
    /// the caller's job, same as today's `closeTab` -- Task 6
    /// generalizes that check for whole-tab close; per-pane close in
    /// `CalixWindowController` gets its own equivalent single-pane check.
    func closeDiffPane(_ leafID: UUID) {
        diffTasks[leafID]?.cancel()
        diffTasks.removeValue(forKey: leafID)
        diffStates.removeValue(forKey: leafID)
        reviewStores.removeValue(forKey: leafID)
        if let tab = windowSession.activeGroup?.activeTab {
            tab.paneContent.removeValue(forKey: leafID)
        }
    }

    private func findWorkDir() -> String? {
        activeTab?.pwd
    }

    // MARK: - Review Submission

    func submitDiffReview(leafID: UUID) {
        guard let tab = activeTab, let store = reviewStores[leafID], store.hasUnsubmittedComments else { return }
        guard case .diff(let source) = tab.paneContent[leafID] else { return }
        let filePath: String
        switch source {
        case .unstaged(let p, _), .staged(let p, _), .branchDelta(let p, _, _), .untracked(let p, _):
            filePath = p
        }

        let payload = store.formatForSubmission(filePath: filePath)
        let result = sendToAgent(payload)
        if result == .sent {
            store.clearAll()
            refresh()
        }
    }

    func submitAllDiffReviews() {
        let entries = activeTabReviewEntries
        guard !entries.isEmpty else { return }

        let payload = DiffReviewStore.formatAllForSubmission(entries)
        let result = sendToAgent(payload)
        if result == .sent {
            for entry in entries { entry.store.clearAll() }
            refresh()
        }
    }

    func discardReview(leafID: UUID) {
        guard let store = reviewStores[leafID] else { return }
        store.clearAll()
        refresh()
    }

    /// Scoped to the active tab's own diff panes, exactly like
    /// `submitAllDiffReviews` above -- the button that triggers this lives
    /// in an active-tab diff pane and is gated on the (now tab-scoped)
    /// `reviewFileCount`, and the confirmation text below is built from the
    /// same counts. A window-global discard would report N comments and
    /// silently destroy more than N.
    func discardAllDiffReviews() {
        let entries = activeTabReviewEntries
        guard !entries.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Discard All Review Comments"
        alert.informativeText = "This will discard \(totalReviewCommentCount) comment(s) across \(reviewFileCount) file(s)."
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        for entry in entries { entry.store.clearAll() }
        refresh()
    }

    // MARK: - Shutdown

    func shutdown() {
        diffTasks.cancelAll()
        diffStates.removeAll()
        reviewStores.removeAll()
        refreshTask?.cancel()
        let gitChangesMonitor = gitChangesMonitor
        gitMonitorStopTask?.cancel()
        Task { await gitChangesMonitor?.stop() }
    }
}
