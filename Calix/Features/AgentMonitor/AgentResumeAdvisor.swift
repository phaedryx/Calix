// AgentResumeAdvisor.swift
// Calix
//
// Agent-resume daemon-query infra, extracted from AppDelegate: fetching
// the daemon's session ledger for the current restore/attach pass,
// reasserting history-persistence state at launch, and deciding whether
// a reattached persistent-session surface should have a resumable agent
// CLI session typed into it. AppDelegate retains its own copy of the
// `_sessionDaemonClientForTesting` seam and the unrelated
// `listAllSessionsBounded(client:)`-consuming `hasRunningPersistentSessions()`
// empty-snapshot-anomaly guard, calling across to
// `AgentResumeAdvisor.listAllSessionsBounded(client:)` for the latter.

import AppKit

@MainActor
final class AgentResumeAdvisor {
    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase, R6-C): when non-nil, used
    /// instead of `SessionDaemonClient.shared` inside
    /// `fetchSessionsForAgentResume`. Mirrors the
    /// `SessionDaemonClientProtocol` fake pattern already established by
    /// `SessionBrowserModelTests`/`SessionReconnectCoordinatorTests`
    /// rather than inventing a new one, since `SessionDaemonClient.shared`
    /// itself is a non-swappable `let` (unlike `NotificationManager
    /// .shared`). Lets a test control exactly when/whether the daemon
    /// round-trip completes, without spawning a real `calix-session`
    /// process, to prove `fetchSessionsForAgentResume` does or does not
    /// block the calling thread on it. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _sessionDaemonClientForTesting: SessionDaemonClientProtocol?
    #endif

    /// R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking): the async
    /// fetch task `fetchSessionsForAgentResume()` starts, shared by
    /// every surface created during the SAME restore/attach pass so
    /// `restoreTabSurfaces`'s fan-out `Task` (R8-D/H2) can await its
    /// result, right before calling `offerAgentResume`, instead of
    /// blocking on it. `restoreSession`/`attachWindow` each make exactly
    /// one call per pass (matching F10's original "one `listAll()` per
    /// pass" intent); `restoreWindow`/`restoreTabSurfaces` read this
    /// property synchronously afterward, within that same call stack.
    ///
    /// R8-D item 2 (H1, r8-fix-spec.md): no longer unconditionally
    /// overwritten. `fetchSessionsForAgentResume()` reuses an already
    /// in-flight task instead of starting a second daemon subprocess
    /// for the same purpose (a `listAll()` round-trip reflects the
    /// whole daemon-wide ledger regardless of which pass triggered it,
    /// so an overlapping pass reusing a still-in-flight fetch from a
    /// previous one is exactly as correct as waiting for a fresh one).
    /// Not `private` (P4 round-8 fix RED phase, G5): exposed read-only
    /// so `AppDelegateFetchSessionsForAgentResumeTests` can observe that
    /// a task was actually started, now that
    /// `fetchSessionsForAgentResume()` itself no longer returns a
    /// meaningful synchronous result.
    ///
    /// R10-B (r10-fix-spec.md): reset back to `nil` once the task it
    /// holds actually COMPLETES (see `agentResumeFetchGeneration`'s doc
    /// comment), not only when agent resume is disabled. Before this
    /// fix, the `== nil` reuse guard in `fetchSessionsForAgentResume()`
    /// never reset after a successful fetch, so every call after the
    /// very first one silently reused the launch-time snapshot forever;
    /// a first fetch that timed out permanently pinned an empty `[:]`
    /// result.
    private(set) var agentResumeSessionsTask: Task<[String: SessionInfo], Never>?

    /// R10-B (r10-fix-spec.md): monotonic counter identifying which
    /// `fetchSessionsForAgentResume()` call started the currently
    /// in-flight `agentResumeSessionsTask`, mirroring
    /// `BrowserTabController.snapshotGeneration`'s established pattern.
    /// The task's own completion compares this against its own captured
    /// generation before resetting `agentResumeSessionsTask` to `nil`,
    /// so a disable-then-re-enable cycle that starts a NEWER fetch
    /// while an older, already-cancelled one is still unwinding can
    /// never have that older fetch's completion clobber the newer
    /// task's reference.
    private var agentResumeFetchGeneration = 0

    /// R8-D item 1 (r8-fix-spec.md; r7-verdicts.md's "Unbounded await
    /// (D1)" finding): the deadline `SessionDaemonClientProtocol
    /// .listAllBounded()` races the real daemon round-trip against, so
    /// `agentResumeSessionsTask` always reaches a terminal state even
    /// if the daemon never responds at all.
    /// `AppDelegateOfferAgentResumePipelineBoundTests`'s 15s `XCTWaiter`
    /// bound comfortably exceeds this (R10-C item 2/5, r10-fix-spec.md:
    /// shared with `SessionBrowserModel.refresh()` via `listAllBounded()`'s
    /// `daemonQueryBoundTimeoutSeconds`. R14-B (r14-fix-spec.md) later gave
    /// `sessionStateBounded(id:)`'s reconnect-decision path its own,
    /// longer `sessionStateBoundTimeoutSeconds` instead of reusing this
    /// one, so the low- and high-consequence callers now deliberately use
    /// two separate bounds, not the single shared constant this comment
    /// used to describe).

    /// F10 (V11, WARNING, r4-fix-spec.md): starts (but does not wait
    /// for) the daemon's session list fetch, keyed by session ID, gated
    /// on `SessionSettings.agentResumeEnabled` (off, the default, spawns
    /// no subprocess at all, the same gate `offerAgentResume` itself
    /// used to check before spawning its own `Task`). `offerAgentResume`
    /// used to call `SessionDaemonClient.shared.listAll()` itself, once
    /// per restored surface: N concurrent `calix-session ls --all --json`
    /// subprocesses at launch for N restored persistent-session
    /// surfaces, each decoding the full ledger just to pick out one ID.
    /// Shared by `restoreSession` (one call for the whole restore pass)
    /// and `attachWindow` (one call for the single session being
    /// attached).
    ///
    /// R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking) fix: this used
    /// to `RunLoop.current.run` spin the calling (main) thread in 10ms
    /// steps for up to 2.0s, synchronously, on both call sites above,
    /// the opposite of this method's stated purpose. Now it only starts
    /// `agentResumeSessionsTask` and returns immediately; window/tab
    /// restoration proceeds without ever waiting on the daemon, and
    /// `restoreTabSurfaces`'s fan-out `Task` (R8-D/H2) awaits
    /// `agentResumeSessionsTask` itself, only where the result is
    /// actually needed.
    ///
    /// G5 (r8-fix-spec.md): returns `Void`, not a dictionary. The old
    /// return value was always `[:]` (no daemon response is ever
    /// available synchronously), never a meaningful result to report;
    /// `agentResumeSessionsTask` itself (see its own doc comment) is
    /// what callers actually need. Not `private` (round-6 RED phase):
    /// `AppDelegateFetchSessionsForAgentResumeTests` calls this directly
    /// to measure that it no longer blocks, matching this file's
    /// `offerAgentResume`/`attachWindow` direct-drive precedent.
    func fetchSessionsForAgentResume() {
        guard SessionSettings.agentResumeEnabled else {
            // R10-B item 2 (r10-fix-spec.md): cancel a still-in-flight
            // fetch instead of merely dropping the reference.
            // `Task.cancel()` only sets a cooperative flag, but R14-A
            // (r14-fix-spec.md) made `SessionDaemonClientProtocol
            // .bounded(...)` (the race `listAllSessionsBounded` below
            // ultimately awaits) honor that flag with a
            // `withTaskCancellationHandler` that cancels both its
            // internal race arms and resumes promptly -- reaching, in
            // turn, `SystemCommandRunner.run()`'s own R12-A cancellation
            // handler, which SIGTERMs the underlying `calix-session`
            // subprocess -- so a disable mid-flight now genuinely ends
            // the daemon round-trip promptly instead of merely dropping
            // an unobserved reference to it (or, pre-R14-A, riding out
            // the full bound regardless of this cancel() call).
            agentResumeSessionsTask?.cancel()
            agentResumeSessionsTask = nil
            return
        }
        // R8-D item 2 (H1): reuse whatever fetch is already in flight
        // rather than starting a second daemon subprocess for the
        // identical purpose.
        guard agentResumeSessionsTask == nil else { return }
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        agentResumeFetchGeneration += 1
        let generation = agentResumeFetchGeneration
        agentResumeSessionsTask = Task {
            let result = await AgentResumeAdvisor.listAllSessionsBounded(client: client)
            // R10-B item 1 (r10-fix-spec.md): reset back to nil once
            // THIS fetch completes, so the next
            // fetchSessionsForAgentResume() call starts a fresh daemon
            // round-trip instead of reusing an already-resolved (or
            // timed-out) snapshot forever. Guarded by generation (see
            // agentResumeFetchGeneration's own doc comment) so a newer
            // fetch started after a disable/re-enable cycle is never
            // clobbered by this one's completion.
            if self.agentResumeFetchGeneration == generation {
                self.agentResumeSessionsTask = nil
            }
            return result
        }
    }

    /// P6 (R-B4): the attach-spawned calix-session daemon always starts
    /// with history OFF (`DaemonConfig::history_enabled`'s bind-time
    /// default; see `ControlMsg::SetHistoryEnabled`'s own doc comment --
    /// a live, in-memory override, never persisted daemon-side),
    /// regardless of any `history on` a previous process lifetime sent
    /// it. A user with `historyPersistenceEnabled` on therefore needs it
    /// re-pushed once per launch, against whatever daemon this launch
    /// attaches to or spawns. Gated on `persistentSessionsEnabled` (no
    /// persistent daemon is ever spawned otherwise, so there is nothing
    /// to reassert to) AND `historyPersistenceEnabled`. Called once from
    /// `applicationDidFinishLaunching`, right after the
    /// `restoreSession()`/`createNewWindow()` branch resolves -- NOT
    /// piggybacked onto `fetchSessionsForAgentResume()`, which gates on
    /// the unrelated `agentResumeEnabled` setting and would silently
    /// skip reassertion for a user who has `persistentSessionsEnabled`
    /// and `historyPersistenceEnabled` on but `agentResumeEnabled` off.
    ///
    /// CAVEAT: the daemon that ends up serving this launch's
    /// persistent-session panes is spawned on demand, per pane, by the
    /// FIRST `calix-session attach --create` ghostty actually execs
    /// (`commands/attach.rs`'s `connect_or_spawn`) -- a process this
    /// call has no synchronous handle on and does not wait for. Unlike
    /// `attach`, the `history` CLI subcommand does not auto-spawn a
    /// daemon, so a reassertion that runs before any pane has actually
    /// attached could race a not-yet-running daemon and silently no-op.
    /// Left as documented best-effort rather than adding a bounded
    /// retry: this whole feature is opt-in/experimental, the corner
    /// self-heals on the next settings toggle (which also pushes
    /// immediately, via `HistoryPersistenceToggleCoordinator`) or the
    /// next launch, and a retry would add timers for a corner most
    /// launches never hit (the daemon is typically already running from
    /// a previous session by the time this races it).
    func reassertHistoryPersistenceIfNeeded() async {
        guard SessionSettings.persistentSessionsEnabled, SessionSettings.historyPersistenceEnabled else { return }
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        await client.setHistoryEnabled(true)
    }

    /// R8-D item 1 (r8-fix-spec.md; r7-verdicts.md's "Unbounded await
    /// (D1)" finding): delegates to
    /// `SessionDaemonClientProtocol.listAllBounded()` (R10-C item 2,
    /// r10-fix-spec.md, lifted from this method's own former
    /// implementation so `SessionBrowserModel.refresh()` shares the
    /// same bounded race and the same timeout constant instead of
    /// awaiting `listAll()` unbounded), then keys the result by session
    /// ID for `offerAgentResume`'s lookup.
    @MainActor
    static func listAllSessionsBounded(client: SessionDaemonClientProtocol) async -> [String: SessionInfo] {
        let sessions = await client.listAllBounded()
        // R12-A item 4 (r12-fix-spec.md): a disable mid-flight
        // (`fetchSessionsForAgentResume`'s guard above) cancels this
        // call's enclosing Task; skip the otherwise-pointless keying
        // work once cancelled instead of building a dictionary nobody
        // will read.
        guard !Task.isCancelled else { return [:] }
        return Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// P4: once a reattached persistent-session surface exists, checks
    /// the daemon's per-session meta (`AgentSessionMetaBridge`'s
    /// recording, resolved from the caller-supplied `sessions`, i.e.
    /// `fetchSessionsForAgentResume`'s result (F10), rather than this
    /// method querying the daemon itself) for a resumable agent CLI
    /// session and, if `SessionSettings.agentResumeEnabled`, types
    /// `SessionResumePlanner.initialInput` into the live surface via
    /// `sendText`. The `sendText` call is deliberately left as its own
    /// fire-and-forget `Task`, not tracked the way
    /// `SessionKillTracker.track`'s callers are, since dropping it on
    /// quit is intentional and harmless: it's a resume command not yet
    /// typed into a surface that's being quit anyway, not state that
    /// needs to survive teardown.
    ///
    /// Deliberately uses `GhosttySurfaceController.sendText` (which
    /// resolves to ghostty's `textCallback` -> `completeClipboardPaste`)
    /// rather than `ghostty_surface_config_s.initial_input`: the
    /// `initial_input` path only queues bytes into the surface's pty at
    /// creation time, before `calix-session attach`'s reattach
    /// connection is even established, which is unverified — this
    /// method waits for a live, reattached surface first, at the cost
    /// of one caveat verified against ghostty's core (`Surface
    /// .textCallback`): pasted text goes through the same completion
    /// path a real clipboard paste does, and most shells' bracketed
    /// paste handling does not treat a pasted trailing newline as
    /// Return — so this reliably reproduces "propose" mode
    /// (`agentResumeAutoExecute == false`, no trailing newline, user
    /// presses Return themselves) but "auto-execute" mode's trailing
    /// newline may not actually submit the command. Flagged in this
    /// feature's P4 handoff as needing live verification.
    ///
    /// Not `private` (P4 round-4 fix RED phase): `AppDelegateOfferAgentResumeTests`
    /// calls this directly to drive its decode/selection/sendText
    /// pipeline without a live daemon round-trip, matching this file's
    /// existing `attachWindow` direct-drive precedent.
    func offerAgentResume(tab: Tab, surfaceID: UUID, sessionID: String, sessions: [String: SessionInfo]) {
        guard SessionSettings.agentResumeEnabled else { return }
        guard let info = sessions[sessionID] else { return }
        let resumable = info.meta.compactMap { key, value -> (kind: String, agentSessionID: String)? in
            guard let kind = SessionResumePlanner.decodeMetaKey(key) else { return nil }
            return (kind, value)
        }.first
        guard let resumable else { return }
        guard let input = SessionResumePlanner.initialInput(
            agentKind: resumable.kind,
            agentSessionID: resumable.agentSessionID,
            autoExecute: SessionSettings.agentResumeAutoExecute
        ) else { return }

        #if DEBUG
        if let hook = _offerAgentResumeSendTextHookForTesting {
            Task { hook(surfaceID, input) }
            return
        }
        #endif
        Task {
            guard let controller = tab.registry.controller(for: surfaceID) else { return }
            controller.sendText(input)
        }
    }

    #if DEBUG
    /// Test seam (P4 round-4 fix, F14): when non-nil, called instead of
    /// `tab.registry.controller(for: surfaceID)?.sendText(_:)` inside
    /// `offerAgentResume`'s fire-and-forget `Task`. Lets
    /// `AppDelegateOfferAgentResumeTests` observe the exact text
    /// `offerAgentResume` computed without a live ghostty surface
    /// controller (`SurfaceRegistry.controller(for:)` only resolves
    /// real, ghostty-backed entries; a `_testInsert`-only fixture,
    /// this codebase's existing no-live-surface test pattern, never has
    /// one). `nil` (the default) leaves production behavior unchanged.
    /// DO NOT use from production code.
    var _offerAgentResumeSendTextHookForTesting: ((UUID, String) -> Void)?
    #endif
}
