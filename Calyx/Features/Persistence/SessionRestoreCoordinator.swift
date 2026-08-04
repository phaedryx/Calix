// SessionRestoreCoordinator.swift
// Calyx
//
// Session save/restore/recovery orchestration, extracted from AppDelegate:
// building and persisting session snapshots, restoring a previous session
// on launch, and the "preserve on disk + offer recovery" fallback path
// (Bug 3a/3c) for a session that was skipped, failed to restore, or timed
// out reading from disk. AppDelegate retains the actual window/tab
// construction machinery (`restoreWindow(_:)` and everything it shares
// with `attachWindow`/`attachSessionAsNewTab`) and the agent-resume
// daemon-query infra (`fetchSessionsForAgentResume`,
// `hasRunningPersistentSessions`) -- both injected here as closures.

import AppKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "SessionRestoreCoordinator"
)

@MainActor
final class SessionRestoreCoordinator {
    private let windowControllers: () -> [CalyxWindowController]
    private let restoreWindow: (WindowSnapshot) -> Bool
    private let fetchSessionsForAgentResume: () -> Void
    private let hasRunningPersistentSessions: () async -> Bool

    init(
        windowControllers: @escaping () -> [CalyxWindowController],
        restoreWindow: @escaping (WindowSnapshot) -> Bool,
        fetchSessionsForAgentResume: @escaping () -> Void,
        hasRunningPersistentSessions: @escaping () async -> Bool
    ) {
        self.windowControllers = windowControllers
        self.restoreWindow = restoreWindow
        self.fetchSessionsForAgentResume = fetchSessionsForAgentResume
        self.hasRunningPersistentSessions = hasRunningPersistentSessions
    }

    func requestSave() {
        let snapshot = buildSnapshot()
        Task {
            await SessionPersistenceActor.shared.save(snapshot)
        }
    }

    func saveImmediately() {
        let snapshot = buildSnapshot()
        var done = false
        Task {
            await SessionPersistenceActor.shared.saveImmediately(snapshot)
            done = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    // Closure-indirection artifact: `windowControllers` is a stored
    // closure here (injected by AppDelegate), not a stored property, so
    // this reads `windowControllers()` where the original AppDelegate
    // method read the property directly.
    func buildSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            windows: windowControllers().map { $0.windowSnapshot() }
        ).removingEmptyWindows()
    }

