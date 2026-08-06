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

    var isSidebarVisible: Bool {
        windowSession.showSidebar && windowSession.sidebarMode == .changes
    }

    var activeDiffState: DiffLoadState? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return diffStates[tab.id]
    }

    var activeDiffSource: DiffSource? {
        guard let tab = activeTab, case .diff(let source) = tab.content else { return nil }
        return source
    }

    var activeDiffReviewStore: DiffReviewStore? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return reviewStores[tab.id]
    }

    var totalReviewCommentCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.reduce(0) { $0 + $1.comments.count }
    }

    var reviewFileCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.count
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
        guard !Task.isCancelled, isSidebarVisible else { return }

        let monitor: GitChangesMonitor
        if let existingMonitor = gitChangesMonitor {
            monitor = existingMonitor
        } else {
            monitor = GitChangesMonitor { @MainActor [weak self] _ in
                guard let self, self.isSidebarVisible else { return }
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
        // Dedup: check if same source already open
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .diff(let existingSource) = tab.content, existingSource == source {
                    switchToTab(tab.id)
                    return
                }
            }
        }

        guard let group = windowSession.activeGroup else { return }

        let fileName: String
        switch source {
        case .unstaged(let path, _), .staged(let path, _), .branchDelta(let path, _, _), .untracked(let path, _):
            fileName = (path as NSString).lastPathComponent
        }

        let tab = Tab(title: fileName, content: .diff(source: source))
        deactivateCurrentTab()
        group.addTab(tab)
        group.activeTabID = tab.id

        diffStates[tab.id] = .loading
        let reviewStore = DiffReviewStore()
        reviewStore.onCommentsChanged = { [weak self] in self?.refresh() }
        reviewStores[tab.id] = reviewStore
        refresh()

        let tabID = tab.id
        // Plain subscript store, not `insert(_:task:)`: tabID is the id
        // of the `Tab()` just created above, so this key was never
        // registered before -- `insert`'s cancel-before-replace would
        // never actually match anything here. This Task also never
        // self-removes its own entry once done (unlike `childExitedTasks`'
        // Tasks) -- a pre-existing divergence kept as-is here, not
        // something this refactor changes.
        diffTasks[tabID] = Task { [weak self] in
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

                // Verify tab still exists
                guard self.windowSession.groups.flatMap(\.tabs).contains(where: { $0.id == tabID }) else { return }

                self.diffStates[tabID] = .success(parsed)
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.diffStates[tabID] = .error(error.localizedDescription)
                self.refresh()
            }
        }
    }

    func closeDiffTab(_ tabID: UUID) {
        diffTasks[tabID]?.cancel()
        diffTasks.removeValue(forKey: tabID)
        diffStates.removeValue(forKey: tabID)
        reviewStores.removeValue(forKey: tabID)
    }

    private func findWorkDir() -> String? {
        activeTab?.pwd
    }

    // MARK: - Review Submission

    func submitDiffReview(tabID: UUID) {
        guard let store = reviewStores[tabID], store.hasUnsubmittedComments else { return }

        // Get file path from tab
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
              case .diff(let source) = tab.content else { return }
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
        // Collect all review stores with comments, paired with their DiffSource
        let entries: [(source: DiffSource, store: DiffReviewStore)] = reviewStores.compactMap { tabID, store in
            guard store.hasUnsubmittedComments else { return nil }
            guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  case .diff(let source) = tab.content else { return nil }
            return (source: source, store: store)
        }
        guard !entries.isEmpty else { return }

        let payload = DiffReviewStore.formatAllForSubmission(entries)
        let result = sendToAgent(payload)

        if result == .sent {
            for entry in entries { entry.store.clearAll() }
            refresh()
        }
    }

    func discardReview(tabID: UUID) {
        guard let store = reviewStores[tabID] else { return }
        store.clearAll()
        refresh()
    }

    func discardAllDiffReviews() {
        let storesWithComments = reviewStores.values.filter { $0.hasUnsubmittedComments }
        guard !storesWithComments.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Discard All Review Comments"
        alert.informativeText = "This will discard \(totalReviewCommentCount) comment(s) across \(reviewFileCount) file(s)."
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        for store in storesWithComments { store.clearAll() }
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
