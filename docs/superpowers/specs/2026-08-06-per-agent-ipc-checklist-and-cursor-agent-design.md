# Per-agent IPC checklist + cursor-agent support

Date: 2026-08-06

## Problem

"Enable AI Agent IPC" is one global action (`CalixWindowController.enableIPC()`/`disableIPC()`) that writes/removes the `calix-ipc` MCP server entry in *every* installed agent tool's config at once (Claude Code, Codex, OpenCode, Hermes). There's no way to opt a specific agent out. Separately, Cursor's `cursor-agent` CLI has zero integration in Calix today.

This spec covers two related changes:

1. A Settings checklist to choose which agents participate in IPC enablement.
2. Adding `cursor-agent` as a new IPC-capable agent (config-registration tier only — no hooks, no sidebar tracking).

## Part 1: Per-agent IPC checklist

### Data model

Add an agent-identity enum so the codebase has one canonical list instead of four independently hand-maintained axes for at least this feature's purposes:

```swift
enum IPCAgent: String, CaseIterable {
    case claudeCode, codex, openCode, hermes, cursorAgent

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .hermes: return "Hermes"
        case .cursorAgent: return "Cursor Agent"
        }
    }
}
```

Refactor `IPCConfigResult` (`IPCConfigManager.swift`) from four hand-written fields to `[IPCAgent: ConfigStatus]`. The current shape requires `anySucceeded` and `configStatusMessage` to hand-maintain an OR-chain / switch over every field; adding `cursorAgent` without updating both is a silent bug the compiler won't catch (the memberwise initializer would catch a missing field; these two computed properties would not). Keying by `IPCAgent` deletes that bug class and lets the checklist UI and `IPCConfigManager` both iterate `IPCAgent.allCases` instead of re-listing the four (now five) agents by hand in multiple places.

### Settings storage

New `AgentIPCSettings.swift` (`Features/IPC/`), following the exact `SettingsStore`-backed pattern used by `CockpitSettings`/`CommandTrackingSettings`:

- One `Bool` per `IPCAgent`, keys like `calix.ipc.claudeCodeEnabled`.
- **Default `true`** for every agent — explicit `store.object(forKey:) == nil` check (same pattern as `CommandTrackingSettings.trackingEnabled`), not the native `bool(forKey:)` false-default. Shipping this must not change behavior for existing users until they actively uncheck something.

### Enable/disable semantics

The core invariant: **a preference gates writing config, but never gates removing it.** This avoids orphaning a `calix-ipc` entry that points at a dead port.

| Action | Server running | Behavior |
|---|---|---|
| Checkbox → ON | yes | Immediately write that agent's config, using `CalixMCPServer.shared.port`/`.token`. |
| Checkbox → ON | no | Persist the preference only; nothing to write yet. |
| Checkbox → OFF | either | **Always** remove that agent's config, regardless of the new preference value — same as if the agent were never installed. |
| Global "Enable AI Agent IPC" | — | Writes config only for agents whose preference is `true`. Skipped agents get `.skipped(reason: "disabled in settings")`. |
| Global "Disable AI Agent IPC" | — | Unchanged: removes from all five agents regardless of checklist state (existing `disableIPC()` behavior — no directory-existence gate, no preference gate). |

Uncheck-always-cleans-up means the switch state and on-disk reality can never drift apart, and a later re-check simply re-writes.

### All-agents-unchecked edge case

If every `IPCAgent` preference is `false`, `CalixWindowController.enableIPC()` must detect this **before** generating a token or starting `CalixMCPServer.shared`, and show an alert explaining all agents are disabled in Settings → Agents. Today, an all-`.skipped` result falls into the `!result.anySucceeded` branch, which stops the server it just started and shows "No agent configs found. Configure manually if needed." — a misleading message once "user preference" is a possible cause distinct from "nothing installed." The two causes must produce distinguishable messages (or the preference case must short-circuit earlier, as above).

### Settings UI

Five new `SettingsRow` cases in the `Agents` pane, declared **contiguously** (rendering order follows declaration order in `paneStack`): `ipcClaudeCode`, `ipcCodex`, `ipcOpenCode`, `ipcHermes`, `ipcCursorAgent`. Each renders via the existing `controlRow(label:control:)` + `NSSwitch` pattern (matching `agentHookApprovalRow()` etc.) — this is a deliberate five-rows-of-one-control choice, not a new custom checklist widget, to stay consistent with every other Settings row in the codebase.

- Only the first case (`ipcClaudeCode`) returns a `SectionHeading` ("IPC-Enabled Agents" / subtitle: "Choose which agent tools get the Calix IPC MCP server when you enable IPC."); the other four are added to `sectionHeading(for:)`'s `nil` case list.
- Initial switch state = `AgentIPCSettings` preference (not live server status — the switch reflects intent, matching the "ON but server not running" row in the table above).
- If an agent's config directory doesn't exist (`ConfigFileUtils.directoryExists`, via `AgentToolPaths`), disable that switch and append "(not installed)" to its label.
- Toggle actions: apply the truth table above. On a live write/remove failure while the server is running, surface it — reuse the existing `NSAlert` pattern rather than inventing a new inline-error UI, since failures here should be rare and this keeps the diff small.
- New `AccessibilityID.Settings` identifiers for each of the five switches (tests grep on these).

