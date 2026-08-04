import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calix.terminal",
    category: "AppDelegate"
)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appSession = AppSession()
    private(set) var browserTabBroker = BrowserTabBroker()
    private var windowControllers: [CalixWindowController] = []
    private var pendingURLs: [URL] = []
    private var quickTerminalController: QuickTerminalController?

    /// Captured the moment termination is confirmed (isTerminationConfirmed's
    /// didSet, false -> true transition only), BEFORE any window teardown or
    /// removeWindowController(_:) call can empty windowControllers/appSession.
    /// applicationWillTerminate (via saveForTermination()) consults this
    /// instead of re-deriving buildSnapshot() from the possibly-already-
    /// emptied live state, so the confirm-quit-by-closing-the-last-window
    /// route always saves a real snapshot. Covers BOTH termination routes:
    /// windowShouldClose's confirm branch and applicationShouldTerminate's
    /// own Cmd+Q branch both set isTerminationConfirmed = true.
    private(set) var pendingTerminationSnapshot: SessionSnapshot?

    #if DEBUG
    /// Test seam: force pendingTerminationSnapshot directly instead of
    /// only via isTerminationConfirmed's didSet, so saveForTermination()'s
    /// own "prefers the captured snapshot over a live rebuild" contract is
    /// testable in isolation from the capture mechanism itself. DO NOT use
    /// from production code.
    func _setPendingTerminationSnapshotForTesting(_ snapshot: SessionSnapshot?) {
        pendingTerminationSnapshot = snapshot
    }
    #endif

    /// Set when the user has already confirmed quit (prevents double-prompting
    /// between windowShouldClose and applicationShouldTerminate). The
    /// false -> true transition also captures pendingTerminationSnapshot
    /// (see that property's own doc comment for why); resetting back to
    /// false (applicationShouldTerminate's own "already confirmed" branch)
    /// deliberately leaves any already-captured snapshot untouched.
    var isTerminationConfirmed = false {
        didSet {
            guard isTerminationConfirmed, !oldValue else { return }
            pendingTerminationSnapshot = sessionRestoreCoordinator.buildSnapshot()
        }
    }

    /// P4 round-6 fix (R6-A/R6-D, r6-fix-spec.md): app-wide "the app is
    /// actually terminating" discriminator, distinct from any single
    /// `CalixWindowController.isClosingForShutdown`. That per-window flag
    /// means only "this window is tearing down" (round-5 review finding
    /// I2: `closeLastWindow`/F7 sets it even for a non-terminating close),
    /// so it cannot alone tell a deferred-event drain or `windowWillClose`'s
    /// destroy loop whether the whole app is quitting. This flag must be
    /// consulted (in addition to, not instead of, the per-window flag) by:
    /// the deferred-reconnect-event drain (must NOT replay into teardown
    /// while the app is mid-quit, see r5-verdicts.md V5), and
    /// `windowWillClose`'s destroy loop (must preserve `sessionRefs`
    /// into the snapshot only while this is true; otherwise it must run
    /// the normal kill/detach close policy, see r5-verdicts.md's sweep
    /// finding). Set `true` in `applicationShouldTerminate` on every
    /// `.terminateNow` return (alongside `markAllControllersClosingForShutdown`)
    /// and again in `applicationWillTerminate` as a belt-and-suspenders
    /// safety net. Never reset back to `false`: once the app is genuinely
    /// terminating, it stays that way for the remainder of the process's
    /// life.
    private(set) var isApplicationTerminating = false

    /// R8-C (r8-fix-spec.md; consolidates r7-verdicts.md's I1/A2/C2
    /// dormant discriminator-mismatch finding): the ONE canonical "is
    /// the app actually terminating" query, folding in both
    /// `isApplicationTerminating` (set once `applicationShouldTerminate`
    /// itself has decided to terminate) and `isTerminationConfirmed`
    /// (set earlier, by `windowShouldClose`'s last-window success path,
    /// for the whole window between that decision and
    /// `applicationShouldTerminate` actually running, see that flag's
    /// own doc comment for why `isClosingForShutdown` alone cannot
    /// stand in for this: round-5 review (I2) found it set even for a
    /// non-terminating close). Every reader that used to consult one or
    /// the other ad hoc (`CalixWindowController.isAppActuallyTerminating`,
    /// `killSessionIfPersistent`/`detachSessionIfPersistent`'s
    /// `isTerminating` parameter) must read THIS query instead, so the
    /// outer "should this teardown preserve or tear down" gate and any
    /// inner policy it drives always agree.
    var isTerminating: Bool {
        isApplicationTerminating || isTerminationConfirmed
    }

    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase): mirrors
    /// `_setConfirmingQuitForTesting`'s convention for `isApplicationTerminating`.
    /// DO NOT use from production code.
    func _setApplicationTerminatingForTesting(_ value: Bool) {
        isApplicationTerminating = value
    }
    #endif

    var allWindowControllers: [CalixWindowController] {
        windowControllers
    }

    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase, R6-D/R6-E): appends
    /// `controller` directly to `windowControllers`, bypassing
    /// `createNewWindow`/`makeRestoringWindowController`'s real window/
    /// surface construction. Lets tests exercise `focusWindowForExistingSession`
    /// (via `attachWindow`) against a genuine, already-registered
    /// controller, instead of only the "no owning controller at all"
    /// (stale-mapping) case `AppDelegateAttachWindowTests`'s existing
    /// fixture covers. DO NOT use from production code.
    func _testInsertWindowController(_ controller: CalixWindowController) {
        windowControllers.append(controller)
    }
    #endif

    #if DEBUG
    /// Test seam: overrides the resources root
    /// `applyGhosttyResourcesDirEnvironmentIfNeeded()` resolves against,
    /// instead of `Bundle.main.resourceURL`. DO NOT use from production
    /// code.
    var _ghosttyResourcesRootForTesting: URL?
    #endif

    /// Sets `GHOSTTY_RESOURCES_DIR` in this process's environment to
    /// Calix's own bundled ghostty resources directory, if the bundle
    /// actually contains shell-integration scripts (via
    /// `GhosttyResourcesDirResolver`), overwriting any inherited value
    /// (via `GhosttyResourcesDirEnvironment.apply(_:)`). Must run before
    /// `GhosttyAppController.shared` is ever touched, since ghostty reads
    /// this variable from its own process environment at engine init.
    func applyGhosttyResourcesDirEnvironmentIfNeeded() {
        #if DEBUG
        let root = _ghosttyResourcesRootForTesting ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #else
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #endif
        let resolvedPath = GhosttyResourcesDirResolver(resourcesRoot: root).resolve()
        GhosttyResourcesDirEnvironment.apply(resolvedPath)
    }

    #if DEBUG
    /// Test seam: overrides the root `ShellIntegrationInstaller.install`
    /// writes into, instead of
    /// `ShellIntegrationInstaller.defaultInstallDirectory`. DO NOT use
    /// from production code.
    var _shellIntegrationRootForTesting: URL?
    #endif

    /// If command tracking is enabled (`CommandTrackingSettings
    /// .trackingEnabled`), installs Calix's own zsh/fish command-log
    /// shell integration scripts and points this process's environment
    /// at them (`CalixShellIntegrationEnvironment.apply(rootDirectory:)`)
    /// -- every surface's child shell inherits this process's own
    /// environment fresh at launch, so a toggle change takes effect from
    /// the next NEW terminal without an app restart, matching
    /// `applyGhosttyResourcesDirEnvironmentIfNeeded()`'s own env-based
    /// injection point. Run right after that method so both env
    /// mutations land before `GhosttyAppController.shared` is ever
    /// touched.
    func applyCalixShellIntegrationIfEnabled() {
        guard CommandTrackingSettings.trackingEnabled else { return }
        #if DEBUG
        let root = _shellIntegrationRootForTesting ?? ShellIntegrationInstaller.defaultInstallDirectory
        #else
        let root = ShellIntegrationInstaller.defaultInstallDirectory
        #endif
        ShellIntegrationActivation.activateIfPossible(root: root)
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The CalixTests scheme runs this app itself as its unit-test
        // HOST, so this method runs for real, unguarded, against the
        // developer's own ~/.calix before a single test method executes.
        // That already caused a live incident on 2026-03-20 (commit
        // 8a0a76bcc, "Skip global event tap in unit test host
        // environment"): the global event tap was installed for real
        // from the test host. Left ungated, the rest of this method is
        // worse -- it increments the real crash-loop recovery counter
        // and, on terminate, overwrites the real sessions.json (see
        // applicationWillTerminate's own matching gate below); with
        // persistentSessionsEnabled == true in the developer's real
        // UserDefaults, restoreSession()/createNewWindow() would also
        // spawn real persistent calix-session daemons; it starts
        // BrowserServer's real loopback listener; and setupMainMenu()
        // transitively initializes UpdateController.shared, pulling in
        // Sparkle. CalixUITests launches the app-under-test as a
        // separate process with "--uitesting" and no XCTest loaded, so
        // it always evaluates false here and keeps running the full
        // launch unchanged.
        if LaunchEnvironmentPolicy.isUnitTestHost() { return }

        // One-time Calyx -> Calix rename migration. Must run before
        // SessionRootResolver/SessionPersistenceActor.shared are first used
        // (restoreSession() below is the first such use). Skipped under
        // CALIX_UITEST_SESSION_DIR for the same reason SessionPersistenceActor.init
        // bypasses both real paths under that override: UI tests use a private
        // flat test directory and must never touch $HOME/.calyx or $HOME/.calix.
        if ProcessInfo.processInfo.environment["CALIX_UITEST_SESSION_DIR"] == nil {
            let home = URL(fileURLWithPath: SessionRootResolver().resolve(), isDirectory: true)
            SessionDirectoryMigrator.migrateIfNeeded(
                oldRoot: home.appendingPathComponent(".calyx", isDirectory: true),
                newRoot: home.appendingPathComponent(".calix", isDirectory: true)
            )
        }

        // One-time Calyx -> Calix preferences migration. Must run before
        // the first UserDefaults.standard-backed read below (inside
        // applyCalixShellIntegrationIfEnabled(), which reads
        // CommandTrackingSettings.trackingEnabled) -- otherwise that read
        // would silently see defaults instead of the user's existing
        // settings from the old com.calyx.terminal bundle ID.
        PreferencesMigrator.migrateIfNeeded()

        // Wire the real Ghostty-FFI-backed output reader now that we're
        // definitely not in the unit-test host (a GhosttyCommandOutputReader
        // read touches live ghostty FFI, unsafe there).
        CommandLogStore.shared.reader = GhosttyCommandOutputReader()

        // Must run before GhosttyAppController.shared's first access below:
        // ghostty forwards shell-integration scripts to surface children
        // only when GHOSTTY_RESOURCES_DIR is already set in this process's
        // own environment at engine init.
        applyGhosttyResourcesDirEnvironmentIfNeeded()
        applyCalixShellIntegrationIfEnabled()

        // Add CLI to PATH for terminals launched within Calix
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            setenv("PATH", "\(binPath):\(currentPath)", 1)
        }

        let controller = GhosttyAppController.shared
        guard controller.readiness == .ready else {
            logger.critical("GhosttyAppController initialization failed")
            let alert = NSAlert()
            alert.messageText = "Failed to Initialize"
            alert.informativeText = "Terminal engine initialization failed. The application will now exit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        if let app = controller.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }

        setupMainMenu()
        registerNotificationObservers()
        installKeyMonitor()
        installGlobalEventTap()
        SurfacePropertyStore.shared.startObserving()

        browserTabBroker.appDelegate = self
        let browserHandler = BrowserToolHandler(broker: browserTabBroker)
        BrowserServer.shared.toolHandler = browserHandler
        BrowserServer.shared.start()
        NSApp.servicesProvider = self

        // No `--uitesting` bypass here: `restoreSession()` returns false
        // whenever there is no snapshot to restore (see its guard against
        // a nil or empty-`windows` snapshot), and every UI test launches
        // with a fresh, never-before-used `CALIX_UITEST_SESSION_DIR`
        // (`CalixUITestCase.setUp`), so this always falls through to
        // `createNewWindow()` exactly as before for every existing test.
        // Only a test that relaunches with the SAME session dir (the
        // persistence E2E suite) can find a snapshot and take the
        // restore path, which is required for the restored pane to
        // reattach to its pre-restart session instead of a fresh one
        // being created.
        if !restoreSession() {
            if pendingURLs.isEmpty {
                createNewWindow()
                // Demo-recording scenario only (CalixUITests
                // /DemoRecordingScenario.swift): every UI test launches
                // with a fresh session dir (see comment above), so
                // launch always takes THIS branch, not restoreSession()'s
                // -- no equivalent hook is needed there.
                applyDemoWindowFrameIfNeeded()
            }
        }
        // Bug 3c gap-close: a snapshot preserved by a PREVIOUS run's
        // restoreSession() (via preserveSnapshotForRecovery()) still sits
        // on disk at launch even though THIS run never called that method
        // itself -- without this, `session.recoverPreviousSession` would
        // stay unavailable until the next skipped/failed restore, instead
        // of offering the still-pending recovery from before. Mirrors
        // reassertHistoryPersistenceIfNeeded()'s own async-Task-after-launch shape.
        Task { await initializeHasPreservedSessionSnapshotFlag() }
        Task { await agentResumeAdvisor.reassertHistoryPersistenceIfNeeded() }
        // Process any URLs that arrived before launch completed
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        quickTerminalController == nil
    }

    /// Reads and clears `isTerminationConfirmed` — set ahead of time by
    /// `windowShouldClose` when the last-window close path already ran
    /// its own pre-close confirm-quit prompt, so this method doesn't
    /// prompt a second time for the same termination. See
    /// `windowShouldClose` for that last-window pre-close prompt path.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            markAllControllersClosingForShutdown()
            isApplicationTerminating = true
            return .terminateNow
        }

        // Already confirmed (from windowShouldClose on last-window close path)
        if isTerminationConfirmed {
            isTerminationConfirmed = false
            markAllControllersClosingForShutdown()
            isApplicationTerminating = true
            return .terminateNow
        }

        // Cmd+Q path: run confirmations
        if !confirmQuitIfNeeded() {
            return .terminateCancel
        }

        isTerminationConfirmed = true
        // Flag all controllers so windowDidExitFullScreen preserves tracking state
        // during app teardown (the red-button / Cmd+W path sets its own flag).
        markAllControllersClosingForShutdown()
        // R6-A/R6-D (r6-fix-spec.md): app-wide termination signal,
        // alongside markAllControllersClosingForShutdown, consulted by
        // the deferred-reconnect-event drain and windowWillClose's
        // destroy loop (see isApplicationTerminating's own doc comment).
        isApplicationTerminating = true
        return .terminateNow
    }

    private func markAllControllersClosingForShutdown() {
        for wc in windowControllers {
            wc.isClosingForShutdown = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mirrors applicationDidFinishLaunching's own gate (see that
        // method's doc comment for the full incident narrative): a
        // unit-test host's applicationDidFinishLaunching already
        // returned early and never populated windowControllers or
        // appSession, but this notification still fires for real at
        // host process teardown regardless. Without this gate,
        // saveAtTermination/resetRecoveryCounter below would still run
        // against SessionPersistenceActor.shared and write to the
        // developer's real ~/.calix even though nothing in this launch
        // was ever gated by a window/session-emptiness check alone.
        if LaunchEnvironmentPolicy.isUnitTestHost() { return }

        // R6-A/R6-D (r6-fix-spec.md): belt-and-suspenders alongside
        // applicationShouldTerminate's own set, in case this notification
        // ever fires without that method having run first (see
        // isApplicationTerminating's own doc comment).
        isApplicationTerminating = true

        // Give any kill(id:) calls dispatched by an explicit pane/tab
        // close that raced with this quit a short, bounded window to
        // actually finish (see SessionKillTracker's header comment) —
        // otherwise a kill's Task could be torn down mid-Process-spawn,
        // silently leaving the calix-session running as an orphan even
        // though the user asked to end it. Runs regardless of
        // windowControllers/appSession state below, since kills can be
        // in flight even after every window has already closed.
        var killsDrained = false
        Task {
            await SessionKillTracker.drain(timeoutSeconds: 2.0)
            killsDrained = true
        }
        let killDrainDeadline = Date().addingTimeInterval(2.5)
        while !killsDrained, Date() < killDrainDeadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        // Last-window close path already persists synchronously in
        // windowWillClose. This guard's ONLY remaining job is skipping
        // pointless work when there is neither a captured confirm-time
        // pendingTerminationSnapshot nor any live window left to build one
        // from -- saveForTermination()'s own saveAtTermination(_:) call
        // already refuses to let an empty snapshot clobber a non-empty
        // on-disk one, so this is not a correctness gate: a non-nil
        // pendingTerminationSnapshot (the confirm-quit-by-closing-the-
        // last-window route, see that property's own doc comment) must
        // still be saved even though windowControllers/appSession are
        // already emptied by the time this runs.
        let hasLiveWindows = !windowControllers.isEmpty && !appSession.windows.isEmpty
        guard pendingTerminationSnapshot != nil || hasLiveWindows else {
            return
        }

        saveForTermination()
        windowControllers.removeAll()
    }

    func applicationDidChangeOcclusionState(_ notification: Notification) {
        if let app = GhosttyAppController.shared.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.compactMap { url -> String? in
            guard url.isFileURL else {
                logger.warning("Ignoring non-file URL: \(url)")
                return nil
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let path = resolved.path

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                logger.warning("Path does not exist: \(path)")
                return nil
            }
            let dirPath = isDir.boolValue ? path : resolved.deletingLastPathComponent().path
            guard FileManager.default.isReadableFile(atPath: dirPath) else {
                logger.warning("Directory not readable: \(dirPath)")
                return nil
            }
            return dirPath
        }

        guard !directories.isEmpty else { return }

        guard GhosttyAppController.shared.readiness == .ready else {
            pendingURLs.append(contentsOf: urls)
            return
        }

        for dir in directories {
            openWindowAtPath(dir)
        }
    }

    // MARK: - Notification Observers

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleNewTab(_:)), name: .ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(handleNewWindow(_:)), name: .ghosttyNewWindow, object: nil)
    }

    @objc private func handleNewTab(_ notification: Notification) {
        // Find the window controller that owns the source surface
        guard let surfaceView = notification.object as? SurfaceView,
              let window = surfaceView.window,
              let wc = windowControllers.first(where: { $0.window === window }) else {
            // No source — create tab in the key window's controller
            if let keyWC = windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                keyWC.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
            }
            return
        }
        wc.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
    }

    @objc private func handleNewWindow(_ notification: Notification) {
        createNewWindow()
    }

    // MARK: - Window Management

    @objc func createNewWindow() {
        openNewWindow(initialHost: nil)
    }

    /// `initialHost` (P5, remote sessions): forwarded to
    /// `CalixWindowController.init(initialHost:)` for the new window's
    /// sole initial tab. `nil` (`createNewWindow()` above, every
    /// existing caller) is unchanged, a local window exactly as before
    /// this parameter existed. Reached by `spawnRemoteSessionTab(host:)`
    /// when no key window controller exists yet to add a tab to. Named
    /// distinctly from `createNewWindow()` (rather than an overload of
    /// it) since `#selector(createNewWindow)` above resolves by base
    /// name alone and would become ambiguous with a same-named overload.
    private func openNewWindow(initialHost: String?) {
        let initialTab = Tab()
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)

        let wc = CalixWindowController(windowSession: windowSession, initialHost: initialHost)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    /// `--demo-window-frame=<W>x<H>` (DemoWindowFrameArgument.parse):
    /// forces the just-created main window to a fixed, screen-recording-
    /// friendly size and position, so the scripted demo scenario
    /// (CalixUITests/DemoRecordingScenario.swift) always frames
    /// identically regardless of this machine's actual screen size or
    /// `CalixWindowController`'s own 800x600-then-`center()` default.
    /// Gated on `--uitesting` (mirrors every other `--uitesting`-only
    /// behavior in this file) even though a production launch never
    /// receives `--demo-window-frame` in the first place -- an explicit
    /// gate here keeps the intent readable at the call site, per this
    /// argument's own spec (only ever consulted alongside `--uitesting`).
    private func applyDemoWindowFrameIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"),
              let size = DemoWindowFrameArgument.parse(arguments),
              let window = windowControllers.last?.window else {
            return
        }
        // Same NSScreen.main?.visibleFrame fallback shape as
        // restoreWindow(_:)'s own screen-clamping above, for consistency.
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let origin = CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    #if DEBUG
    /// Test seam (spawnRemoteSessionTab latent-bug RED phase, confirmed
    /// in scope): called with the chosen target controller immediately
    /// before `spawnRemoteSessionTab` calls `keyWC.createNewTab(host:)`.
    /// Needed because `createNewTab` itself would silently no-op if
    /// driven for real here: it guards on `GhosttyAppController.shared.app`,
    /// which is `nil` in this test host (see
    /// `CalixWindowControllerCreateManagedSurfaceRemoteHostTests`'s own
    /// dummy-app workaround for the identical constraint) -- so there is
    /// no observable effect to assert on without this hook. `nil` (the
    /// default) leaves production behavior unchanged: `createNewTab`
    /// still runs for real when this hook is nil. DO NOT use from
    /// production code.
    var _spawnRemoteSessionTabAddTabHookForTesting: ((CalixWindowController) -> Void)?

    /// Test seam (spawnRemoteSessionTab latent-bug RED phase): called
    /// immediately before `spawnRemoteSessionTab` calls
    /// `openNewWindow(initialHost:)`, mirroring
    /// `_attachWindowCreationHookForTesting`'s exact "intercept right
    /// before the actually-unsafe call" pattern -- `openNewWindow`
    /// constructs a real `CalixWindowController` and calls
    /// `showWindow(nil)` for real, confirmed unsafe to drive in this test
    /// host (see `AppDelegateAttachWindowTests`'s header for the
    /// identical hang). `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _spawnRemoteSessionTabNewWindowHookForTesting: (() -> Void)?
    #endif

    /// `SessionBrowserModel.onRemoteSessionRequested`'s target (Session
    /// Browser's remote-host picker, `SessionBrowserWindowController
    /// .attachRemote(_:)`): spawns a new tab against `host` in the key
    /// window's controller if one exists -- mirrors `handleNewTab`'s own
    /// key-window lookup for a local ghostty-originated new tab --
    /// otherwise opens a fresh window whose sole initial tab spawns
    /// against `host`, reaching a window controller the same way
    /// `attachWindow` always does for a session with no live surface
    /// anywhere yet.
    ///
    /// LATENT BUG (confirmed, in scope for this cycle's Green phase, same
    /// round as the session-browser attach-as-tab fix): every real caller
    /// of this method fires from inside the Session Browser's own button
    /// action, at which point the Session Browser's own window (not any
    /// `CalixWindowController`'s window) is key -- so
    /// `windowControllers.first(where: { $0.window?.isKeyWindow == true })`
    /// never matches in practice, and this method always falls through to
    /// `openNewWindow`, even when a main window is already open. See
    /// `AppDelegateAttachSessionAsTabTests`'s scope-1 fix for the
    /// identical defect and chosen resolution
    /// (`windowControllers.first(where: { $0.window?.isKeyWindow == true }) ?? windowControllers.first`,
    /// team-confirmed); this method's own fix is Green-phase work, not
    /// yet applied here -- the two new hooks above exist solely to make
    /// today's (buggy) behavior observable without hanging the test
    /// process, see `AppDelegateSpawnRemoteSessionTabWindowLookupTests`.
    func spawnRemoteSessionTab(host: String?) {
        // FIX (see this method's own doc comment): the real caller fires
        // from inside the Session Browser's own button action, at which
        // point the Session Browser's plain NSWindow, not any
        // CalixWindowController's window, is key -- so an isKeyWindow-
        // only lookup never matched in practice. Prefer the actually-key
        // window if one exists, but fall back to the first available
        // controller instead of dead-ending on the Session Browser panel
        // holding key status.
        if let targetWC = windowControllers.first(where: { $0.window?.isKeyWindow == true }) ?? windowControllers.first {
            #if DEBUG
            _spawnRemoteSessionTabAddTabHookForTesting?(targetWC)
            if _spawnRemoteSessionTabAddTabHookForTesting != nil { return }
            #endif
            targetWC.createNewTab(host: host)
            return
        }
        #if DEBUG
        if let hook = _spawnRemoteSessionTabNewWindowHookForTesting {
            hook()
            return
        }
        #endif
        openNewWindow(initialHost: host)
    }

    func toggleQuickTerminal() {
        if quickTerminalController == nil {
            quickTerminalController = QuickTerminalController()
        }
        quickTerminalController?.toggle()
    }

    func openWindowAtPath(_ pwd: String) {
        let initialTab = Tab(pwd: pwd)
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)
        let wc = CalixWindowController(windowSession: windowSession)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    /// Session Browser's "Attach" action for a *running* session with
    /// no live surface in this process (`SessionBrowserRow.isOrphan`):
    /// opens a new window whose sole tab reattaches to `sessionID`.
    /// Reuses `restoreTabSurfaces`/`fallbackCreateSurface` — the same
    /// machinery a snapshot restore uses — with a placeholder leaf UUID
    /// standing in for the "old leaf" `tab.sessionRefs` key
    /// `restoreTabSurfaces` expects, so this is exactly the single-tab,
    /// single-leaf case of a snapshot restore rather than a second,
    /// parallel code path.
    #if DEBUG
    /// Test seam (P4 round-4 fix RED phase): when non-nil, consulted
    /// right where `attachWindow` is about to construct a real window
    /// and ghostty surface, invoked instead of that real work, which
    /// never runs. Driving `attachWindow` end-to-end with a live
    /// surface is unsafe from this test host (confirmed empirically:
    /// it hangs the XCTest process indefinitely, no other test in
    /// this suite creates a real ghostty surface or calls
    /// `showWindow`). This seam lets `AppDelegateAttachWindowTests`
    /// observe WHETHER `attachWindow` reaches its window-creation step
    /// at all, exactly what F6's double-attach guard must prevent for
    /// an already-attached sessionID, without ever performing that
    /// real, unsafe-to-test work. Does not affect production behavior:
    /// `nil` (the default) leaves this line as a no-op; every guard
    /// ABOVE this point (including the fix this seam was added for)
    /// still runs for real, unmodified. DO NOT use from production
    /// code.
    var _attachWindowCreationHookForTesting: (() -> Void)?

    /// Test seam (P5, remote sessions, contract 3c): called with the
    /// constructed placeholder `tab`, immediately before
    /// `_attachWindowCreationHookForTesting`'s own check -- today's hook
    /// fires and returns BEFORE the placeholder tab is even constructed,
    /// so no existing seam can observe the `SessionRef` it would have
    /// produced. A second, independent, purely additive observer instead
    /// of changing that hook's signature, mirroring `AppDelegate
    /// ._createSurfaceWithPwdCommandObserverForTesting`'s/
    /// `CalixWindowController._performReconnectCommandObserverForTesting`'s
    /// identical reasoning. `nil` (the default) leaves production
    /// behavior unchanged; every existing test using
    /// `_attachWindowCreationHookForTesting` alone is unaffected. DO NOT
    /// use from production code.
    var _attachWindowPlaceholderTabObserverForTesting: ((Tab) -> Void)?
    #endif

    func attachWindow(sessionID: String, cwd: String?, host: String? = nil) {
        guard let app = GhosttyAppController.shared.app else { return }

        // F6 (S1, HIGH, r4-fix-spec.md): a sessionID already registered
        // in SessionSurfaceMap already has a live surface somewhere in
        // this process. This covers the session browser's double-click/
        // stale-row race (rows only refresh on poll, and this method has
        // no debounce of its own). Focus that existing surface's window
        // instead of creating a second one. Checked BEFORE the
        // test-creation hook below, so AppDelegateAttachWindowTests can
        // observe the guard firing without ever reaching real window/
        // surface creation.
        //
        // R6-D (r6-fix-spec.md, sweep finding): `focusWindowForExistingSession`
        // returns `false` for a STALE mapping (registered, but no
        // controller anywhere actually contains the surfaceID, e.g. left
        // behind by a non-terminating window close), having already
        // unregistered it, in which case this falls through to a fresh
        // attach below instead of silently doing nothing.
        if SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil {
            if focusWindowForExistingSession(sessionID: sessionID) {
                return
            }
        }

        let placeholderLeafID = UUID()
        let tab = Tab(
            // NSHomeDirectory() ignores a HOME env override (P4 root-resolver lesson); use the canonical resolver.
            title: SessionTabTitle.fromCwd(cwd, home: SessionRootResolver().resolve()),
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
        )

        // P5 (remote sessions): Tab's own init has no side effects (no
        // FFI, no SessionSurfaceMap/global registration), so constructing
        // it ahead of the creation hook below is behaviorally inert for
        // every existing caller -- the hook still fires (and still
        // returns early) at exactly the same decision point relative to
        // every OTHER guard, just after this (side-effect-free) tab value
        // now exists to observe.
        #if DEBUG
        _attachWindowPlaceholderTabObserverForTesting?(tab)
        if let hook = _attachWindowCreationHookForTesting {
            hook()
            return
        }
        #endif

        let windowSession = WindowSession(initialTab: tab)
        let (window, wc) = makeRestoringWindowController(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            windowSession: windowSession
        )

        // R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking): starts the
        // fetch without waiting on it, window/surface creation proceeds
        // immediately (see fetchSessionsForAgentResume's doc comment).
        agentResumeAdvisor.fetchSessionsForAgentResume()
        let restored = restoreTabSurfaces(tab: tab, app: app, window: window)
        guard restored || fallbackCreateSurface(tab: tab, app: app, window: window) else {
            cleanupFailedWindow(window, windowSession, wc, message: "Failed to attach window for session \(sessionID)")
            return
        }

        wc.activateRestoredSession()
        wc.showWindow(nil)
    }

    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase, R6-E): when non-nil, called
    /// instead of the real `wc.showWindow(nil)` inside
    /// `focusWindowForExistingSession`, mirroring
    /// `_attachWindowCreationHookForTesting`'s "hook right before the
    /// actually-unsafe-to-test call" pattern (see that seam's doc
    /// comment): no other test in this suite calls `showWindow` for real,
    /// and this avoids the same unverified risk for the "found an
    /// existing controller" branch. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _focusWindowForExistingSessionShowHookForTesting: ((CalixWindowController) -> Void)?
    #endif

    /// F6: brings the window already hosting `sessionID`'s live surface
    /// to the front, instead of `attachWindow` creating a second one for
    /// the same session. Returns `true` once a live controller was found
    /// and focused, `false` when the mapping was stale (see below); the
    /// caller (`attachWindow`) falls through to a fresh attach on `false`.
    ///
    /// R6-D (r6-fix-spec.md, sweep finding): when NO controller contains
    /// the mapped surfaceID at all (a stale mapping left behind by, e.g.,
    /// a non-terminating window close that unregistered every OTHER
    /// tracked surface but somehow left this one stale, or a window
    /// that's mid-teardown, skipped below), unregisters the stale entry
    /// and returns `false` instead of silently doing nothing.
    ///
    /// R6-E (r6-fix-spec.md, A2): also activates the tab/group
    /// containing `surfaceID` (`CalixWindowController.activateTabContaining`,
    /// reusing that controller's existing tab-switch logic instead of
    /// reimplementing containment, reuse finding F3f) before showing the
    /// window, so a session living in a background tab is actually
    /// visible, not just the window with whatever tab happened to
    /// already be active. Skips any controller mid-teardown
    /// (`isClosingForShutdown`), since that window's surfaces are about
    /// to be torn down or preserved into a snapshot, not a valid focus
    /// target.
    private func focusWindowForExistingSession(sessionID: String) -> Bool {
        guard let surfaceID = SessionSurfaceMap.shared.surfaceID(for: sessionID) else { return false }
        guard let wc = windowControllers.first(where: { controller in
            !controller.isClosingForShutdown && controller.windowSession.groups.contains { group in
                group.tabs.contains { $0.registry.contains(surfaceID) }
            }
        }) else {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            return false
        }

        wc.activateTabContaining(surfaceID: surfaceID)

        #if DEBUG
        if let hook = _focusWindowForExistingSessionShowHookForTesting {
            hook(wc)
            return true
        }
        #endif
        wc.showWindow(nil)
        return true
    }

    #if DEBUG
    /// Test seam (session browser Attach-consistency RED phase): when
    /// non-nil, called with the `SessionAttachRoutingPolicy.Decision`
    /// `attachSessionAsTab` just computed, immediately before acting on
    /// it. Mirrors `_attachWindowPlaceholderTabObserverForTesting`'s
    /// "new, narrow, DEBUG-gated, nil-by-default" shape: `nil` (the
    /// default) leaves production behavior unchanged. DO NOT use from
    /// production code.
    var _attachSessionAsTabRoutingObserverForTesting: ((SessionAttachRoutingPolicy.Decision) -> Void)?
    #endif

    /// Session Browser's "Attach" action (`SessionBrowserWindowController
    /// .attach(_:)`'s single entry point, replacing a direct
    /// `attachWindow` call): keeps the local-attach flow consistent with
    /// the sibling remote-session flow (`spawnRemoteSessionTab(host:)`),
    /// per `SessionAttachRoutingPolicy`'s own doc comment. Computes both
    /// of that policy's inputs from real `AppDelegate` state --
    /// `isAttachedHere` from `SessionSurfaceMap` (identical to
    /// `attachWindow`'s own F6 guard), `hasAvailableWindow` from the same
    /// "prefer the key window, else the first available one" lookup
    /// `spawnRemoteSessionTab` now also uses (see that method's own doc
    /// comment for why an `isKeyWindow`-only lookup never matches a real
    /// main window from either call site: both fire from inside the
    /// Session Browser's own button action, at which point the Session
    /// Browser's plain `NSWindow`, not any `CalixWindowController`'s
    /// window, is key) -- and dispatches to the matching action.
    ///
    func attachSessionAsTab(sessionID: String, cwd: String?, host: String? = nil) {
        let isAttachedHere = SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil
        // Same "prefer key, else first" fallback as `spawnRemoteSessionTab`'s
        // own fix, and for the identical reason: whichever controller this
        // resolves to is also the one `.attachAsTab` below adds the new tab
        // to, so `hasAvailableWindow` and the eventual target come from the
        // same lookup.
        let targetWindowController = windowControllers.first(where: { $0.window?.isKeyWindow == true })
            ?? windowControllers.first
        let decision = SessionAttachRoutingPolicy.decide(
            isAttachedHere: isAttachedHere, hasAvailableWindow: targetWindowController != nil
        )
        #if DEBUG
        _attachSessionAsTabRoutingObserverForTesting?(decision)
        #endif
        switch decision {
        case .focusExistingSurface:
            if focusWindowForExistingSession(sessionID: sessionID) { return }
            // Stale mapping: focusWindowForExistingSession already
            // unregistered it above (R6-D precedent). Re-decide now that
            // isAttachedHere is no longer true, exactly one recursion.
            attachSessionAsTab(sessionID: sessionID, cwd: cwd, host: host)
        case .attachAsTab:
            if let target = targetWindowController {
                attachSessionAsNewTab(sessionID: sessionID, cwd: cwd, host: host, in: target)
            }
        case .attachAsNewWindow:
            attachWindow(sessionID: sessionID, cwd: cwd, host: host)
        }
    }

    #if DEBUG
    /// Test seam (attached-tab placeholder title RED phase): mirrors
    /// `_attachWindowPlaceholderTabObserverForTesting` exactly -- same
    /// "new, narrow, DEBUG-gated, nil-by-default, purely additive"
    /// shape, just for `attachSessionAsNewTab`'s placeholder `Tab`
    /// instead of `attachWindow`'s. `attachSessionAsNewTab` is private
    /// and has no other seam that observes the placeholder tab it
    /// constructs before wiring it into `target`, so without this,
    /// nothing in this file's `.attachAsTab` path could pin the tab's
    /// initial `title`/`pwd`. `nil` (the default) leaves production
    /// behavior unchanged; every existing test reaching this method
    /// (e.g. `AppDelegateAttachSessionAsTabTests`'s `.attachAsTab` row)
    /// is unaffected. DO NOT use from production code.
    var _attachSessionAsNewTabPlaceholderTabObserverForTesting: ((Tab) -> Void)?

    /// Test seam: mirrors `_attachWindowCreationHookForTesting` exactly,
    /// for `attachSessionAsNewTab`'s `.attachAsTab` branch. When non-nil,
    /// called immediately after the placeholder observer above and BEFORE
    /// this method reaches `GhosttyAppController.shared.app` /
    /// `restoreTabSurfaces` / `fallbackCreateSurface` / `attachRestoredTab`
    /// -- the same real, ghostty-FFI-driven surface + PTY creation
    /// `attachWindow` guards behind its own creation hook. Without this,
    /// every test driving the `.attachAsTab` route (an unregistered
    /// sessionID with a window available) spawns a real ghostty surface
    /// and a real login-shell PTY in the unit-test host, which leak across
    /// the process-wide `SurfaceRegistry`/`SessionSurfaceMap`/
    /// `GhosttyAppController.shared` singletons and crash the XCTest host
    /// during a later surface teardown (confirmed unsafe, identical to the
    /// hang/crash `_attachWindowCreationHookForTesting`'s own doc comment
    /// describes). `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _attachSessionAsNewTabCreationHookForTesting: (() -> Void)?
    #endif

    /// `.attachAsTab`'s real work: reuses `restoreTabSurfaces`/
    /// `fallbackCreateSurface` -- the same machinery `attachWindow` uses
    /// to reattach `sessionID` to a placeholder leaf -- but wires the
    /// result into `target`'s EXISTING window as a new tab
    /// (`CalixWindowController.attachRestoredTab(_:)`) instead of
    /// constructing a brand-new window. Deliberately does not route
    /// through `createNewTab`/`SessionSpawnPlanner`: both of those spawn
    /// a brand-new session (`createManagedSurface`), not a reattach to
    /// an already-running one. A total surface-creation failure leaves
    /// `target` untouched (the tab is only wired in on success), so no
    /// window/group cleanup is needed the way `attachWindow`'s own
    /// failure path needs `cleanupFailedWindow`.
    private func attachSessionAsNewTab(sessionID: String, cwd: String?, host: String?, in target: CalixWindowController) {
        guard let app = GhosttyAppController.shared.app, let window = target.window else { return }

        let placeholderLeafID = UUID()
        let tab = Tab(
            // NSHomeDirectory() ignores a HOME env override (P4 root-resolver lesson); use the canonical resolver.
            title: SessionTabTitle.fromCwd(cwd, home: SessionRootResolver().resolve()),
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
        )

        #if DEBUG
        _attachSessionAsNewTabPlaceholderTabObserverForTesting?(tab)
        if let hook = _attachSessionAsNewTabCreationHookForTesting {
            hook()
            return
        }
        #endif

        agentResumeAdvisor.fetchSessionsForAgentResume()
        let restored = restoreTabSurfaces(tab: tab, app: app, window: window)
        guard restored || fallbackCreateSurface(tab: tab, app: app, window: window) else {
            logger.error("Failed to attach tab for session \(sessionID, privacy: .public)")
            return
        }

        target.attachRestoredTab(tab)
    }

    /// F11 (V13, WARNING, r4-fix-spec.md): the window-construction +
    /// registration boilerplate shared identically by `attachWindow` and
    /// `restoreWindow`. Does NOT cover the tab-restoration control flow
    /// around it (single guard vs. loop+accumulator) or the fullscreen
    /// branch, which genuinely differ and must stay separate (see
    /// r4-verdicts.md V13). Registers `windowSession` with `appSession`
    /// and appends the new controller to `windowControllers` as a side
    /// effect, exactly matching both callers' prior inline code.
    private func makeRestoringWindowController(
        contentRect: NSRect,
        windowSession: WindowSession
    ) -> (window: CalixWindow, controller: CalixWindowController) {
        appSession.addWindow(windowSession)
        let window = CalixWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let wc = CalixWindowController(window: window, windowSession: windowSession, restoring: true)
        windowControllers.append(wc)
        return (window, wc)
    }

    /// F11 (V13, WARNING): the failure-cleanup triple shared identically
    /// by `attachWindow` and `restoreWindow` when no surface could be
    /// restored at all. Closes the just-created (never shown) window,
    /// undoes its `appSession`/`windowControllers` registration, and
    /// logs `message`. Logged `.public` (matching this file's other
    /// session-ID log statements, e.g. `performReconnect`'s); the
    /// `.private` this exact line used before extraction was an
    /// inconsistency, not a deliberate secrecy decision, since every
    /// other session-ID log statement in this codebase already uses
    /// `.public`.
    private func cleanupFailedWindow(
        _ window: CalixWindow,
        _ windowSession: WindowSession,
        _ wc: CalixWindowController,
        message: String
    ) {
        window.close()
        appSession.removeWindow(id: windowSession.id)
        windowControllers.removeAll { $0 === wc }
        logger.error("\(message, privacy: .public)")
    }

    func removeWindowController(_ controller: CalixWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
        if !windowControllers.isEmpty {
            requestSave()
        } else if quickTerminalController == nil {
            NSApp.terminate(nil)
        }
    }

    func isClosingLastManagedWindow(_ controller: CalixWindowController) -> Bool {
        windowControllers.count == 1 && windowControllers.first === controller
    }

    /// True when closing `controller` would empty the last managed
    /// window and no quick terminal is open to keep the app alive —
    /// i.e. closing it would terminate the app. Consulted by
    /// `CalixWindowController`'s close paths (`windowShouldClose`,
    /// `closeTab`, `closeActiveGroup`, `closeAllTabsInGroup`,
    /// `confirmQuitBeforeCloseIfWouldTerminate`) to decide whether a
    /// pre-teardown confirm-quit prompt is needed at all.
    func closingWouldTerminate(_ controller: CalixWindowController) -> Bool {
        isClosingLastManagedWindow(controller) && quickTerminalController == nil
    }

    /// Distinguishes the two confirm-quit wordings: `.killProcesses`
    /// (the default — a real process is about to be killed) vs.
    /// `.detachOnly` (the session will keep running headless in the
    /// daemon, detached rather than killed). Passed through by
    /// `CalixWindowController.confirmQuitBeforeCloseIfWouldTerminate`
    /// from whichever close path is asking (kill vs. detach semantics).
    enum ConfirmQuitMode {
        case killProcesses
        case detachOnly
    }

    /// Set for the duration of `confirmQuitIfNeeded`'s `alert.runModal()`
    /// call (see Patch 2's header comment there). While `true`, other
    /// MainActor entry points that could mutate window/tab state out
    /// from under an in-flight confirm-quit prompt, currently
    /// `CalixWindowController.handleShowChildExitedNotification` and
    /// `handleSessionReconnectDecision`, defer their work instead of
    /// acting immediately (see each's doc comment). The `didSet` below
    /// posts `.calixConfirmingQuitDidEnd` on the `true` -> `false`
    /// transition so every live `CalixWindowController` can replay
    /// whatever it deferred (F4, r4-fix-spec.md). This fires for both
    /// the real `alert.runModal()` return path below AND the
    /// `_setConfirmingQuitForTesting` test seam, since both assign this
    /// same property.
    private(set) var isConfirmingQuit: Bool = false {
        didSet {
            guard oldValue, !isConfirmingQuit else { return }
            NotificationCenter.default.post(name: .calixConfirmingQuitDidEnd, object: nil)
        }
    }

    #if DEBUG
    /// Test seam (P4 round-4 fix RED phase): lets tests simulate the
    /// `isConfirmingQuit` gate flipping on/off without driving a real,
    /// blocking `NSAlert.runModal()` through `confirmQuitIfNeeded`,
    /// mirrors `SurfaceRegistry._testInsert`'s naming/gating convention.
    /// Production code only ever toggles `isConfirmingQuit` itself, from
    /// within `confirmQuitIfNeeded`'s own bracket. DO NOT use from
    /// production code.
    func _setConfirmingQuitForTesting(_ value: Bool) {
        isConfirmingQuit = value
    }
    #endif

    /// Returns true if the app should proceed with quit, false if user
    /// cancelled. Called both from `applicationShouldTerminate` (the
    /// Cmd+Q / "Quit Calix" path) and, via
    /// `CalixWindowController.confirmQuitBeforeCloseIfWouldTerminate`,
    /// from individual close paths (`windowShouldClose`, `closeTab`,
    /// `closeActiveGroup`, `closeAllTabsInGroup`,
    /// `closeFocusedSessionSurface`, `handleReconnectGiveUp`) BEFORE
    /// they tear anything down, when closing would terminate the app —
    /// see `closingWouldTerminate`. `mode` selects the wording: a
    /// kill-semantics close (default) warns that a running process is
    /// about to end; a detach-semantics close (`.detachOnly`) explains
    /// the session will keep running headless instead.
    func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
        // Check for running processes
        guard let app = GhosttyAppController.shared.app,
              ghostty_app_needs_confirm_quit(app) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Calix?"
        switch mode {
        case .killProcesses:
            alert.informativeText = "A process is still running. Do you want to quit?"
        case .detachOnly:
            alert.informativeText = "The session will be detached and remain running in the background. The daemon will keep it alive for later reattachment. Do you want to quit?"
        }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        isConfirmingQuit = true
        let response = alert.runModal()
        isConfirmingQuit = false

        return response != .alertSecondButtonReturn
    }

    func applyCurrentGhosttyConfigToAllWindows() {
        for controller in windowControllers {
            controller.applyCurrentGhosttyConfig()
        }
    }

    // MARK: - Main Menu

    /// Not `private` any more (session-browser menu-item RED phase):
    /// mirrors `closeAllTabsInGroup(id:)`'s/`processChildExited`'s/
    /// `handleSessionReconnectDecision`'s own identical "un-privated for
    /// direct test access" precedent. Builds and assigns a fresh
    /// `NSApp.mainMenu` -- pure menu/item construction, no ghostty
    /// surface, no window, no async work -- so, unlike `attachWindow`/
    /// `showWindow`, driving it directly from a test is safe (confirmed:
    /// see `AppDelegateSessionBrowserMenuItemTests`).
    func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Calix", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        if !UpdateController.shared.isHomebrew {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            appMenu.addItem(updateItem)
        }
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        let secureInputItem = NSMenuItem(title: "Secure Keyboard Entry", action: #selector(toggleSecureInput(_:)), keyEquivalent: "")
        appMenu.addItem(secureInputItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Calix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Calix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Window", action: #selector(createNewWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(CalixWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Browser Tab", action: #selector(CalixWindowController.newBrowserTab(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())

        // Split actions live directly under File to match Ghostty's menu structure.
        let splitRightItem = NSMenuItem(
            title: "Split Right",
            action: #selector(SurfaceView.splitRight(_:)),
            keyEquivalent: "d")
        splitRightItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(splitRightItem)

        let splitLeftItem = NSMenuItem(
            title: "Split Left",
            action: #selector(SurfaceView.splitLeft(_:)),
            keyEquivalent: "")
        fileMenu.addItem(splitLeftItem)

        let splitDownItem = NSMenuItem(
            title: "Split Down",
            action: #selector(SurfaceView.splitDown(_:)),
            keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(splitDownItem)

        let splitUpItem = NSMenuItem(
            title: "Split Up",
            action: #selector(SurfaceView.splitUp(_:)),
            keyEquivalent: "")
        fileMenu.addItem(splitUpItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(CalixWindowController.closeTab(_:)), keyEquivalent: "w")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenu.addItem(.separator())

        // Parent "Find" submenu item has no action of its own — clicking it
        // only expands the submenu (which exposes Find…, Find Next, Find
        // Previous). Earlier revisions wired #selector(performFindAction:) on
        // the parent as a workaround for XCUI predicate-based firstMatch
        // landing on the submenu parent before its child; that workaround was
        // unsafe (AppKit could fire the parent action alongside submenu
        // expansion) and has been replaced with a tightened predicate in the
        // UI tests that selects "Find…" directly.
        let findMenuItem = NSMenuItem(
            title: "Find",
            action: nil,
            keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenuItem.submenu = findMenu

        let findStartItem = NSMenuItem(
            title: "Find…",
            action: #selector(SurfaceView.performFindAction(_:)),
            keyEquivalent: "f")
        findStartItem.keyEquivalentModifierMask = [.command]
        findMenu.addItem(findStartItem)

        let findNextItem = NSMenuItem(
            title: "Find Next",
            action: #selector(SurfaceView.findNext(_:)),
            keyEquivalent: "g")
        findNextItem.keyEquivalentModifierMask = [.command]
        findMenu.addItem(findNextItem)

        let findPreviousItem = NSMenuItem(
            title: "Find Previous",
            action: #selector(SurfaceView.findPrevious(_:)),
            keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPreviousItem)

        editMenu.addItem(findMenuItem)

        editMenu.addItem(.separator())
        let composeItem = NSMenuItem(
            title: "Compose Input",
            action: #selector(CalixWindowController.toggleComposeOverlay),
            keyEquivalent: "e"
        )
        composeItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(composeItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(CalixWindowController.toggleSidebar),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)

        viewMenu.addItem(.separator())

        let paletteItem = NSMenuItem(
            title: "Command Palette",
            action: #selector(CalixWindowController.toggleCommandPalette),
            keyEquivalent: "p"
        )
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(paletteItem)

        viewMenu.addItem(.separator())

        viewMenu.addItem(
            withTitle: "Quick Terminal",
            action: #selector(handleToggleQuickTerminal),
            keyEquivalent: ""
        )

        let sessionBrowserItem = NSMenuItem(
            title: "Session Browser",
            action: #selector(openSessionBrowser(_:)),
            keyEquivalent: "b"
        )
        sessionBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(sessionBrowserItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Use a custom selector instead of NSWindow.toggleFullScreen(_:) so
        // AppKit doesn't rewrite the menu title to "Enter/Exit Full Screen".
        // Matches Ghostty's `toggleGhosttyFullScreen:` approach.
        let fullScreenItem = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(CalixWindowController.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreenItem)

        windowMenu.addItem(.separator())

        let focusSplitMenuItem = NSMenuItem(title: "Focus Split", action: nil, keyEquivalent: "")
        let focusSplitMenu = NSMenu(title: "Focus Split")
        focusSplitMenuItem.submenu = focusSplitMenu

        let focusUpItem = NSMenuItem(
            title: "Focus Split Up",
            action: #selector(SurfaceView.focusSplitUp(_:)),
            keyEquivalent: String(Unicode.Scalar(NSUpArrowFunctionKey)!))
        focusUpItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusUpItem)

        let focusDownItem = NSMenuItem(
            title: "Focus Split Down",
            action: #selector(SurfaceView.focusSplitDown(_:)),
            keyEquivalent: String(Unicode.Scalar(NSDownArrowFunctionKey)!))
        focusDownItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusDownItem)

        let focusLeftItem = NSMenuItem(
            title: "Focus Split Left",
            action: #selector(SurfaceView.focusSplitLeft(_:)),
            keyEquivalent: String(Unicode.Scalar(NSLeftArrowFunctionKey)!))
        focusLeftItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusLeftItem)

        let focusRightItem = NSMenuItem(
            title: "Focus Split Right",
            action: #selector(SurfaceView.focusSplitRight(_:)),
            keyEquivalent: String(Unicode.Scalar(NSRightArrowFunctionKey)!))
        focusRightItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusRightItem)

        windowMenu.addItem(focusSplitMenuItem)

        windowMenu.addItem(.separator())

        // Tab navigation via menu
        let nextTabItem = NSMenuItem(title: "Select Next Tab", action: #selector(CalixWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Select Previous Tab", action: #selector(CalixWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevTabItem)

        let jumpUnreadItem = NSMenuItem(title: "Jump to Unread Tab", action: #selector(CalixWindowController.jumpToMostRecentUnreadTab), keyEquivalent: "u")
        jumpUnreadItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(jumpUnreadItem)

        windowMenu.addItem(.separator())

        // Cmd+1-9 tab selection — collapsed into a submenu so the Window menu
        // doesn't carry 9 sibling rows.
        let selectTabMenuItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        let selectTabMenu = NSMenu(title: "Select Tab")
        selectTabMenuItem.submenu = selectTabMenu
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(i)")
            item.target = self
            item.tag = i - 1
            selectTabMenu.addItem(item)
        }
        windowMenu.addItem(selectTabMenuItem)

        windowMenu.addItem(.separator())

        let groupMenuItem = NSMenuItem(title: "Group", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu(title: "Group")
        groupMenuItem.submenu = groupMenu

        let newGroupItem = NSMenuItem(
            title: "New Group",
            action: #selector(CalixWindowController.newGroup(_:)),
            keyEquivalent: "n")
        newGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(newGroupItem)

        let closeGroupItem = NSMenuItem(
            title: "Close Group",
            action: #selector(CalixWindowController.closeGroup(_:)),
            keyEquivalent: "w")
        closeGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(closeGroupItem)

        groupMenu.addItem(.separator())

        let nextGroupItem = NSMenuItem(
            title: "Next Group",
            action: #selector(CalixWindowController.nextGroup(_:)),
            keyEquivalent: "]")
        nextGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(nextGroupItem)

        let prevGroupItem = NSMenuItem(
            title: "Previous Group",
            action: #selector(CalixWindowController.previousGroup(_:)),
            keyEquivalent: "[")
        prevGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(prevGroupItem)

        windowMenu.addItem(groupMenuItem)

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Session Persistence

    /// Session save/restore/recovery orchestration lives on
    /// SessionRestoreCoordinator (SessionRestoreCoordinator.swift); this
    /// AppDelegate keeps only the closures it injects (window/tab
    /// construction and agent-resume daemon-query infra, both out of
    /// scope for that extraction -- see the coordinator's own header)
    /// plus the thin forwarders below that preserve AppDelegate's public
    /// surface byte-for-byte for existing call sites and tests.
    private(set) lazy var sessionRestoreCoordinator: SessionRestoreCoordinator = SessionRestoreCoordinator(
        windowControllers: { [weak self] in self?.windowControllers ?? [] },
        restoreWindow: { [weak self] snap in self?.restoreWindow(snap) ?? false },
        fetchSessionsForAgentResume: { [weak self] in self?.agentResumeAdvisor.fetchSessionsForAgentResume() },
        hasRunningPersistentSessions: { [weak self] in await self?.hasRunningPersistentSessions() ?? false }
    )

    func requestSave() {
        sessionRestoreCoordinator.requestSave()
    }

    func saveImmediately() {
        sessionRestoreCoordinator.saveImmediately()
    }

    func saveForTermination() {
        sessionRestoreCoordinator.saveForTermination(pendingSnapshot: pendingTerminationSnapshot)
    }

    #if DEBUG
    /// Test seam: overrides the SessionPersistenceActor instance
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:) resets,
    /// instead of SessionPersistenceActor.shared. DO NOT use from
    /// production code.
    var _sessionPersistenceActorForTesting: SessionPersistenceActor? {
        get { sessionRestoreCoordinator.sessionPersistenceActorForTesting }
        set { sessionRestoreCoordinator.sessionPersistenceActorForTesting = newValue }
    }
    #endif

    func scheduleRecoveryCounterResetAfterStableLaunch(delay: Duration = .seconds(5)) {
        sessionRestoreCoordinator.scheduleRecoveryCounterResetAfterStableLaunch(delay: delay)
    }

    var hasPreservedSessionSnapshot: Bool {
        sessionRestoreCoordinator.hasPreservedSessionSnapshot
    }

    #if DEBUG
    /// Test seam: mirrors _setApplicationTerminatingForTesting's
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setHasPreservedSessionSnapshotForTesting(_ value: Bool) {
        sessionRestoreCoordinator._setHasPreservedSessionSnapshotForTesting(value)
    }
    #endif

    var isRecovering: Bool {
        sessionRestoreCoordinator.isRecovering
    }

    #if DEBUG
    /// Test seam: mirrors `_setHasPreservedSessionSnapshotForTesting`'s
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setIsRecoveringForTesting(_ value: Bool) {
        sessionRestoreCoordinator._setIsRecoveringForTesting(value)
    }
    #endif

    func initializeHasPreservedSessionSnapshotFlag() async {
        await sessionRestoreCoordinator.initializeHasPreservedSessionSnapshotFlag()
    }

    func notifyPreviousSessionNotRestored() {
        sessionRestoreCoordinator.notifyPreviousSessionNotRestored()
    }

    func recoverPreservedSession() {
        sessionRestoreCoordinator.recoverPreservedSession()
    }

    func finalizeRecoverPreservedSession(restoredAny: Bool) async {
        await sessionRestoreCoordinator.finalizeRecoverPreservedSession(restoredAny: restoredAny)
    }

    func attemptSessionRestoreFromDisk(deadline: TimeInterval = 2.0) -> SessionRestoreCoordinator.SessionRestoreDiskOutcome {
        sessionRestoreCoordinator.attemptSessionRestoreFromDisk(deadline: deadline)
    }

    func attemptPreserveDiscardedSessionOnDisk(deadline: TimeInterval = 2.0) -> SessionRestoreCoordinator.SessionPreserveDiskOutcome {
        sessionRestoreCoordinator.attemptPreserveDiscardedSessionOnDisk(deadline: deadline)
    }

    private func restoreSession() -> Bool {
        sessionRestoreCoordinator.restoreSession()
    }

    private func restoreWindow(_ windowSnap: WindowSnapshot) -> Bool {
        guard let app = GhosttyAppController.shared.app else { return false }

        // Clamp window frame to screen
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clampedSnap = windowSnap.clampedToScreen(screenFrame: screenFrame)

        // Create WindowSession from snapshot
        let windowSession = WindowSession(snapshot: clampedSnap)
        let (window, wc) = makeRestoringWindowController(contentRect: clampedSnap.frame, windowSession: windowSession)

        // Restore surfaces for each tab
        var anyTabRestored = false
        for group in windowSession.groups {
            for tab in group.tabs {
                // Browser tabs don't need surface restoration
                if case .browser = tab.content {
                    anyTabRestored = true
                    continue
                }
                if restoreTabSurfaces(tab: tab, app: app, window: window) {
                    anyTabRestored = true
                } else {
                    // Fallback: create a single new surface for this tab
                    if fallbackCreateSurface(tab: tab, app: app, window: window) {
                        anyTabRestored = true
                    }
                }
            }
        }

        if !anyTabRestored {
            cleanupFailedWindow(window, windowSession, wc, message: "Failed to restore any tabs for window \(windowSnap.id)")
            return false
        }

        if clampedSnap.isFullScreen {
            // Keep isRestoring=true until the window finishes entering fullscreen,
            // then activate. This prevents windowDidEnterFullScreen from triggering
            // a save that captures an intermediate (non-fullscreen) frame.
            let box = FullScreenRestoreBox()
            box.activate = { [weak wc, weak box] in
                guard let box, !box.didActivate else { return }
                box.didActivate = true
                if let token = box.observer {
                    NotificationCenter.default.removeObserver(token)
                    box.observer = nil
                }
                wc?.activateRestoredSession()
            }
            box.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak box] _ in
                MainActor.assumeIsolated {
                    box?.activate?()
                }
            }

            // Safety timeout: if fullscreen transition never completes, activate anyway.
            // Strong-capture `box` so its lifetime extends until this closure fires.
            // The notification callback above is [weak box]; it only fires if box is
            // still alive via this strong reference. After activate() runs (either via
            // notification or timeout), didActivate guards against double-invocation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [box] in
                MainActor.assumeIsolated {
                    box.activate?()
                }
            }

            wc.showWindow(nil)

            // toggleFullScreen must be scheduled after the current run-loop cycle
            // so the window is fully shown before AppKit begins the transition.
            DispatchQueue.main.async { [weak wc] in
                MainActor.assumeIsolated {
                    wc?.window?.toggleFullScreen(nil)
                }
            }
        } else {
            wc.activateRestoredSession()
            wc.showWindow(nil)
        }

        return true
    }

    /// Holds the mutable observer / activation state for the fullscreen-restore
    /// coordination in `restoreWindow`. A reference-typed box lets multiple
    /// escaping closures (notification callback, timeout) share a single
    /// one-shot activation flag without inout captures.
    @MainActor
    private final class FullScreenRestoreBox {
        var observer: NSObjectProtocol?
        var didActivate: Bool = false
        var activate: (() -> Void)?
    }

    /// Not `private` (P4 round-8 fix RED phase, T-B):
    /// `AppDelegateRestoreTabSurfacesOwnershipTests`/
    /// `AppDelegateOfferAgentResumePipelineBoundTests` call this directly
    /// (with `_createSurfaceWithPwdHookForTesting` set, see that seam's
    /// own doc comment on `createSurfaceWithPwd`) to drive its
    /// partial-failure cleanup and per-surface agent-resume dispatch
    /// deterministically, without a real, live ghostty surface, mirroring
    /// `fetchSessionsForAgentResume`'s identical round-6 RED phase
    /// precedent.
    func restoreTabSurfaces(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        let oldLeafIDs = tab.splitTree.allLeafIDs()
        guard !oldLeafIDs.isEmpty else { return false }

        // Reject any persisted SessionRef whose sessionID isn't shaped
        // like a genuine ULID before it ever reaches calix-session
        // attach, a corrupted/malicious sessions.json value must not
        // run arbitrary daemon-side lookups. The rejected leaf simply
        // restores as an ordinary passthrough shell below
        // (createSurfaceWithPwd only synthesizes an attach command when
        // tab.sessionRefs still has an entry for that leaf).
        for (leafID, sessionRef) in tab.sessionRefs where !SessionRef.isValidULID(sessionRef.sessionID) {
            tab.sessionRefs.removeValue(forKey: leafID)
        }

        var mapping: [UUID: UUID] = [:]
        // R8-D item 3 (H2, r8-fix-spec.md): collected here, fanned out
        // through a single shared Task below instead of
        // `createSurfaceWithPwd` spawning its own per-surface Task (see
        // its own doc comment).
        var agentResumeCandidates: [(tab: Tab, surfaceID: UUID, sessionID: String)] = []

        for oldID in oldLeafIDs {
            guard let created = createSurfaceWithPwd(tab: tab, app: app, window: window, oldLeafID: oldID) else {
                continue
            }
            let newID = created.surfaceID
            mapping[oldID] = newID
            if let sessionRef = tab.sessionRefs[oldID] {
                // R6-C (V4 constraint, r6-fix-spec.md): re-checked
                // immediately before registering, defense in depth
                // against a future async gap between this check and the
                // register call (this whole loop stays fully synchronous
                // today, with no `await` in between, so no other
                // MainActor call can interleave here, see
                // fetchSessionsForAgentResume's doc comment); abort
                // registering over an entry that appeared meanwhile
                // rather than clobber it.
                if SessionSurfaceMap.shared.surfaceID(for: sessionRef.sessionID) == nil {
                    SessionSurfaceMap.shared.register(sessionID: sessionRef.sessionID, surfaceID: newID)
                }
            }
            if let agentResumeSessionID = created.agentResumeSessionID {
                agentResumeCandidates.append((tab, newID, agentResumeSessionID))
            }
        }

        // R8-D item 3 (H2): one shared Task awaits the shared fetch
        // once and calls `offerAgentResume` for every reattached leaf
        // from this single restore pass, an O(1) Task count regardless
        // of how many persistent-session leaves this tab has.
        if !agentResumeCandidates.isEmpty {
            let candidates = agentResumeCandidates
            let fetchTask = agentResumeAdvisor.agentResumeSessionsTask
            Task { [weak self] in
                let sessions = await fetchTask?.value ?? [:]
                for candidate in candidates {
                    self?.agentResumeAdvisor.offerAgentResume(
                        tab: candidate.tab, surfaceID: candidate.surfaceID,
                        sessionID: candidate.sessionID, sessions: sessions
                    )
                    #if DEBUG
                    self?._createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting?()
                    #endif
                }
            }
        }

        // All leaves must be restored for split integrity
        if mapping.count == oldLeafIDs.count {
            tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
            tab.sessionRefs = tab.sessionRefs.remappingKeys(mapping)
            return true
        }

        // Partial failure: destroy any surfaces we created (undoing
        // their SessionSurfaceMap registration too) and return false.
        // R8-B (r8-fix-spec.md; r7-verdicts.md R7-V3): unregisters only
        // when the mapping still actually points at THIS (failed)
        // restore's own surface. A duplicate sessionID across two tabs
        // (a corrupted/hand-edited sessions.json, explicitly in this
        // function's own threat model, see the doc comment above)
        // registers the FIRST tab's surface and skips the SECOND (the
        // `== nil` guard above); without this check, the second tab's
        // partial-failure cleanup would unregister the sessionID
        // unconditionally, ripping the FIRST tab's still-live,
        // already-succeeded mapping out from under it.
        for (oldID, newID) in mapping {
            if let sessionRef = tab.sessionRefs[oldID],
               SessionSurfaceMap.shared.surfaceID(for: sessionRef.sessionID) == newID {
                SessionSurfaceMap.shared.unregister(sessionID: sessionRef.sessionID)
            }
            tab.registry.destroySurface(newID)
        }
        return false
    }

    private func fallbackCreateSurface(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        guard let created = createSurfaceWithPwd(tab: tab, app: app, window: window) else {
            return false
        }
        let newID = created.surfaceID
        tab.splitTree = SplitTree(leafID: newID)
        // The whole original tree failed to restore, so none of the
        // old leaf UUIDs survive into this brand-new single-leaf tree —
        // drop every now-orphaned SessionRef rather than let it linger
        // (and get written back out by the next snapshot) pointing at a
        // leaf that no longer exists.
        tab.pruneSessionRefs()
        return true
    }

    /// Creates one surface for `tab` during restore. When `oldLeafID`
    /// names a leaf that had a `SessionRef` in the snapshot
    /// (`tab.sessionRefs`, carried over by `Tab.init(snapshot:)`
    /// regardless of the current `SessionSettings
    /// .persistentSessionsEnabled` toggle, a session that already
    /// exists in the daemon must not be orphaned just because the user
    /// has since turned the feature off), creates the surface with an
    /// attach command instead of a plain shell so `restoreTabSurfaces`
    /// can reconnect it, returning the sessionID it reattached
    /// alongside the new surfaceID so the caller can offer agent resume
    /// for it (see `agentResumeSessionID`'s own doc comment).
    /// `fallbackCreateSurface`'s single-surface, whole-tree-failed path
    /// calls this with the default `oldLeafID: nil`, so it always falls
    /// back to a plain passthrough surface (`agentResumeSessionID` is
    /// always `nil` for that call, matching this method's pre-feature
    /// behavior exactly for that rare failure case).
    ///
    /// R6-C (r6-fix-spec.md): no longer takes a `sessions` parameter.
    /// The surface is created immediately, synchronously; a caller that
    /// gets a non-nil `agentResumeSessionID` back awaits
    /// `agentResumeSessionsTask`'s result itself before calling
    /// `offerAgentResume` (see `restoreTabSurfaces`'s R8-D/H2 fan-out),
    /// so this method never waits on the daemon.
    private func createSurfaceWithPwd(
        tab: Tab, app: ghostty_app_t, window: NSWindow, oldLeafID: UUID? = nil
    ) -> (surfaceID: UUID, agentResumeSessionID: String?)? {
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        if let oldLeafID, let sessionRef = tab.sessionRefs[oldLeafID] {
            let command: String?
            if let host = sessionRef.host {
                command = SessionCommandSynthesizer.remoteAttachCommand(
                    host: host, sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
                )
            } else {
                command = SessionCommandSynthesizer.reattachCommand(
                    sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
                )
            }
            #if DEBUG
            _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, command)
            #endif
            if let command {
                guard let surfaceID = createRegistrySurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: command, oldLeafID: oldLeafID) else {
                    return nil
                }
                return (surfaceID, sessionRef.sessionID)
            }
        } else {
            #if DEBUG
            _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, nil)
            #endif
        }
        guard let surfaceID = createRegistrySurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: nil, oldLeafID: oldLeafID) else {
            return nil
        }
        return (surfaceID, nil)
    }

    #if DEBUG
    /// Test seam (P4 round-8 fix RED phase, T-B/T-D): when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `createRegistrySurface`, keyed by `oldLeafID` (`nil`
    /// for the no-old-leaf/fallback path). Returns the UUID to report as
    /// the newly created surface (simulating success), or `nil` to
    /// simulate surface-creation failure for that one leaf, letting
    /// `restoreTabSurfaces`'s partial-failure bookkeeping (and, R8-D/H2,
    /// its shared agent-resume fan-out `Task`) be driven deterministically
    /// without a real, live ghostty surface (confirmed unsafe from this
    /// test host, see `_attachWindowCreationHookForTesting`'s doc comment
    /// for the confirmed hang). Placed as the narrowest possible wrapper
    /// around only the actually-unsafe call: everything around it (the
    /// attach-command detection, the `offerAgentResume` dispatch) stays
    /// real, unmodified production code. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdHookForTesting: ((UUID?) -> UUID?)?

    /// Test seam (P4 round-8 fix RED phase, T-D): when non-nil, called
    /// once `restoreTabSurfaces`'s shared agent-resume fan-out `Task`
    /// (R8-D/H2, r8-fix-spec.md; formerly a per-surface `Task` spawned
    /// directly inside `createSurfaceWithPwd`, before that fan-out
    /// consolidated it) has awaited `agentResumeSessionsTask`'s result
    /// and called `offerAgentResume` for ONE reattached leaf, i.e. once
    /// that leaf's pipeline reaches a terminal state, regardless of
    /// whether `offerAgentResume` actually found a resumable session to
    /// act on. Fires once per candidate leaf in the fan-out, not once
    /// per restore pass. No such observable existed before this seam:
    /// the fan-out `Task` is otherwise fire-and-forget, with nothing to
    /// await from a test. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting: (() -> Void)?

    /// Test seam (P5, remote sessions, contract R2): when non-nil,
    /// called with `(oldLeafID, command)` from inside
    /// `createSurfaceWithPwd`, immediately before `createRegistrySurface`
    /// is invoked, in both of that method's branches -- the
    /// `sessionRef`-carrying branch (with its local `reattachCommand` or
    /// remote `remoteAttachCommand` result, either of which may itself be
    /// `nil`) and the plain-passthrough branch (`command` always `nil`).
    /// Added as a second, independent observer alongside
    /// `_createSurfaceWithPwdHookForTesting` rather than changing that
    /// hook's signature, since every existing caller of it only needs the
    /// resulting surfaceID, never the command string. `nil` (the default)
    /// leaves production behavior unchanged. DO NOT use from production
    /// code.
    var _createSurfaceWithPwdCommandObserverForTesting: ((UUID?, String?) -> Void)?
    #endif

    /// Thin wrapper around the one actually-unsafe-to-test call
    /// `createSurfaceWithPwd` makes (`tab.registry.createSurface`, a
    /// real ghostty FFI surface), so `_createSurfaceWithPwdHookForTesting`
    /// (see its own doc comment) can intercept exactly that call and
    /// nothing else.
    private func createRegistrySurface(
        tab: Tab, app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?, command: String?, oldLeafID: UUID?
    ) -> UUID? {
        #if DEBUG
        if let hook = _createSurfaceWithPwdHookForTesting {
            return hook(oldLeafID)
        }
        #endif
        return tab.registry.createSurface(app: app, config: config, pwd: pwd, command: command)
    }

    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase, R6-C): when non-nil, used
    /// instead of `SessionDaemonClient.shared` inside
    /// `hasRunningPersistentSessions`. Mirrors the
    /// `SessionDaemonClientProtocol` fake pattern already established by
    /// `SessionBrowserModelTests`/`SessionReconnectCoordinatorTests`
    /// rather than inventing a new one, since `SessionDaemonClient.shared`
    /// itself is a non-swappable `let` (unlike `NotificationManager
    /// .shared`). Lets a test control exactly what the daemon's ledger
    /// reports, without spawning a real `calix-session` process. `nil`
    /// (the default) leaves production behavior unchanged. DO NOT use
    /// from production code.
    var _sessionDaemonClientForTesting: SessionDaemonClientProtocol?
    #endif

    /// Agent-resume daemon-query infra (`AgentResumeAdvisor.swift`):
    /// fetching the daemon's session ledger for the current
    /// restore/attach pass, reasserting history-persistence state at
    /// launch, and deciding whether a reattached persistent-session
    /// surface should have a resumable agent CLI session typed into it.
    let agentResumeAdvisor = AgentResumeAdvisor()

    /// True when the daemon's ledger currently reports at least one
    /// RUNNING persistent session. Reuses listAllSessionsBounded(client:)
    /// exactly as fetchSessionsForAgentResume() already does -- bounded,
    /// best-effort; a probe failure (daemon unreachable/timeout) surfaces
    /// as an empty ledger, which this method treats as "no evidence of
    /// any anomaly" (current, unchanged behavior for that case).
    /// Consulted by restoreSession()'s empty-snapshot branch: with
    /// close=kill semantics, a genuinely empty snapshot from a deliberate
    /// "closed every window" quit should never coexist with a still-
    /// running persistent session.
    func hasRunningPersistentSessions() async -> Bool {
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        let sessions = await AgentResumeAdvisor.listAllSessionsBounded(client: client)
        return sessions.values.contains { session in
            if case .running = session.state { return true }
            return false
        }
    }

    // MARK: - Finder Services

    @objc func openInCalix(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            error.pointee = "No folder selected" as NSString
            return
        }
        application(NSApp, open: urls)
    }

    // MARK: - Global Keybinds

    /// Enable the global CGEvent tap if ghostty has global keybindings configured.
    /// This allows keybindings like quick terminal toggle to work from any app.
    private func installGlobalEventTap() {
        if ProcessInfo.processInfo.arguments.contains("--uitesting")
            || TestEnvironment.isTestHost { return }
        guard let app = GhosttyAppController.shared.app else {
            logger.warning("installGlobalEventTap: no ghostty app available")
            return
        }
        let hasGlobal = GhosttyFFI.appHasGlobalKeybinds(app)
        logger.info("installGlobalEventTap: hasGlobalKeybinds=\(hasGlobal)")
        if hasGlobal {
            // Delay slightly on fresh launch to avoid burying the Accessibility
            // permissions dialog behind initial windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                GlobalEventTap.shared.enable(app: app)
            }
        }
    }

    // MARK: - Actions

    /// Action produced by `matchKeyEvent` when an `NSEvent` matches one of the
    /// shortcuts handled by `installKeyMonitor`. The enum is exposed as a pure,
    /// Equatable value so the matching logic can be unit-tested in isolation
    /// from `AppDelegate`'s window-controller state (see
    /// `CalixTests/AppDelegateKeyMonitorTests.swift`).
    ///
    /// Cases:
    /// - `commandPalette`: Cmd+Shift+P — toggle the command palette.
    /// - `unreadTab`:      Cmd+Shift+U — jump to most recent unread tab.
    /// - `nextTab`:        Cmd+Shift+] — select next tab (Issue #27).
    /// - `previousTab`:    Cmd+Shift+[ — select previous tab (Issue #27).
    /// - `selectTab(Int)`: Cmd+1..Cmd+9 — select tab at 0-based index.
    /// - `debugSelect`:    Ctrl+Shift+D — UI-testing-only debug hook.
    enum KeyMonitorAction: Equatable, Sendable {
        case commandPalette
        case unreadTab
        case nextTab
        case previousTab
        case selectTab(Int)
        case debugSelect
    }

    /// Translate a key-down `NSEvent` into a `KeyMonitorAction` that the local
    /// event monitor should dispatch. Returns `nil` for any event that should
    /// flow through to the first responder / main menu unchanged.
    ///
    /// This method is a pure function — it does not touch window-controller
    /// state — so it can be driven directly from unit tests that fabricate
    /// synthetic `NSEvent`s (see `AppDelegateKeyMonitorTests`).
    ///
    /// Modifier matching uses strict equality after intersecting with
    /// `[.command, .shift, .control, .option]` so that incidental flags such
    /// as `.capsLock`, `.numericPad`, or `.function` do not prevent a match.
    ///
    /// - Parameters:
    ///   - event: The incoming `.keyDown` event.
    ///   - isUITesting: Whether the process was launched with `--uitesting`.
    ///     The `Ctrl+Shift+D` debug-select hook is only active in that mode.
    /// - Returns: The action to perform, or `nil` to pass the event through.
    static func matchKeyEvent(_ event: NSEvent, isUITesting: Bool) -> KeyMonitorAction? {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let chars = event.charactersIgnoringModifiers
        let lowered = chars?.lowercased()

        // Cmd+Shift+P — command palette
        if mods == [.command, .shift], lowered == "p" {
            return .commandPalette
        }

        // Cmd+Shift+U — jump to most recent unread tab
        if mods == [.command, .shift], lowered == "u" {
            return .unreadTab
        }

        // Cmd+Shift+] — select next tab (Issue #27).
        // Must be handled here (not just via the Window menu's key equivalent)
        // because `NSTextView` in diff tabs would otherwise consume the event
        // for its built-in `alignRight:` binding before the main menu fires.
        //
        // Matched by keyCode (not `charactersIgnoringModifiers`) because
        // `charactersIgnoringModifiers` APPLIES Shift (per Apple docs: "as if
        // no modifier key had been pressed, except for Shift"). So a real
        // `Cmd+Shift+]` keystroke reports `"}"`, not `"]"`. KeyCode matching
        // is also the project's convention for bracket shortcuts — the
        // sibling `Ctrl+Shift+]` / `Ctrl+Shift+[` group-navigation
        // shortcuts are bound on the Window > Group menu items
        // (see `AppDelegate.setupMainMenu`) using the same physical keys.
        // kVK_ANSI_RightBracket = 30 (from HIToolbox/Events.h).
        if mods == [.command, .shift], event.keyCode == 30 {
            return .nextTab
        }

        // Cmd+Shift+[ — select previous tab (Issue #27).
        // Parallel reasoning to `.nextTab`: `NSTextView`'s `alignLeft:`
        // binding would otherwise swallow the event on diff tabs.
        // kVK_ANSI_LeftBracket = 33 (from HIToolbox/Events.h).
        if mods == [.command, .shift], event.keyCode == 33 {
            return .previousTab
        }

        // Cmd+1..Cmd+9 — select tab at 0-based index (no shift).
        if mods == [.command],
           let chars,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 49, scalar.value <= 57 {
            return .selectTab(Int(scalar.value - 49))
        }

        // Ctrl+Shift+D — UI-testing-only debug-select hook.
        if isUITesting, mods == [.control, .shift], lowered == "d" {
            return .debugSelect
        }

        return nil
    }

    private func installKeyMonitor() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let action = AppDelegate.matchKeyEvent(event, isUITesting: isUITesting) else {
                return event
            }

            // All window-targeted actions require a key window. If none, fall
            // through so the event can still reach the responder chain / menu.
            let keyWC = self.windowControllers.first(where: { $0.window?.isKeyWindow == true })

            switch action {
            case .debugSelect:
                // Reads selection parameters from the pasteboard and simulates
                // a mouse drag via ghostty FFI to create a terminal selection.
                // Does not require a key window.
                self.performDebugSelect()
                return nil
            case .commandPalette, .unreadTab, .nextTab, .previousTab, .selectTab:
                // All window-targeted actions require a key window. If none,
                // fall through so the event can still reach the responder
                // chain / menu.
                guard let wc = keyWC else { return event }
                switch action {
                case .commandPalette:        wc.toggleCommandPalette()
                case .unreadTab:             wc.jumpToMostRecentUnreadTab()
                case .nextTab:               wc.selectNextTab(nil)
                case .previousTab:           wc.selectPreviousTab(nil)
                case .selectTab(let index):  wc.selectTab(at: index)
                case .debugSelect:           break // unreachable; handled above
                }
                return nil // consume the event
            }
        }
    }

    // MARK: - UI Testing Support

    /// Simulates a mouse drag on the focused terminal surface to create a text selection.
    /// Reads selection parameters (fromCol, toCol, row) from the general pasteboard as JSON.
    /// Only available when launched with --uitesting flag.
    private func debugLog(_ msg: String) {
        let logPath = "/tmp/calix_debug_select.log"
        let entry = "\(Date()): \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(entry.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: entry.data(using: .utf8))
        }
    }

    private func performDebugSelect() {
        let pbContent = NSPasteboard.general.string(forType: .string)
        debugLog("performDebugSelect called, pasteboard=\(pbContent ?? "nil")")

        guard let jsonStr = pbContent,
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let fromCol = json["fromCol"],
              let toCol = json["toCol"],
              let row = json["row"] else {
            debugLog("FAIL: JSON parse failed")
            return
        }

        debugLog("Parsed: fromCol=\(fromCol), toCol=\(toCol), row=\(row)")

        guard let wc = windowControllers.first(where: { $0.window?.isKeyWindow == true }) else {
            debugLog("FAIL: no key window")
            return
        }
        guard let controller = wc.focusedControllerForTesting else {
            debugLog("FAIL: no focused controller")
            return
        }
        guard let surface = controller.surface else {
            debugLog("FAIL: no surface")
            return
        }

        // Try cellSize from controller first, fallback to surfaceSize from FFI.
        let cellSize = controller.cellSize
        let surfSize = GhosttyFFI.surfaceSize(surface)
        let cachedCS = controller.surfaceView?.cachedCellSize ?? .zero
        debugLog("cellSize=\(cellSize), surfSize.cell_width_px=\(surfSize.cell_width_px), surfSize.cell_height_px=\(surfSize.cell_height_px), cachedCellSize=\(cachedCS)")

        // Use cellSize if available, otherwise compute from surfaceSize (pixel values
        // divided by backing scale factor to get view-point coordinates).
        let cellW: Double
        let cellH: Double
        if cellSize.width > 0, cellSize.height > 0 {
            cellW = Double(cellSize.width)
            cellH = Double(cellSize.height)
        } else if surfSize.cell_width_px > 0, surfSize.cell_height_px > 0 {
            let scale = controller.surfaceView?.window?.backingScaleFactor ?? 2.0
            cellW = Double(surfSize.cell_width_px) / Double(scale)
            cellH = Double(surfSize.cell_height_px) / Double(scale)
            debugLog("Using surfaceSize with scale=\(scale): cellW=\(cellW), cellH=\(cellH)")
        } else {
            debugLog("FAIL: both cellSize and surfaceSize are zero")
            return
        }

        let startX = (Double(fromCol) + 0.5) * cellW
        let endX = (Double(toCol) + 0.5) * cellW
        let y = (Double(row) + 0.5) * cellH

        debugLog("Drag: startX=\(startX), endX=\(endX), y=\(y)")

        // Simulate drag: move to start, press, move to end, release.
        GhosttyFFI.surfaceMousePos(surface, x: startX, y: y, mods: GHOSTTY_MODS_NONE)
        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

        GhosttyFFI.surfaceMousePos(surface, x: endX, y: y, mods: GHOSTTY_MODS_NONE)

        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

        let hasSelection = GhosttyFFI.surfaceHasSelection(surface)
        debugLog("After drag: hasSelection=\(hasSelection)")

        // Also try to read text from the entire row for diagnostics.
        do {
            let fullStartX = 0.5 * cellW
            let fullEndX = 80.0 * cellW
            GhosttyFFI.surfaceMousePos(surface, x: fullStartX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            GhosttyFFI.surfaceMousePos(surface, x: fullEndX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

            var fullText = ghostty_text_s()
            if GhosttyFFI.surfaceReadSelection(surface, text: &fullText) {
                let fullLen = Int(fullText.text_len)
                if fullLen > 0, let ptr = fullText.text {
                    let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    let buf = UnsafeBufferPointer(start: uint8Ptr, count: fullLen)
                    let fullStr = String(decoding: buf, as: UTF8.self)
                    debugLog("Full row \(row) text: '\(fullStr)' (len=\(fullLen))")
                } else {
                    debugLog("Full row \(row): empty (len=\(fullLen))")
                }
                var mutableFullText = fullText
                GhosttyFFI.surfaceFreeText(surface, text: &mutableFullText)
            }

            // Restore original selection
            GhosttyFFI.surfaceMousePos(surface, x: startX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            GhosttyFFI.surfaceMousePos(surface, x: endX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        }

        if hasSelection {
            var text = ghostty_text_s()
            let readOK = GhosttyFFI.surfaceReadSelection(surface, text: &text)
            debugLog("readSelection returned \(readOK), text_len=\(text.text_len), text.text=\(text.text == nil ? "nil" : "non-nil")")
            if readOK {
                let len = Int(text.text_len)
                if len > 0, let ptr = text.text {
                    let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    let buf = UnsafeBufferPointer(start: uint8Ptr, count: len)
                    let selectedText = String(decoding: buf, as: UTF8.self)
                    debugLog("Selected text: '\(selectedText)' (len=\(len))")
                } else {
                    debugLog("readSelection text is nil or empty, len=\(len)")
                }
                var mutableText = text
                GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
            }
        }

        debugLog("Debug select complete")
    }

    @objc private func showAboutPanel() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: "",
            .applicationVersion: version
        ])
    }

    @objc private func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func toggleSecureInput(_ sender: NSMenuItem) {
        let input = SecureInput.shared
        input.global.toggle()
        UserDefaults.standard.set(input.global, forKey: "SecureInput")
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let wc = windowControllers.first(where: { $0.window?.isKeyWindow == true }) else { return }
        wc.selectTab(at: sender.tag)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSecureInput(_:)) {
            menuItem.state = SecureInput.shared.global ? .on : .off
            return true
        }
        return true
    }

    @objc private func handleToggleQuickTerminal() {
        toggleQuickTerminal()
    }

    /// View menu's "Session Browser" item (Cmd+Shift+B): the same call
    /// every other entry point into the session browser already makes
    /// (`SessionBrowserWindowController.attachRemote(_:)`'s sibling
    /// palette command `session.attach`, the Settings panel button).
    @objc private func openSessionBrowser(_ sender: Any?) {
        SessionBrowserWindowController.shared.showBrowser()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when `AppDelegate.isConfirmingQuit` transitions from
    /// `true` to `false` (see that property's `didSet`): the
    /// confirm-quit gate has cleared, whether via a real
    /// `NSAlert.runModal()` return or the `_setConfirmingQuitForTesting`
    /// test seam. `CalixWindowController` observes this to replay events
    /// it deferred while the gate was up (F4, r4-fix-spec.md); see
    /// `drainDeferredReconnectEvents()`.
    static let calixConfirmingQuitDidEnd = Notification.Name("com.calix.session.confirmingQuitDidEnd")
}
