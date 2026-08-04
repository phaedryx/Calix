// SessionReconnectCoordinator.swift
// Calyx
//
// Decides what to do when a persistent-session surface's
// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` fires: query the daemon for the
// session's actual state (see `SessionDaemonClient`'s header comment for
// why macOS's exit code can't be trusted) and either close the pane
// (the session really ended) or reconnect (the attach process merely
// disconnected).
//
// Attempt tracking is keyed by sessionID rather than surfaceID so it
// survives a reconnect's surface swap (`SessionSurfaceMap
// .replaceSurface`); consecutive `.running`/`.unreachable` decisions
// are capped at `maxReconnectAttempts`, giving up (closing the pane
// with DETACH, not kill, semantics — see `SessionReconnectDecision
// .giveUp`'s doc comment) instead of retrying forever once exceeded;
// and the gate for whether a surface is managed at all is "does
// `surfaceMap` have a session for this surface", not the global
// `SessionSettings.persistentSessionsEnabled` toggle — a surface
// already tracked must keep being managed even if the user turns off
// "start new panes as persistent" afterward (that toggle only affects
// `SessionSpawnPlanner`'s decision for *new* surfaces).

import Foundation

/// Reconnect-flashing-bug fix: narrow `#if DEBUG` override hook for
/// `SessionReconnectCoordinator.reconnectEstablishGraceMilliseconds`,
/// mirroring `SessionDaemonClientBoundTimeoutOverrides`'s identical
/// shape/reasoning exactly. `nil` (the default) means "use the
/// production value" (2000ms); a test sets a tiny, distinguishable
/// value so it can assert the grace-period wait's plumbing without
/// waiting out the real one. `nonisolated(unsafe)` is sound because the
/// only production reader is that computed property, and every test
/// that sets it resets it back to `nil` in its own `tearDown()`. Name
/// kept as `CalyxWindowControllerReconnectGraceOverrides` even after
/// this move -- several tests reference it by that name directly.
#if DEBUG
enum CalyxWindowControllerReconnectGraceOverrides {
    nonisolated(unsafe) static var reconnectEstablishGraceMilliseconds: UInt64?
}
#endif

/// Round-18 finding G6: what `performReconnect`'s grace `Task` learns from
/// `reconnectGraceProbe(sessionID:)` before calling `markEstablished`. Time
/// alone (the grace-period wait) plus surface identity alone is not
/// positive evidence the replacement is actually connected -- an attach
/// process that dies SLOWER than the grace window keeps resetting the
/// attempt count every cycle without ever advancing it, so `.giveUp` never
/// fires. `.established` requires the daemon to report the session
/// `Running` with at least one attached client; anything else, including a
/// probe failure, is `.notEstablished`.
enum ReconnectGraceProbeResult: Sendable, Equatable {
    case established
    case notEstablished
}

/// The coordinator's own view of `CalyxWindowController.performReconnect`'s
/// FFI/surface-swap half, handed back across `SessionReconnectSurfaceSwapping`
/// so the coordinator never needs to know what a `Tab`/`SessionRef`/
/// `SurfaceView` is.
struct ReconnectSurfaceSwapResult {
    let newSurfaceID: UUID
    /// `tab.sessionRefs[oldSurfaceID]?.host != nil`, read by the delegate
    /// implementation, so the coordinator's grace-establish branch works
    /// without ever knowing what a Tab/SessionRef is.
    let isRemote: Bool
}

/// Delegate boundary between `SessionReconnectCoordinator`'s timing/dedup/
/// give-up logic and `CalyxWindowController`'s actual FFI surface swap --
/// the coordinator calls back into the controller for this ONE thing only,
/// never for timing/dedup/give-up, which stay entirely inside the
/// coordinator.
@MainActor
protocol SessionReconnectSurfaceSwapping: AnyObject {
    /// Command synthesis, tab.registry.createSurface, splitTree/sessionRefs/
    /// SessionSurfaceMap/CommandLogStore remap, reconnectingSurfaceIDs-guarded
    /// destroy of oldSurfaceID -- i.e. today's performReconnect body minus its
    /// grace-Task tail. nil on failure, mirroring performReconnect's early
    /// returns exactly.
    func performReconnectSurfaceSwap(oldSurfaceID: UUID, sessionID: String) -> ReconnectSurfaceSwapResult?
}