## Part 2: cursor-agent support (IPC-only tier)

Scope for this pass: `cursor-agent` gets the same MCP config-registration tier as Hermes today — IPC yes, hooks/sidebar/approval-routing no. Full integration (hooks, `AgentEntry.cursorAgentKind`, sidebar tracking, approval-routing gate, title-detection) is out of scope; revisit as a separate pass if wanted later.

### New `CursorAgentConfigManager.swift` (`Features/IPC/`)

Modeled directly on `ClaudeConfigManager`'s three-method shape (`enableIPC`/`disableIPC`/`isIPCEnabled`), targeting `~/.cursor/mcp.json`. Confirmed against Cursor's own docs (`cursor.com/docs/mcp`, `cursor.com/docs/cli/mcp`): a remote MCP server entry is

```json
{
  "mcpServers": {
    "calix-ipc": {
      "url": "http://127.0.0.1:<port>/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Two deliberate deviations from the Claude template:

- **No `"type"` field.** Cursor's docs state `type` is required only for STDIO servers; a bare `url` is enough for a remote/HTTP one.
- **No `X-Calix-Surface-ID` header.** Claude's entry sends `${CALIX_SURFACE_ID:-}` — bash-style empty-default interpolation. cursor-agent's own interpolation syntax is `${env:VAR}`; whether it supports a default-on-unset form is unconfirmed, and guessing wrong risks breaking cursor-agent's config parse entirely (the same failure mode the existing Claude-side comment warns about). Verified in `CalixMCPServer.swift` that omitting the header is safe server-side: `header(named:in:)` returns `nil` for an absent key, and `parseSurfaceID`/`resolveSurfaceID` already treat "header absent" and "header present but empty" identically as "no binding for this connection" — there's no force-unwrap or reject path that distinguishes them.

  **Named limitation**: cursor-agent panes get no automatic surface→peer binding. Calix's calix-ipc tools that target a specific pane won't auto-resolve to a cursor-agent pane the way they do for Claude/Codex. Follow-up candidate: try cursor-agent's own `${env:CALIX_SURFACE_ID}` form once someone can verify its unset-variable behavior live, and add the header if it's safe.

### Wiring (mechanical, same shape as Hermes)

- `AgentToolPaths.swift`: add `cursorAgentConfigDirectory = NSHomeDirectory() + "/.cursor"`.
- `IPCConfigManager`: add `.cursorAgent` to the (now dictionary-keyed) `IPCConfigResult`; gate `enableIPC` on `cursorAgentConfigDirectory` existing, same as the other four.
- `IPCConfigManager.isIPCEnabled()`: add `cursorAgent` to the returned per-agent status (already has zero callers today outside its own definition — this checklist feature is its first real caller).
- `CalixWindowController.swift:3878` (`isAIAgentTitle`): its comment instructs it to stay in sync with `IPCConfigResult`'s axes. Either add a `"cursor-agent"` substring match (not bare `"cursor"` — too many false positives against the mouse/text-cursor code elsewhere in this file) or update the comment to state cursor-agent is intentionally excluded from title-based detection in this pass. Recommend the latter, since this pass explicitly excludes sidebar tracking.
- `Calix.xcodeproj/project.pbxproj`: manually add the new file to its group and target membership (this project does not use `PBXFileSystemSynchronizedRootGroup` — confirmed no matches for it in the pbxproj).

### Verification

Unit tests (`CursorAgentConfigManagerTests.swift`, mirroring `ClaudeConfigManagerTests.swift`) prove the JSON round-trips correctly but do **not** prove cursor-agent can actually use the entry. Required manual verification step before considering this done: write the config via the app (or the new manager directly), then run `cursor-agent mcp list` and confirm `calix-ipc` appears and shows connected.

## Testing summary

- `AgentIPCSettingsTests.swift`: default-true behavior, persistence, independent per-agent state.
- `CursorAgentConfigManagerTests.swift`: enable/disable/isIPCEnabled round-trip against a temp file (existing pattern).
- `IPCConfigManagerTests.swift`: extend for — preference-disabled agent is skipped on enable; disable ignores preference; all-agents-disabled short-circuit; `cursorAgent` participates in `anySucceeded`/status messaging now that `IPCConfigResult` is dictionary-keyed.
- `SettingsPaneTests.swift`: update the hardcoded `SettingsRow.allCases` expected list/count for the five new rows.
- Manual: `cursor-agent mcp list` after enabling, per Part 2's verification step above.

## Out of scope (this pass)

- cursor-agent hooks/plugin wiring, `AgentEntry.cursorAgentKind`, Agents-sidebar status tracking, approval-hook routing gate, title-detection heuristics for cursor-agent.
- Any change to the *global* enable/disable command-palette entries beyond respecting the new per-agent preference.
- Retrofitting the other three existing hand-maintained "agent list" axes (`AgentHooksResult`, `AgentEntry.kind` constants, the approval-routing gate) into `IPCAgent` — only `IPCConfigResult` is touched, since that's the one this feature actually reads/writes.
