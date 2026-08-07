# Silent-success IPC dialog + titlebar enable/disable toggle

Date: 2026-08-07

## Problem

`CalixWindowController.enableIPC()` (`CalixWindowController.swift:3766`) always shows an "IPC Enabled" summary alert once at least one agent's config write succeeds (`result.anySucceeded`), even when every selected agent configured cleanly. `disableIPC()` (`:3826`) always shows its "IPC Disabled" summary too. There's no way to tell "it all just worked" from "something needs attention" without reading the dialog text.

Separately, the only way to trigger `enableIPC()`/`disableIPC()` today is the command palette (`ipc.enable`/`ipc.disable`) — there's no titlebar affordance, unlike the git-changes panel, which got a titlebar toggle in the previous pass (`GitChangesTitlebarButtonView`).

This spec covers two related changes:

1. Make the config-setup dialog fire only on failure, naming the specific agents that failed.
2. Add a titlebar toggle button for IPC enable/disable, next to the git-changes button.

## Part 1: Failure-only dialog

### `IPCConfigResult` gets a failure accessor

Add to `IPCConfigResult` (`IPCConfigManager.swift:55`):

```swift
var failedAgents: [(agent: IPCAgent, error: Error)] {
    [
        (IPCAgent.claudeCode, claudeCode), (.codex, codex), (.openCode, openCode),
        (.hermes, hermes), (.cursorAgent, cursorAgent),
    ].compactMap { agent, status in
        guard case .failed(let error) = status else { return nil }
        return (agent, error)
    }
}
```

Mirrors the existing hand-rolled-per-field style of `anySucceeded` (`:62-69`) rather than the dictionary-keyed refactor floated in the prior per-agent-checklist spec — that refactor hasn't landed, so this stays consistent with the current shape.

### `enableIPC()` (`CalixWindowController.swift:3766`)