enum SessionReconnectDecision: Sendable, Equatable {
    /// The session actually ended — close the pane normally (kill
    /// semantics: the daemon confirmed the child process is gone, so
    /// there is nothing left to reattach to).
    case closePane
    /// Re-run `calyx-session attach --create` for `sessionID`. `attempt`
    /// is the 1-based count of consecutive reconnect attempts for this
    /// sessionID, for the caller to compute a backoff delay from.
    case reconnect(sessionID: String, attempt: Int)
    /// Reconnect attempts exceeded `maxReconnectAttempts`; give up and
    /// close the pane now, using DETACH (not kill) semantics. Unlike
    /// `.closePane`, the daemon here was only ever reported unreachable
    /// — never confirmed exited — so the underlying `calyx-session` may
    /// still be legitimately running (e.g. slow to start). Closing the
    /// pane deterministically at this point, rather than leaving it
    /// dangling for a later keypress to close, keeps the last-pane/
    /// last-window quit cascade's timing consistent with every other
    /// session-ending path (a prior design that left the pane open only
    /// deferred that same cascade to an unpredictable later moment,
    /// per review finding, and could not rely on ghostty rendering
    /// anything informative in the meantime). Carries no payload: the
    /// caller already has `surfaceID` in hand and resolves whatever
    /// else it needs (sessionID, tab) itself via `SessionSurfaceMap`.
    case giveUp
}

@MainActor
final class SessionReconnectCoordinator {

    /// After this many consecutive `.running`/`.unreachable` reconnect
    /// decisions for the same sessionID with no intervening
    /// `markEstablished(sessionID:)`, give up (`.giveUp` — closes the
    /// pane with detach, not kill, semantics; see the case's doc
    /// comment) instead of retrying forever.
    static let maxReconnectAttempts = 5

    private let daemonClient: SessionDaemonClientProtocol
    /// Resolves which calyx-session a surface belongs to. Tests inject
    /// a fresh instance for isolation instead of mutating the shared
    /// singleton.
    private let surfaceMap: SessionSurfaceMap
    private let onDecision: (UUID, SessionReconnectDecision) -> Void

    /// The one call the coordinator makes back into
    /// `CalyxWindowController` -- the actual FFI surface swap. Never
    /// consulted for timing/dedup/give-up, which stay entirely inside
    /// this coordinator. Set once, alongside `onDecision`, in
    /// `CalyxWindowController`'s `sessionReconnectCoordinator` lazy-var
    /// init.
    weak var surfaceSwapDelegate: SessionReconnectSurfaceSwapping?

    /// Consecutive reconnect-attempt count keyed by sessionID (not
    /// surfaceID): a reconnect replaces the surface, so tracking by
    /// surfaceID would silently reset backoff on every single
    /// reconnect instead of accumulating across them. Reset by
    /// `markEstablished(sessionID:)` / `markClosed(sessionID:)`.
    private(set) var attemptCounts: [String: Int] = [:]