    /// Extracted from applicationWillTerminate's save step so it is
    /// directly unit-testable: applicationWillTerminate itself is gated
    /// behind LaunchEnvironmentPolicy.isUnitTestHost() and always
    /// early-returns in the CalyxTests process (see that gate's own doc
    /// comment), so no test can drive it directly. Saves
    /// pendingTerminationSnapshot when present, falling back to
    /// buildSnapshot() otherwise (the existing behavior for e.g. a Cmd+Q
    /// with no window-close race). Routes through saveAtTermination(_:),
    /// which itself refuses to let an empty snapshot clobber a non-empty
    /// on-disk one, and resets the crash-loop counter exactly as
    /// applicationWillTerminate's own Task body already did.
    /// See SyncBridgeBox's own doc comment for why this uses
    /// `Task.detached` instead of the plain `Task { }` every other
    /// busy-wait in this file uses: this method must also behave
    /// correctly when driven directly from an async XCTest method
    /// (AppDelegatePendingTerminationSnapshotTests), not only from
    /// applicationWillTerminate's genuinely synchronous call stack.
    ///
    /// Closure-indirection artifact: `pendingTerminationSnapshot` stays
    /// on AppDelegate, so it is taken here as an explicit parameter
    /// instead of being read directly.
    func saveForTermination(pendingSnapshot: SessionSnapshot?) {
        let snapshot = pendingSnapshot ?? buildSnapshot()
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<Bool>(false)
        Task.detached {
            await actor.saveAtTermination(snapshot)
            await actor.resetRecoveryCounter()
            box.value = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !box.value, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    #if DEBUG
    /// Test seam: overrides the SessionPersistenceActor instance
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:) resets,
    /// instead of SessionPersistenceActor.shared. DO NOT use from
    /// production code.
    var sessionPersistenceActorForTesting: SessionPersistenceActor?
    #endif

    /// Schedules a delayed reset of the crash-loop recovery counter,
    /// confirming this launch survived `delay` before declaring it
    /// stable. Called exactly once per restoreSession() invocation,
    /// unconditionally -- independent of whether anything was restored
    /// -- so every launch that stays up long enough eventually resets
    /// the counter. A launch that crashes before `delay` elapses never
    /// runs this Task's body, so the counter is left incremented for
    /// the crash-loop detector exactly as today.
    func scheduleRecoveryCounterResetAfterStableLaunch(delay: Duration = .seconds(5)) {
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        Task {
            try? await Task.sleep(for: delay)
            await actor.resetRecoveryCounter()
        }
    }

    /// True once Bug 3a's preserveSnapshotForRecovery() has moved a
    /// skipped/failed session's snapshot aside. Gates
    /// session.recoverPreviousSession's isAvailable. Cleared back to
    /// false once recoverPreservedSession() either restores at least
    /// one window from the preserved snapshot (via
    /// finalizeRecoverPreservedSession(restoredAny:)), or finds the
    /// preserved snapshot undecodable and quarantines it (see
    /// SessionPersistenceActor.quarantineCorruptPreservedSnapshot()). A
    /// recovery attempt that restores nothing from an otherwise
    /// decodable snapshot leaves this flag untouched, so the user's
    /// last-resort backup is never silently destroyed.
    private(set) var hasPreservedSessionSnapshot = false

    #if DEBUG
    /// Test seam: mirrors _setApplicationTerminatingForTesting's
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setHasPreservedSessionSnapshotForTesting(_ value: Bool) {
        hasPreservedSessionSnapshot = value
    }
    #endif

    /// Reentrancy guard for `recoverPreservedSession()`: two back-to-back
    /// invocations (e.g. a double-click on "Recover Previous Session")
    /// would otherwise each independently load the same preserved
    /// snapshot and each run their own `restoreWindow(_:)` loop over its
    /// windows, restoring every window TWICE. Mirrors
    /// `SessionBrowserModel.refresh()`'s existing `isRefreshing` guard.
    private(set) var isRecovering = false

    #if DEBUG
    /// Test seam: mirrors `_setHasPreservedSessionSnapshotForTesting`'s
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setIsRecoveringForTesting(_ value: Bool) {
        isRecovering = value
    }
    #endif

    /// Bug 3c gap-close: initializes hasPreservedSessionSnapshot from
    /// whatever preserveSnapshotForRecovery() left on disk in a PREVIOUS
    /// run, so a relaunch (where THIS run's own restoreSession() never
    /// calls preserveSnapshotForRecovery() itself) still offers the
    /// still-pending recovery command. Mirrors
    /// reassertHistoryPersistenceIfNeeded()'s async-Task-after-launch shape.
    ///
    /// Not `private` any more (recovery-bar empty-snapshot fix, mirrors
    /// `finalizeRecoverPreservedSession(restoredAny:)`'s own identical
    /// extraction-for-testability precedent):
    /// AppDelegateEmptyPreservedSnapshotTests drives this directly via
    /// `@testable import Calyx`.
    ///
    /// A decodable-but-EMPTY preserved snapshot (`windows.isEmpty`) has
    /// nothing to recover, so it is treated as ABSENT here: the useless
    /// file is retired (clearPreservedSnapshot()) and the flag stays
    /// false, instead of trusting hasPreservedSnapshot()'s bare file-
    /// existence check -- an empty file left on disk would otherwise
    /// re-trigger this same dead state on every future launch. Broadcasts
    /// the resolved value to every tracked window controller's
    /// RecoveryBarModel either way, fixing the launch-time race where a
    /// window was already constructed (with the flag still at its
    /// initial `false`) before this Task resolves (see
    /// RecoveryBarModelTests.swift's own header).
    func initializeHasPreservedSessionSnapshotFlag() async {
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        guard let snapshot = await actor.loadPreservedSnapshot()?.removingEmptyWindows(),
              !snapshot.windows.isEmpty else {
            await actor.clearPreservedSnapshot()
            hasPreservedSessionSnapshot = false
            broadcastHasPreservedSessionSnapshotToRecoveryBars()
            return
        }
        hasPreservedSessionSnapshot = true
        broadcastHasPreservedSessionSnapshotToRecoveryBars()
    }

    /// Pushes the current `hasPreservedSessionSnapshot` into every
    /// currently-tracked window controller's `RecoveryBarModel`
    /// (RecoveryBarModel.swift), so an already-constructed window's bar
    /// updates in lockstep with this flag instead of only ever
    /// reflecting whatever value was current at that window's own
    /// construction time. Called from every site that changes this
    /// flag: `initializeHasPreservedSessionSnapshotFlag()`,
    /// `recoverPreservedSession()`'s empty/corrupt-snapshot guards, and
    /// `finalizeRecoverPreservedSession(restoredAny:)`.
    private func broadcastHasPreservedSessionSnapshotToRecoveryBars() {
        for wc in windowControllers() {
            wc.recoveryBarModel.updateHasPreservedSessionSnapshot(hasPreservedSessionSnapshot)
            wc.refreshRecoveryBar()
        }
    }

    /// Tells the user restoreSession() skipped or failed to restore
    /// their previous windows/tabs, and that the previous session was
    /// preserved (see SessionPersistenceActor.preserveSnapshotForRecovery(),
    /// Bug 3a) and can be recovered via the command palette's
    /// "Recover Previous Session" action (session.recoverPreviousSession,
    /// Bug 3c). Called once from restoreSession()'s crash-loop-skip and
    /// restoredAny-false branches (see
    /// SessionPersistenceActorRecoveryPreservationTests's wire-point
    /// note for the full branch list), alongside preserveSnapshotForRecovery().
    func notifyPreviousSessionNotRestored() {
        NotificationManager.shared.sendNotification(
            title: "Previous session not restored",
            body: "Calyx didn't restore your previous windows and tabs, but they're safely preserved. " +
                  "Recover them from the command palette (\"Recover Previous Session\").",
            tabID: UUID()
        )
    }

    /// session.recoverPreviousSession's handler: loads the preserved
    /// snapshot (via the same actor _sessionPersistenceActorForTesting
    /// seam scheduleRecoveryCounterResetAfterStableLaunch already uses).
    /// When the preserved snapshot is undecodable (corrupt JSON, unknown
    /// future schema version) or nothing was preserved at all, quarantines
    /// it (a safe no-op in the latter sub-case -- see
    /// SessionPersistenceActor.quarantineCorruptPreservedSnapshot()) and
    /// resets hasPreservedSessionSnapshot, so a dead command never stays
    /// stuck available. Otherwise rebuilds each window through the
    /// existing restoreWindow(_:) machinery (same one restoreSession()
    /// itself uses), tracking whether any window actually restored, and
    /// hands that result to finalizeRecoverPreservedSession(restoredAny:),
    /// which only clears the preserved file and resets the flag once at
    /// least one window restored -- a total-failure attempt leaves the
    /// backup in place so the user can retry or investigate.
    func recoverPreservedSession() {
        guard !isRecovering else { return }
        isRecovering = true
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        Task {
            defer { isRecovering = false }
            guard let rawSnapshot = await actor.loadPreservedSnapshot() else {
                // Nothing preserved, OR preserved but undecodable
                // (corrupt/unknown schema) -- quarantine is a no-op in
                // the former sub-case, so calling it unconditionally is
                // safe and unsticks the latter.
                await actor.quarantineCorruptPreservedSnapshot()
                hasPreservedSessionSnapshot = false
                broadcastHasPreservedSessionSnapshotToRecoveryBars()
                return
            }
            let snapshot = rawSnapshot.removingEmptyWindows()
            // Empty-snapshot fix: a decodable-but-empty preserved
            // snapshot has nothing to recover -- clear the useless file
            // and reset the flag (mirroring
            // finalizeRecoverPreservedSession(restoredAny: true)'s own
            // two-step "clear + reset" shape) instead of a silent no-op
            // that leaves a permanently dead command enabled.
            guard !snapshot.windows.isEmpty else {
                await actor.clearPreservedSnapshot()
                hasPreservedSessionSnapshot = false
                broadcastHasPreservedSessionSnapshotToRecoveryBars()
                return
            }
            var restoredAny = false
            for windowSnap in snapshot.windows {
                if restoreWindow(windowSnap) {
                    restoredAny = true
                }
            }
            await finalizeRecoverPreservedSession(restoredAny: restoredAny)
        }
    }

    /// Extracted from recoverPreservedSession() so the "was anything
    /// actually recovered" bookkeeping is unit-testable without reaching
    /// restoreWindow(_:)'s real GhosttyAppController/window-creation path
    /// (see AppDelegateRecoverPreservedSessionFinalizeTests's own
    /// reachability note). Mirrors
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:)'s
    /// actor-seam resolution. Clears the preserved snapshot and resets
    /// hasPreservedSessionSnapshot ONLY when restoredAny is true;
    /// otherwise leaves both untouched, so a recovery attempt that
    /// restored NOTHING never destroys the user's last-resort backup.
    func finalizeRecoverPreservedSession(restoredAny: Bool) async {
        guard restoredAny else { return }
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        await actor.clearPreservedSnapshot()
        hasPreservedSessionSnapshot = false
        broadcastHasPreservedSessionSnapshotToRecoveryBars()
    }

