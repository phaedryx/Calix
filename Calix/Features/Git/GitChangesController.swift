// GitChangesController.swift
// Calix
//
// Git Changes sidebar + diff-tab orchestration, extracted from
// CalixWindowController: sidebar visibility/monitoring, commit-log
// pagination, diff-tab open/close lifecycle, and review-comment
// submit/discard. A thin orchestrator over GitChangesMonitor/GitService/
// DiffParser/DiffReviewStore -- those stay unchanged.
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
    private var loadMoreTask: Task<Void, Never>?
    private var expandTasks = KeyedTaskRegistry<String>()
    private var hasMoreCommits = true
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

    // MARK: - Sidebar / Monitoring

    func refreshStatus(
        kind: GitChangesRefreshKind = .repositoryMetadata,
        showsLoadingState: Bool = true
    ) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }

            let workDir = self.findWorkDir()
            guard let workDir else {
                self.stopMonitoring(cancelRefresh: false)
                self.windowSession.gitChangesState = .error("No working directory found")
                self.refresh()
                return
            }

            if showsLoadingState {
                self.windowSession.gitChangesState = .loading
                self.refresh()
            }

            do {
                let repository = try await GitService.repositoryLocation(workDir: workDir)
                guard !Task.isCancelled else { return }

                self.windowSession.repoRoots[workDir] = repository.workTree
                await self.startMonitoring(repository: repository)
                guard !Task.isCancelled else { return }

                let entries: [GitFileEntry]
                var commits: [GitCommit]?
                if kind == .repositoryMetadata {
                    let commitCount = showsLoadingState
                        ? 100
                        : max(100, self.windowSession.gitCommits.count)
                    async let statusResult = GitService.gitStatus(workDir: repository.workTree)
                    async let logResult = GitService.commitLog(
                        workDir: repository.workTree,
                        maxCount: commitCount,
                        skip: 0
                    )
                    let (statusEntries, logCommits) = try await (statusResult, logResult)
                    entries = statusEntries
                    commits = logCommits
                } else {
                    entries = try await GitService.gitStatus(workDir: repository.workTree)
                    commits = nil
                }
                guard !Task.isCancelled else { return }

                self.windowSession.gitEntries = entries
                if let commits {
                    self.windowSession.gitCommits = commits
                    self.hasMoreCommits = true
                    if showsLoadingState {
                        self.windowSession.expandedCommitIDs = []
                        self.windowSession.commitFiles = [:]
                    } else {
                        let visibleCommitIDs = Set(commits.map(\.id))
                        self.windowSession.expandedCommitIDs.formIntersection(visibleCommitIDs)
                        self.windowSession.commitFiles = self.windowSession.commitFiles.filter {
                            visibleCommitIDs.contains($0.key)
                        }
                    }
                }
                self.windowSession.gitChangesState = .loaded
                self.refresh()
            } catch let error as GitService.GitError {
                guard !Task.isCancelled else { return }
                self.stopMonitoring(cancelRefresh: false)
                if case .notARepository = error {
                    self.windowSession.gitChangesState = .notRepository
                } else {
                    self.windowSession.gitChangesState = .error(error.localizedDescription)
                }
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.stopMonitoring(cancelRefresh: false)
                self.windowSession.gitChangesState = .error(error.localizedDescription)
                self.refresh()
            }
        }
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
            monitor = GitChangesMonitor { @MainActor [weak self] kind in
                guard let self, self.isSidebarVisible else { return }
                self.refreshStatus(kind: kind, showsLoadingState: false)
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

    func loadMoreCommits() {
        guard hasMoreCommits else { return }
        guard loadMoreTask == nil || loadMoreTask?.isCancelled == true else { return }
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            let currentCount = self.windowSession.gitCommits.count

            guard let workDir = self.findWorkDir(),
                  let repoRoot = self.windowSession.repoRoots[workDir] else { return }

            do {
                let moreCommits = try await GitService.commitLog(
                    workDir: repoRoot, maxCount: 50, skip: currentCount
                )
                guard !Task.isCancelled else { return }
                guard !moreCommits.isEmpty else {
                    self.hasMoreCommits = false
                    return
                }

                self.windowSession.gitCommits.append(contentsOf: moreCommits)
                self.refresh()
            } catch {
                // Silently ignore load-more errors
            }
            self.loadMoreTask = nil
        }
    }

    func expandCommit(hash: String) {
        if windowSession.expandedCommitIDs.contains(hash) {
            windowSession.expandedCommitIDs.remove(hash)
            refresh()
            return
        }

        windowSession.expandedCommitIDs.insert(hash)
        refresh()

        if windowSession.commitFiles[hash] != nil { return }

        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

        // Plain subscript store, not `insert(_:task:)`: unlike this
        // file's other three `KeyedTaskRegistry`s, `hash` is NOT
        // guaranteed fresh here -- a rapid double-expand of the same
        // not-yet-loaded commit before this Task completes reaches this
        // line twice for the same key (the guard above only checks
        // `commitFiles[hash] != nil`, not whether a fetch is already in
        // flight). `insert`'s cancel-before-replace would cancel the
        // first fetch's Task, which -- because `GitService.commitFiles`
        // routes through `GitService.run`'s cancellation propagation --
        // would terminate its underlying git subprocess early, changing
        // today's behavior (both fetches currently run to completion).
        expandTasks[hash] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await GitService.commitFiles(hash: hash, workDir: repoRoot)
                self.windowSession.commitFiles[hash] = files
                self.refresh()
            } catch {
                // Silently ignore
            }
            self.expandTasks.removeValue(forKey: hash)
        }
    }

    // MARK: - Diff Tabs

    func handleWorkingFileSelected(_ entry: GitFileEntry) {
        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

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

    func handleCommitFileSelected(_ entry: CommitFileEntry) {
        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

        let source: DiffSource = .commit(hash: entry.commitHash, path: entry.path, workDir: repoRoot)
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
        case .unstaged(let path, _), .staged(let path, _), .commit(_, let path, _), .untracked(let path, _):
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
        // never actually match anything here, mirroring
        // `reconnectEstablishGraceTasks`' own "fresh key" reasoning at
        // its `insert` call site above. This Task also never self-
        // removes its own entry once done (unlike `expandTasks`'/
        // `childExitedTasks`' Tasks) -- a pre-existing divergence kept
        // as-is here, not something this refactor changes.
        diffTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            do {
                let rawDiff = try await GitService.fileDiff(source: source)
                guard !Task.isCancelled else { return }

                let path: String
                switch source {
                case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
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
        // 1. Active terminal tab's pwd
        if let tab = activeTab, case .terminal = tab.content, let pwd = tab.pwd {
            return pwd
        }
        // 2. Any terminal tab in same group
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .terminal = tab.content, let pwd = tab.pwd {
                    return pwd
                }
            }
        }
        // 3. Any terminal tab in any group
        for group in windowSession.groups {
            for tab in group.tabs {
                if case .terminal = tab.content, let pwd = tab.pwd {
                    return pwd
                }
            }
        }
        // 4. Fallback from cached repo roots
        return windowSession.repoRoots.values.first
    }

    // MARK: - Review Submission

    func submitDiffReview(tabID: UUID) {
        guard let store = reviewStores[tabID], store.hasUnsubmittedComments else { return }

        // Get file path from tab
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
              case .diff(let source) = tab.content else { return }
        let filePath: String
        switch source {
        case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
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
        expandTasks.cancelAll()
        refreshTask?.cancel()
        let gitChangesMonitor = gitChangesMonitor
        gitMonitorStopTask?.cancel()
        Task { await gitChangesMonitor?.stop() }
        loadMoreTask?.cancel()
    }
}