    /// Surfaces with a `childExited` call currently awaiting the
    /// daemon's reply. Guards against two overlapping
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` events for the same surface
    /// (e.g. a flapping daemon connection) racing each other into two
    /// separate attempt-count increments / decisions for what is really
    /// one disconnect.
    private var inFlightSurfaceIDs: Set<UUID> = []

    /// Reconnect-flashing-bug fix: `performReconnect`'s deferred-reset
    /// confirmation `Task` per replacement surface, keyed by the NEW
    /// surfaceID (not sessionID) so two different reconnects never
    /// collide on the same key. See `performReconnect`'s doc comment for
    /// why the `markEstablished(sessionID:)` reset itself is deferred
    /// behind a grace period rather than firing immediately. Cancelled
    /// and cleared via `cancelAllReconnectWork()`, called from
    /// `CalyxWindowController.windowWillClose` alongside its own
    /// per-window `Task`-dictionary discipline.
    private var reconnectEstablishGraceTasks = KeyedTaskRegistry<UUID>()

    init(
        daemonClient: SessionDaemonClientProtocol,
        surfaceMap: SessionSurfaceMap,
        onDecision: @escaping (UUID, SessionReconnectDecision) -> Void
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
        self.onDecision = onDecision
    }

    /// Gated solely on `surfaceMap.sessionID(for: surfaceID) != nil` —
    /// a surface already tracked as a persistent session must keep
    /// being managed for reconnect purposes regardless of
    /// `SessionSettings.persistentSessionsEnabled`, which only affects
    /// `SessionSpawnPlanner`'s decision for *new* surfaces.
    ///
    /// `isRemote` (P5 remote sessions, retires the former "ACCEPTED V1
    /// LIMITATION" this comment used to document): `daemonClient
    /// .sessionStateBounded(id:)` queries the LOCAL calyx-session daemon
    /// only, so it can never meaningfully answer for a REMOTE session --
    /// the local daemon simply has no record of a session whose daemon
    /// lives entirely on the remote host (see `CalyxWindowController
    /// .performReconnect`'s grace-Task doc comment for the same root
    /// cause affecting establishment). `isRemote: true` therefore SKIPS
    /// the local daemon query entirely and treats the disconnect as
    /// retryable exactly like today's `.running`/`.unreachable` branch:
    /// increment the attempt counter, `.reconnect` while under
    /// `maxReconnectAttempts`, `.giveUp` once exceeded. `isRemote: false`
    /// (the default) behaves IDENTICALLY to before this parameter
    /// existed: query the daemon, branch on `.exited`/`.running`/
    /// `.unreachable` exactly as before -- every existing call site
    /// (production and test) keeps compiling and behaving unchanged.
    func childExited(surfaceID: UUID, isRemote: Bool = false) async {
        guard let sessionID = surfaceMap.sessionID(for: surfaceID) else { return }
        guard !inFlightSurfaceIDs.contains(surfaceID) else { return }
        inFlightSurfaceIDs.insert(surfaceID)
        defer { inFlightSurfaceIDs.remove(surfaceID) }

        if isRemote {
            let attempt = (attemptCounts[sessionID] ?? 0) + 1
            guard attempt <= Self.maxReconnectAttempts else {
                attemptCounts[sessionID] = nil
                onDecision(surfaceID, .giveUp)
                return
            }
            attemptCounts[sessionID] = attempt
            onDecision(surfaceID, .reconnect(sessionID: sessionID, attempt: attempt))
            return
        }

        switch await daemonClient.sessionStateBounded(id: sessionID) {
        case .exited:
            attemptCounts[sessionID] = nil
            onDecision(surfaceID, .closePane)
        case .running, .unreachable:
            let attempt = (attemptCounts[sessionID] ?? 0) + 1
            guard attempt <= Self.maxReconnectAttempts else {
                attemptCounts[sessionID] = nil
                onDecision(surfaceID, .giveUp)
                return
            }
            attemptCounts[sessionID] = attempt
            onDecision(surfaceID, .reconnect(sessionID: sessionID, attempt: attempt))
        }
    }

    /// Resets `attemptCounts[sessionID]` once a reconnect attempt is
    /// confirmed to have succeeded (the pane is live again), so a
    /// later, unrelated disconnect starts backing off from attempt 1
    /// again instead of continuing a stale count. Takes `sessionID`
    /// directly rather than a surfaceID: by the time a reconnect
    /// succeeds, the OLD surfaceID has already been replaced in
    /// `surfaceMap` (`replaceSurface`), so resolving through it here
    /// would resolve a mapping that no longer points anywhere.
    func markEstablished(sessionID: String) {
        attemptCounts[sessionID] = nil
    }