    /// Single-slot, lock-protected box used ONLY to bridge a
    /// `Task.detached` result back into a synchronous busy-wait loop.
    ///
    /// WHY THIS EXISTS (confirmed empirically, not theoretical): a plain
    /// (non-detached) `Task { ... }` created inside a `@MainActor`
    /// method inherits MainActor isolation, so it is queued onto
    /// MainActor's SAME serial turn the enclosing synchronous method is
    /// still occupying. When that method is invoked from a genuinely
    /// synchronous, non-Task call stack (e.g. `applicationDidFinishLaunching`,
    /// every production call site here), no other MainActor turn is in
    /// the way, so the queued task runs as soon as the run loop is
    /// pumped -- this is why the busy-wait convention used throughout
    /// this file already works for production. But when the SAME method
    /// is invoked from a caller that is ITSELF already an async Task
    /// running on MainActor (an `async` XCTest method, exactly what
    /// AppDelegateSessionRestoreDiskTimeoutTests/
    /// AppDelegatePendingTerminationSnapshotTests need for their own
    /// setup), the child task cannot start until the CURRENT MainActor
    /// turn (this very function) returns -- confirmed by raising the
    /// busy-wait deadline to 10s in a throwaway experiment and observing
    /// it still never completes; only `Task.detached`, which runs
    /// independently of MainActor's turn, avoids this. `Task.detached`'s
    /// closure must be `@Sendable`, so its result cannot cross back via
    /// a captured `var` the way the inherited-isolation `Task { }`
    /// pattern does elsewhere in this file; `@unchecked Sendable` here is
    /// justified because EVERY read and write of `value` is serialized
    /// through `lock`, so there is no actual unsynchronized shared
    /// mutable state despite crossing an isolation domain.
    private final class SyncBridgeBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Value
        init(_ value: Value) { storedValue = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return storedValue }
            set { lock.lock(); defer { lock.unlock() }; storedValue = newValue }
        }
    }

    enum SessionRestoreDiskOutcome: Equatable {
        case snapshot(SessionSnapshot)
        case empty
        case timedOut
    }

    /// Extracted from restoreSession()'s crash-loop-check + disk-read
    /// preamble so the timeout branch is genuinely unit-drivable and
    /// distinguishable from "the actor completed and said no" (see
    /// AppDelegateSessionRestoreDiskTimeoutTests's own header for the
    /// full root-cause narrative). `deadline: 0` deterministically
    /// forces `.timedOut` without needing an artificially slow actor.
    /// See SyncBridgeBox's own doc comment for why the disk read runs
    /// in a `Task.detached` instead of a plain `Task { }`.
    func attemptSessionRestoreFromDisk(deadline: TimeInterval = 2.0) -> SessionRestoreDiskOutcome {
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<(snapshot: SessionSnapshot?, done: Bool)>((nil, false))
        let task = Task.detached {
            let recoveryCount = await actor.incrementRecoveryCounter()
            var snapshot: SessionSnapshot?
            if recoveryCount <= SessionPersistenceActor.maxRecoveryAttempts {
                snapshot = await actor.restore()
            }
            box.value = (snapshot, true)
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !box.value.done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard box.value.done else {
            task.cancel()
            return .timedOut
        }
        guard let snapshot = box.value.snapshot else { return .empty }
        return .snapshot(snapshot)
    }

    enum SessionPreserveDiskOutcome: Equatable {
        case preserved
        case notPreserved
        case timedOut
    }

    /// Extracted from preserveDiscardedSessionIfAny()'s body for the
    /// identical reason as attemptSessionRestoreFromDisk(deadline:)
    /// above; see SyncBridgeBox's own doc comment for why this also
    /// needs `Task.detached`.
    func attemptPreserveDiscardedSessionOnDisk(deadline: TimeInterval = 2.0) -> SessionPreserveDiskOutcome {
        #if DEBUG
        let actor = sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<(didPreserve: Bool, done: Bool)>((false, false))
        let task = Task.detached {
            let didPreserve = await actor.preserveSnapshotForRecovery()
            box.value = (didPreserve, true)
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !box.value.done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard box.value.done else {
            task.cancel()
            return .timedOut
        }
        return box.value.didPreserve ? .preserved : .notPreserved
    }

    /// Synchronously bridges the async hasRunningPersistentSessions()
    /// into restoreSession()'s own synchronous body. Unlike
    /// attemptSessionRestoreFromDisk(deadline:)/
    /// attemptPreserveDiscardedSessionOnDisk(deadline:) above, this uses
    /// a plain (non-detached) `Task { }`, not SyncBridgeBox/Task.detached:
    /// hasRunningPersistentSessions() is itself MainActor-isolated (this
    /// class's default), so a detached task calling back into it would
    /// need to re-acquire MainActor's turn -- exactly the deadlock
    /// SyncBridgeBox's own doc comment describes -- reintroducing the
    /// same bug this bridge exists to avoid. This is safe as the plain,
    /// inherited-isolation form ONLY because restoreSession() (this
    /// method's sole caller) is itself reached exclusively from
    /// applicationDidFinishLaunching, a genuinely synchronous call stack
    /// with no enclosing MainActor Task already occupying a turn -- if
    /// this is ever driven from an async test caller the way
    /// attemptSessionRestoreFromDisk's sibling tests are, it needs the
    /// same SyncBridgeBox treatment first. The generous default deadline
    /// comfortably exceeds SessionDaemonClient.daemonQueryBoundTimeoutSeconds's
    /// own default bound, so a merely-slow (not unreachable) daemon
    /// still gets a real chance to answer; if it doesn't, this
    /// conservatively reports `false` -- the same "no evidence of an
    /// anomaly" default hasRunningPersistentSessions() itself already
    /// reports for a probe failure.
    private func hasRunningPersistentSessionsBridged(deadline: TimeInterval = 6.0) -> Bool {
        var result = false
        var done = false
        Task {
            result = await hasRunningPersistentSessions()
            done = true
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return result
    }

    /// Bug 3a/3b wiring shared by restoreSession()'s empty-outcome,
    /// timed-out, and restoredAny-false branches: moves whatever is
    /// currently on disk aside into the recovery file (a harmless no-op
    /// when nothing is there -- e.g. the "nothing was ever saved"
    /// sub-case), and, only when a file was actually moved, marks it
    /// recoverable and tells the user. Deliberately does NOT
    /// notify/flag on a no-op preserve: an on-disk file can be absent
    /// even after a successful restore() (e.g. restore() fell back to
    /// backupPath while savePath itself never existed), and a
    /// notification claiming a session is recoverable when
    /// session.recoverPreviousSession would find nothing would be
    /// actively misleading. On `.timedOut`, we do not know for certain
    /// whether a recovery file exists, so this never claims one does.
    private func preserveDiscardedSessionIfAny() {
        switch attemptPreserveDiscardedSessionOnDisk() {
        case .preserved:
            hasPreservedSessionSnapshot = true
            notifyPreviousSessionNotRestored()
        case .notPreserved:
            break
        case .timedOut:
            logger.warning("Timed out attempting to preserve a discarded session snapshot")
        }
    }

    func restoreSession() -> Bool {
        let outcome = attemptSessionRestoreFromDisk()

        // Bug 1: every restoreSession() invocation schedules the delayed
        // stability-confirmation reset, unconditionally -- independent of
        // what is found or done below -- so a healthy "nothing to
        // restore" launch does not leave the crash-loop counter
        // incremented forever (see this method's own doc comment).
        scheduleRecoveryCounterResetAfterStableLaunch()

        let snapshot: SessionSnapshot
        switch outcome {
        case .timedOut:
            // C3: never silently fall through to createNewWindow() as if
            // disk were confirmed empty -- we genuinely don't know
            // whether there was something to restore.
            logger.warning("Timed out reading session snapshot from disk")
            preserveDiscardedSessionIfAny()
            return false
        case .empty:
            // restore() failed to decode, nothing was ever saved, or the
            // crash-loop counter exceeded maxRecoveryAttempts --
            // preserveDiscardedSessionIfAny() harmlessly no-ops in the
            // "nothing was ever saved" sub-case.
            logger.info("No session to restore")
            preserveDiscardedSessionIfAny()
            return false
        case .snapshot(let restored):
            snapshot = restored.removingEmptyWindows()
        }

        guard !snapshot.windows.isEmpty else {
            // C4: with close=kill semantics, a genuinely empty on-disk
            // snapshot from a deliberate "closed every window" quit
            // should never coexist with the daemon still reporting a
            // running persistent session -- when it does, this is much
            // more likely a bug/race (see hasRunningPersistentSessions's
            // own doc comment) than a deliberate quit, so route through
            // preserve+notify instead of silently accepting it.
            if hasRunningPersistentSessionsBridged() {
                logger.warning("Empty session snapshot restored alongside a running persistent session; treating as an anomaly")
                preserveDiscardedSessionIfAny()
                notifyPreviousSessionNotRestored()
                return false
            }
            // The user deliberately closed every window before their
            // last quit -- not a loss to recover from, so this branch
            // does not preserve or notify.
            logger.info("No session to restore")
            return false
        }

        // F10 (V11, WARNING, r4-fix-spec.md): one listAll() subprocess
        // for the whole restore pass, instead of one per surface (see
        // fetchSessionsForAgentResume's doc comment). R6-C: no longer
        // waited on here, window/tab restoration proceeds immediately.
        fetchSessionsForAgentResume()
        var restoredAny = false

        for windowSnap in snapshot.windows {
            if restoreWindow(windowSnap) {
                restoredAny = true
            }
        }

        if !restoredAny {
            logger.warning("Failed to restore any windows")
            preserveDiscardedSessionIfAny()
            return false
        }

        return true
    }
}