Unchanged failure paths (all already alert unconditionally, which is correct — they're failure-only today):
- No agents enabled in Settings → Agents (`:3767-3773`).
- Secure-token generation failure (`:3778-3781`).
- `!result.anySucceeded` (`:3791-3798`).
- `CalixMCPServer.shared.start(token:)` throws (`:3821-3823`).

Changed: the unconditional "IPC Enabled" alert at `:3816-3820`, reached whenever `result.anySucceeded` is true. Replace with:

- `result.failedAgents.isEmpty` → no dialog. Hook install still runs (`AgentHooksCoordinator.install()`, `:3806`) and still updates the sidebar banner (`AgentRegistry.shared.setHooksIssues`, `:3814`) exactly as today — only the pop-up is suppressed.
- `!result.failedAgents.isEmpty` → alert titled "IPC Setup Issue", body listing just the failed agents via the existing `configStatusLabel(_:name:verb:)` formatter (`:3851`), e.g.:
  ```
  Claude Code: error - <localizedDescription>
  Codex: error - <localizedDescription>
  ```
  Skipped/succeeded agents are omitted from this message — the dialog is about what needs attention, not a full status dump (that full dump still exists for the "IPC Enabled" case removed above, so no information is lost, just no longer shown by default when nothing failed).

Hook-install failures do **not** factor into whether this dialog shows, per the explicit scope decision: they're a separate concern with their own persistent surface (the sidebar banner), not a one-shot dialog.

### `disableIPC()` (`CalixWindowController.swift:3826`)

Same shape:

- `result.failedAgents.isEmpty` → no dialog.
- `!result.failedAgents.isEmpty` → alert titled "IPC Teardown Issue", body listing the agents that failed to remove.

Hook-removal visibility gap: today, `AgentHooksCoordinator.remove()`'s result (`hooksResult`, `:3829`) is only ever surfaced through the summary alert this change removes — unlike `enableIPC()`, `disableIPC()` never calls `AgentRegistry.setHooksIssues`. Left as-is, a hook-removal failure would become fully invisible once the dialog goes silent on config success. Fix: call `AgentRegistry.shared.setHooksIssues(Self.hooksIssueMessages(hooksResult))` from `disableIPC()` too, exactly as `enableIPC()` already does, using the same `hooksIssueMessages` helper (`:3886`). `AgentStatusView`'s sidebar banner becomes the standing surface for hook problems on both the install and remove paths; the dialog stays config-only on both.

### Not changed

- `AgentHooksCoordinator` itself, `configStatusMessage`/`agentHooksStatusMessage` (still used nowhere else — dead after this change unless kept for potential future full-status surfacing; delete if no longer referenced).
- The command-palette entries (`ipc.enable`/`ipc.disable`) — unaffected, they just call these two methods.

## Part 2: Titlebar enable/disable toggle

### New view: `IPCToggleTitlebarButtonView`

New file `Calix/Views/MainWindow/IPCToggleTitlebarButtonView.swift`, modeled directly on `GitChangesTitlebarButtonView.swift`:

```swift
struct IPCToggleTitlebarButtonView: View {
    var isEnabled: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        Button(action: { onToggle?() }) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .help(isEnabled ? "Disable AI Agent IPC" : "Enable AI Agent IPC")
        .accessibilityLabel("Toggle AI Agent IPC")
        .accessibilityAddTraits(isEnabled ? [.isSelected] : [])
        .accessibilityIdentifier(AccessibilityID.Titlebar.ipcToggleButton)
    }
}
```

No `isVisible` gate (unlike the git-changes button, which hides outside terminal tabs) — IPC is app-global state, not tab-scoped, so it's always shown.

`isEnabled` is driven by `AgentRegistry.shared.isServerRunning`, the existing `@Observable`-friendly proxy for `CalixMCPServer.isRunning` that `AgentStatusView` already relies on for the same reason (`CalixMCPServer` itself isn't `@Observable`).

### Hosting: combine into the existing titlebar accessory

Rather than a second `NSTitlebarAccessoryViewController` (ordering between multiple `.right`-attached accessories isn't guaranteed), both buttons share the one accessory already set up for git-changes. Rename for clarity and combine:

- `gitChangesAccessoryHostingView` → `titlebarAccessoryHostingView: NSHostingView<TitlebarAccessoryView>?`
- `setupGitChangesTitlebarAccessory()` → `setupTitlebarAccessory()`, same body, just hosts the new combined view.
- `currentGitChangesButtonView()` → `currentTitlebarAccessoryView() -> TitlebarAccessoryView`, a small new wrapper:

```swift
struct TitlebarAccessoryView: View {
    var ipcEnabled: Bool
    var onToggleIPC: (() -> Void)?
    var gitChangesOpen: Bool
    var gitChangesVisible: Bool
    var onToggleGitChanges: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            IPCToggleTitlebarButtonView(isEnabled: ipcEnabled, onToggle: onToggleIPC)
            GitChangesTitlebarButtonView(isOpen: gitChangesOpen, isVisible: gitChangesVisible, onToggle: onToggleGitChanges)
        }
    }
}
```

IPC button goes first (leftmost of the pair, i.e. closer to the window's center / further from the trailing edge) since it's the more persistent global-state indicator; git-changes stays rightmost, closest to where it already was. Only one line in `refreshHostingView()` changes (`:1074`), reassigning `titlebarAccessoryHostingView?.rootView = currentTitlebarAccessoryView()`.

### `CalixWindowController.toggleIPC()`

New method, same shape as `toggleGitChangesPanel()` (`:3752`):

```swift
private func toggleIPC() {
    if CalixMCPServer.shared.isRunning {
        disableIPC()
    } else {
        enableIPC()
    }
    refreshHostingView()
}
```

`enableIPC()`/`disableIPC()` already update `AgentRegistry.shared.isServerRunning` synchronously before returning (via `CalixMCPServer.finishStart()`/`.stop()`), so the immediate `refreshHostingView()` call picks up the new state correctly, same ordering as the git-changes toggle path.

### Accessibility

New `AccessibilityID.Titlebar.ipcToggleButton = "calix.titlebar.ipcToggleButton"` alongside the existing `gitChangesButton` constant (`AccessibilityID.swift:25`).

## Testing summary

- Unit test for `IPCConfigResult.failedAgents`: empty when all `.success`/`.skipped`; returns exactly the `.failed` entries otherwise, in a mixed result.
- `IPCConfigManagerTests.swift` (or a new `CalixWindowController`-adjacent test if the dialog-gating logic is factored into a small pure function per that file's existing pattern): verify the "show dialog" decision is `!result.failedAgents.isEmpty`, independent of hook results.
- UI test: titlebar shows both buttons; toggling IPC flips `isServerRunning`-driven appearance; accessibility identifiers resolve for both buttons (extending whatever UI test currently covers `AccessibilityID.Titlebar.gitChangesButton`).
- Manual: enable IPC with all agents installed and working → confirm no dialog. Force one agent to fail (e.g. make its config directory unwritable) → confirm dialog names only that agent. Repeat for disable. Confirm sidebar hook-issue banner still populates on both install and remove hook failures.

## Out of scope

- Any change to hook install/remove logic itself (`AgentHooksCoordinator`) — only its failure-reporting destination on the disable path changes (added banner call, no dialog change).
- Retrofitting `IPCConfigResult`'s hand-rolled-per-field shape into the dictionary-keyed version floated in the per-agent-checklist spec.
- Keyboard shortcut for the new titlebar toggle or the existing command-palette entries.
- Any change to `AgentStatusView`'s own disabled-placeholder text ("Open Command Palette → Enable AI Agent IPC") — leaving it as an alternate path is fine; not updating it to mention the new button is an acceptable minor staleness, not a correctness issue.