    /// Drops `sessionID`'s attempt count when the user explicitly kills
    /// the session (`SessionCloseKillPolicy.shouldKill` decided `true`)
    /// rather than waiting for a reconnect/cap decision to clear it —
    /// otherwise a stale entry for a now-dead sessionID would linger in
    /// `attemptCounts` indefinitely.
    func markClosed(sessionID: String) {
        attemptCounts[sessionID] = nil
    }

    /// Waits out `attempt`'s backoff delay, then re-attaches. A stale
    /// `oldSurfaceID` (the pane was closed by the user in the meantime) is
    /// handled by `performReconnectSurfaceSwap`'s own `findTab` lookup
    /// coming back `nil`.
    func scheduleReconnect(oldSurfaceID: UUID, sessionID: String, attempt: Int) {
        let delaySeconds = Self.reconnectBackoffSeconds(forAttempt: attempt)
        Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            self?.performReconnect(oldSurfaceID: oldSurfaceID, sessionID: sessionID)
        }
    }

    /// Delegates the actual FFI surface swap to `surfaceSwapDelegate`,
    /// then owns the deferred-reset grace `Task` for the replacement --
    /// see the grace-Task block's own comment for the flashing-bug
    /// history this timing exists to fix. A `nil` result from the
    /// delegate (surface creation failed, or the pane was closed by the
    /// user in the meantime) is a no-op, mirroring the delegate's own
    /// early-return contract exactly.
    private func performReconnect(oldSurfaceID: UUID, sessionID: String) {
        guard let result = surfaceSwapDelegate?.performReconnectSurfaceSwap(
            oldSurfaceID: oldSurfaceID, sessionID: sessionID
        ) else { return }
        let newSurfaceID = result.newSurfaceID
        let isRemote = result.isRemote

        // HIGH-SPEED RECONNECT FLASHING BUG (see
        // SessionReconnectAttemptResetTimingTests's header comment):
        // resetting sessionID's attempt count immediately here, right
        // after the swap, used to mean a replacement surface whose
        // attach process dies right away against a still-unreachable
        // daemon is followed by another childExited decision that gets
        // treated as attempt 1 again (0s backoff) instead of attempt 2+
        // -- backoff never grows and maxReconnectAttempts is never
        // reached, so giveUp never fires: an infinite full-speed
        // reconnect loop (the user-visible pane flashing).
        // Establishment now also requires reconnectGraceProbe(sessionID:)
        // to report the daemon sees the session running with at least one
        // attached client. A probe failure is fail-closed.
        reconnectEstablishGraceTasks.insert(newSurfaceID, task: Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reconnectEstablishGraceMilliseconds))
            guard let self else { return }
            if !Task.isCancelled, self.surfaceMap.surfaceID(for: sessionID) == newSurfaceID {
                if isRemote {
                    self.markEstablished(sessionID: sessionID)
                } else if await self.reconnectGraceProbe(sessionID: sessionID) == .established {
                    self.markEstablished(sessionID: sessionID)
                }
            }
            self.reconnectEstablishGraceTasks.removeValue(forKey: newSurfaceID)
        })
    }

    /// Cancels every in-flight reconnect-establish grace `Task`. Called
    /// from `CalyxWindowController.windowWillClose` alongside its own
    /// per-window `Task`-dictionary teardown.
    func cancelAllReconnectWork() {
        reconnectEstablishGraceTasks.cancelAll()
    }

    /// Exponential backoff for reconnect attempts, capped at 30s:
    /// attempt 1 reconnects immediately (0s); attempts 2-6 wait
    /// 1/2/4/8/16s; attempt 7+ waits the 30s cap. Keeps a persistently
    /// unreachable daemon from spinning the pane in a tight retry loop
    /// while still reconnecting instantly for the common case (the
    /// attach process merely disconnected once).
    private static func reconnectBackoffSeconds(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        return min(30.0, pow(2.0, Double(attempt - 2)))
    }

    /// How long `performReconnect`'s confirmation `Task` waits before
    /// resetting a replacement surface's session's attempt count (see
    /// that method's doc comment for why the reset is deferred at all).
    /// Production default 2000ms: long enough that a replacement whose
    /// attach process dies right away (the flashing bug's own failure
    /// mode) is very unlikely to still look "alive" by the time this
    /// fires, without leaving a legitimately-recovered session's attempt
    /// count wrongly nonzero for long after it's actually fine again.
    /// Same `#if DEBUG`-only override seam as `SessionDaemonClientProtocol
    /// .daemonQueryBoundTimeoutSeconds`.
    private static var reconnectEstablishGraceMilliseconds: UInt64 {
        #if DEBUG
        if let override = CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds {
            return override
        }
        #endif
        return 2000
    }

    /// Round-18 G6: positive-evidence check `performReconnect`'s grace
    /// `Task` consults immediately before `markEstablished`, alongside
    /// (not instead of) the existing surface-identity check -- see that
    /// call site's doc comment for why time and surface identity alone
    /// are insufficient. Mirrors `CalyxWindowController
    /// .createReconnectSurface`'s hook-first/real-fallback shape: under
    /// `#if DEBUG`, a set `_reconnectGraceProbeForTesting` hook is
    /// consulted first, with a throwing hook collapsed to
    /// `.notEstablished` (fail-closed) rather than propagated. The real
    /// fallback reuses the existing bounded `listAllBounded()` race
    /// (already used by `SessionBrowserModel.refresh()`/`AppDelegate
    /// .fetchSessionsForAgentResume()`) against the same
    /// `SessionDaemonClient.shared` singleton `SessionReconnectCoordinator`
    /// already wires in, rather than adding a second daemon-query
    /// primitive. `.established` requires a matching `SessionInfo` whose
    /// `state == .running` AND `attachedClients >= 1`; a missing match,
    /// `.exited`, zero attached clients, or `listAllBounded()`'s own
    /// already-bounded degrade-to-`[]` all fall through to
    /// `.notEstablished` for free.
    private func reconnectGraceProbe(sessionID: String) async -> ReconnectGraceProbeResult {
        #if DEBUG
        if let hook = _reconnectGraceProbeForTesting {
            return (try? await hook()) ?? .notEstablished
        }
        #endif
        let sessions = await SessionDaemonClient.shared.listAllBounded()
        guard let match = sessions.first(where: { $0.id == sessionID }) else {
            return .notEstablished
        }
        return (match.state == .running && match.attachedClients >= 1) ? .established : .notEstablished
    }

    #if DEBUG
    /// Test seam (round-18 G6 RED phase): when non-nil, called INSTEAD of
    /// the real `SessionDaemonClient.shared.listAllBounded()` daemon query
    /// inside `reconnectGraceProbe(sessionID:)`, mirroring
    /// `CalyxWindowController._performReconnectSurfaceCreationHookForTesting`'s
    /// exact hook-first/real-fallback style. A throwing hook is fail-closed
    /// by construction: `reconnectGraceProbe(sessionID:)` treats it exactly
    /// like an explicit `.notEstablished` answer. `nil` (the default)
    /// leaves production behavior unchanged. DO NOT use from production
    /// code.
    var _reconnectGraceProbeForTesting: (() async throws -> ReconnectGraceProbeResult)?
    #endif

    #if DEBUG
    /// Test seam (reconnect-flashing-bug RED phase): directly seeds
    /// `attemptCounts[sessionID]`, letting a controller-level test set
    /// up "N prior consecutive failures already recorded" without a
    /// live daemon round-trip through `childExited(surfaceID:)`. DO NOT
    /// use from production code.
    func _testSeedAttemptCount(sessionID: String, count: Int) {
        attemptCounts[sessionID] = count
    }
    #endif
}
