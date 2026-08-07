# IPC Failure Dialog + Titlebar Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the "Enable/Disable AI Agent IPC" flow silent when every selected agent configures cleanly, popping a dialog only to name the agents that failed — and add a titlebar button so that flow doesn't require the command palette.

**Architecture:** `IPCConfigResult` (in `IPCConfigManager.swift`) gains a `failedAgents` accessor; `CalixWindowController.enableIPC()`/`disableIPC()` use it to gate their summary `NSAlert` instead of showing one unconditionally. A new `IPCToggleTitlebarButtonView` joins the existing `GitChangesTitlebarButtonView` inside one combined `TitlebarAccessoryView`, sharing the window's single `NSTitlebarAccessoryViewController` (a second `.right`-attached accessory has no guaranteed ordering, so both buttons live in one `HStack` instead).

**Tech Stack:** Swift 6.2, AppKit + SwiftUI (macOS 26.0 deployment target), XCTest (`CalixTests` target), `xcodebuild test` via CLI, `xcodegen` for project-file regeneration after adding files.

## Global Constraints

- Every task must leave the app building (`xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`) and `CalixTests` green before commit.
- Any new Swift file requires `xcodegen generate` before the build step — `Calix.xcodeproj` is gitignored and regenerated from `project.yml`'s directory globs.
- Dialog scope is config-setup only: hook install/remove failures (`AgentHooksCoordinator`) stay on the existing `AgentRegistry.setHooksIssues` sidebar banner, never the pop-up.
- No new dependencies; no keyboard shortcut work for the new button or the existing command-palette entries.
- No new XCUITest coverage for the titlebar button: `GitChangesTitlebarButtonView`, the sibling this mirrors, shipped with none either, and this codebase's existing titlebar/settings E2E suites (see `SettingsTogglesE2ETests.swift`'s own header) carry real hermeticity overhead (shared `UserDefaults` domains, per-test isolation) that a real MCP-server-driven toggle would multiply. Manual verification steps cover it instead, consistent with that precedent.

---

### Task 1: `IPCConfigResult.failedAgents`

**Files:**
- Modify: `Calix/Features/IPC/IPCConfigManager.swift:55-70`
- Test: `CalixTests/IPC/IPCConfigManagerTests.swift`

**Interfaces:**
- Produces: `IPCConfigResult.failedAgents: [(agent: IPCAgent, error: Error)]` — used by Tasks 2 and 3.

- [ ] **Step 1: Write the failing tests**

Append to `CalixTests/IPC/IPCConfigManagerTests.swift` (new `// MARK:` section at the end of the class, before the closing brace):

```swift
    // MARK: - IPCConfigResult.failedAgents

    func test_failedAgents_emptyWhenAllSuccessOrSkipped() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .skipped(reason: "not installed"),
            openCode: .success,
            hermes: .skipped(reason: "disabled in settings"),
            cursorAgent: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.failedAgents.isEmpty)
    }

    func test_failedAgents_returnsOnlyFailedEntries() {
        let claudeError = NSError(domain: "test", code: 1)
        let hermesError = NSError(domain: "test", code: 2)
        let result = IPCConfigResult(
            claudeCode: .failed(claudeError),
            codex: .success,
            openCode: .skipped(reason: "not installed"),
            hermes: .failed(hermesError),
            cursorAgent: .success
        )
        let failures = result.failedAgents
        XCTAssertEqual(failures.map(\.agent), [.claudeCode, .hermes])
        XCTAssertEqual((failures[0].error as NSError).code, 1)
        XCTAssertEqual((failures[1].error as NSError).code, 2)
    }

    func test_failedAgents_allFailed() {
        let error = NSError(domain: "test", code: 3)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            cursorAgent: .failed(error)
        )
        XCTAssertEqual(result.failedAgents.map(\.agent), IPCAgent.allCases)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/IPCConfigManagerTests`
Expected: FAIL to compile — `value of type 'IPCConfigResult' has no member 'failedAgents'`.

- [ ] **Step 3: Implement `failedAgents`**

In `Calix/Features/IPC/IPCConfigManager.swift`, add this computed property to `IPCConfigResult` right after `anySucceeded` (currently ending at line 69, just before the struct's closing brace at line 70):

```swift
    /// The subset of agents whose `ConfigStatus` is `.failed`, paired with
    /// the underlying error. Used by `CalixWindowController` to decide
    /// whether the enable/disable summary alert should appear at all, and
    /// if so, to name exactly which agents need attention -- `.skipped`
    /// agents (not installed, or disabled in settings) are intentional
    /// outcomes, not failures, so they're excluded here.
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/IPCConfigManagerTests`
Expected: `** TEST SUCCEEDED **`, all `failedAgents` tests pass alongside the existing `anySucceeded` tests.

- [ ] **Step 5: Commit**

```bash
git add Calix/Features/IPC/IPCConfigManager.swift CalixTests/IPC/IPCConfigManagerTests.swift
git commit -m "feat: add IPCConfigResult.failedAgents for failure-only reporting"
```

---

### Task 2: `enableIPC()` shows a dialog only on failure

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:3766-3895` (the whole `// MARK: - IPC` block: `enableIPC()`, `disableIPC()`, `AgentHooksMode`, `configStatusLabel`, `configStatusMessage`, `agentHooksStatusMessage`, `hooksIssueMessages`)

**Interfaces:**
- Consumes: `IPCConfigResult.failedAgents` (Task 1).
- Produces: `failedAgentsMessage(_:)` — used by Task 3's `disableIPC()` change too.

This task rewrites `enableIPC()` and deletes the now-dead formatting helpers in the same pass, since leaving them in place with zero callers after this change would be dead code. `disableIPC()` itself is touched in Task 3, but its helper dependencies (`configStatusMessage`/`agentHooksStatusMessage`) are only used by these two methods, so they're removed here alongside `enableIPC()`'s rewrite — Task 3 lands second and must not reference them.

- [ ] **Step 1: Replace the `// MARK: - IPC` block**

In `Calix/Views/MainWindow/CalixWindowController.swift`, replace the entire span from `private func enableIPC() {` (line 3766) through the closing brace of `hooksIssueMessages` (line 3895) with:

```swift
    private func enableIPC() {
        guard IPCAgent.allCases.contains(where: { AgentIPCSettings.isEnabled($0) }) else {
            showIPCAlert(
                title: "IPC Error",
                message: "All agents are disabled in Settings \u{2192} Agents. Enable at least one to turn on IPC."
            )
            return
        }
        do {
            // Generate token: 32 random bytes as hex
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                showIPCAlert(title: "IPC Error", message: "Failed to generate secure token.")
                return
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()

            // Start server first to get the port
            try CalixMCPServer.shared.start(token: token)
            let port = CalixMCPServer.shared.port

            // Write config to all available agent tools
            let result = IPCConfigManager.enableIPC(port: port, token: token)

            if !result.anySucceeded {
                CalixMCPServer.shared.stop()
                showIPCAlert(
                    title: "IPC Error",
                    message: "MCP server running on port \(port).\nNo agent configs found. Configure manually if needed."
                )
                return
            }

            // Install the calix-agent-hook script and wire each agent CLI's
            // own hook/plugin configuration to it so panes report lifecycle
            // state to the Agents sidebar. Same collect-independently shape
            // as IPCConfigManager.enableIPC above: an agent-hooks failure
            // degrades the sidebar rather than the whole "Enable AI Agent
            // IPC" flow, since the MCP server is already running.
            let hooksResult = AgentHooksCoordinator.install()

            // Persist any hook-install failure as a standing sidebar
            // banner (AgentStatusView) rather than a dialog -- a
            // symlink/permissions failure here otherwise degrades the
            // Agents sidebar silently for the rest of the session. `[]`
            // when every tool installed cleanly, clearing any banner left
            // over from a prior enable attempt. Hook issues never factor
            // into whether the alert below appears -- that's config-write
            // failures only.
            AgentRegistry.shared.setHooksIssues(Self.hooksIssueMessages(hooksResult))

            // Silent on full success -- a dialog naming nothing wrong adds
            // no information the user needs. Only surface the agents that
            // actually failed to configure.
            if !result.failedAgents.isEmpty {
                showIPCAlert(title: "IPC Setup Issue", message: failedAgentsMessage(result.failedAgents))
            }
        } catch {
            showIPCAlert(title: "IPC Error", message: error.localizedDescription)
        }
    }

    private func disableIPC() {
        CalixMCPServer.shared.stop()
        let result = IPCConfigManager.disableIPC()
        let hooksResult = AgentHooksCoordinator.remove()
        AgentRegistry.shared.setHooksIssues(Self.hooksIssueMessages(hooksResult))

        if !result.failedAgents.isEmpty {
            showIPCAlert(title: "IPC Teardown Issue", message: failedAgentsMessage(result.failedAgents))
        }
    }

    /// One `"<name>: error - <description>"` line per entry in `failures`
    /// (from `IPCConfigResult.failedAgents`), for the enable/disable
    /// summary alert. Only ever called with a non-empty array -- both
    /// call sites already gate on `!result.failedAgents.isEmpty`.
    private func failedAgentsMessage(_ failures: [(agent: IPCAgent, error: Error)]) -> String {
        failures
            .map { "\($0.agent.displayName): error - \($0.error.localizedDescription)" }
            .joined(separator: "\n")
    }

    /// One `"<name>: <localizedDescription>"` line per `.failed` tool in
    /// `result`, for `AgentRegistry.hooksIssues`'s persistent sidebar
    /// banner. `[]` when every tool installed/removed successfully (or was
    /// skipped) — `AgentStatusView` only renders the banner when this is
    /// non-empty.
    private static func hooksIssueMessages(_ result: AgentHooksResult) -> [String] {
        [
            ("Claude Code hooks", result.claudeCode),
            ("Codex hooks", result.codex),
            ("OpenCode plugin", result.openCode),
        ].compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }
```

This deletes `AgentHooksMode`, `configStatusLabel`, `configStatusMessage`, and `agentHooksStatusMessage` — after this change they have zero remaining callers anywhere in the file (verify with the grep in Step 2 below before moving on).

- [ ] **Step 2: Confirm no dangling references**

Run: `grep -n "AgentHooksMode\|configStatusLabel\|configStatusMessage\|agentHooksStatusMessage" Calix/Views/MainWindow/CalixWindowController.swift`
Expected: no output (the block replaced in Step 1 was their only appearance).

- [ ] **Step 3: Run the full build**

Run: `xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **` (this block has no dedicated unit tests of its own — `NSAlert.runModal()` can't run headless — so this is the regression check; manual verification follows).

- [ ] **Step 5: Manual verification**

Using the `run` skill (or launching the built app directly):
1. Ensure at least one agent (e.g. Claude Code) is enabled in Settings → Agents and actually installed.
2. Invoke "Enable AI Agent IPC" from the command palette.
3. Confirm **no dialog appears** when it succeeds (check `AgentStatusView` in the sidebar shows the running agents instead).
4. Force a failure: temporarily `chmod 000` the target agent's config directory (e.g. `~/.claude`), retry step 2, and confirm a dialog titled "IPC Setup Issue" appears naming exactly that agent with an error line. Restore permissions afterward (`chmod 755 ~/.claude`).

- [ ] **Step 6: Commit**

```bash
git add Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "fix: only show an IPC dialog when agent config setup actually fails"
```

---

### Task 3: `disableIPC()` gets sidebar visibility for hook-removal failures

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift` (already rewritten in Task 2 — this task is the manual-verification pass confirming the disable-side behavior, since both methods landed in one edit)

**Interfaces:**
- Consumes: `failedAgentsMessage(_:)`, `Self.hooksIssueMessages(_:)` (both from Task 2).

Task 2's Step 1 already included the new `disableIPC()` body (it replaced the whole `// MARK: - IPC` block in one edit, since `configStatusMessage`/`agentHooksStatusMessage` were shared between both methods and had to go in the same pass). This task is the dedicated verification that the disable path — including the previously-invisible hook-removal-failure case — actually works.

- [ ] **Step 1: Manual verification**

Using the `run` skill:
1. With IPC enabled and running cleanly (per Task 2's Step 5), invoke "Disable AI Agent IPC" from the command palette.
2. Confirm **no dialog appears** when every agent's config and hooks are removed cleanly.
3. Force a hook-removal failure: after re-enabling IPC, find whatever file `AgentHooksCoordinator.remove()` deletes for Claude Code (check `Calix/Features/AgentMonitor/AgentHooksCoordinator.swift`'s `remove()` implementation for the exact path — likely a hook script or a hooks-config JSON key) and make its parent directory temporarily unwritable (`chmod 000` on that directory). Invoke "Disable AI Agent IPC" again.
4. Confirm: still **no pop-up dialog** (hook failures are sidebar-only, not dialog, by design), but the Agents sidebar banner (`AgentStatusView`, the same banner `enableIPC()` already used for install failures) now shows the hook-removal error. This is the fix for the visibility gap called out in the design spec — previously this failure mode was only visible via the alert this task removed. Restore permissions afterward.

- [ ] **Step 2: Commit**

No code changes in this task — skip the commit if Task 2's commit already covers the combined `enableIPC`/`disableIPC` rewrite. If verification in Step 1 surfaces a bug, fix it here and commit:

```bash
git add Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "fix: <describe the disable-path bug found during manual verification>"
```

---

### Task 4: `IPCToggleTitlebarButtonView`

**Files:**
- Create: `Calix/Views/MainWindow/IPCToggleTitlebarButtonView.swift`
- Modify: `Calix/Helpers/AccessibilityID.swift:24-26`

**Interfaces:**
- Consumes: `AccessibilityID.Titlebar.ipcToggleButton` (added in this task).
- Produces: `IPCToggleTitlebarButtonView(isEnabled:onToggle:)` — consumed by Task 5's `TitlebarAccessoryView`.

- [ ] **Step 1: Add the accessibility identifier**

In `Calix/Helpers/AccessibilityID.swift`, change:

```swift
    enum Titlebar {
        static let gitChangesButton = "calix.titlebar.gitChangesButton"
    }
```

to:

```swift
    enum Titlebar {
        static let gitChangesButton = "calix.titlebar.gitChangesButton"
        static let ipcToggleButton = "calix.titlebar.ipcToggleButton"
    }
```

- [ ] **Step 2: Create the view file**

Create `Calix/Views/MainWindow/IPCToggleTitlebarButtonView.swift`:

```swift
// IPCToggleTitlebarButtonView.swift
// Calix
//
// The AI Agent IPC enable/disable toggle, hosted alongside
// GitChangesTitlebarButtonView inside the window's single titlebar
// accessory (see TitlebarAccessoryView). Always visible -- unlike the
// git-changes button, IPC is app-global state, not tied to the active
// tab's content. isEnabled tracks AgentRegistry.shared.isServerRunning,
// the @Observable-friendly proxy AgentStatusView already relies on
// (CalixMCPServer.isRunning itself isn't @Observable, so nothing
// redraws off it directly). See CalixWindowController's
// currentTitlebarAccessoryView() for what drives isEnabled, and
// toggleIPC() for what onToggle calls.

import SwiftUI

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

- [ ] **Step 3: Regenerate the Xcode project and build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (This view has no call site yet — Task 5 wires it in — so a successful build here just confirms the new file compiles standalone and was picked up by `xcodegen`'s directory glob.)

- [ ] **Step 4: Commit**

```bash
git add Calix/Views/MainWindow/IPCToggleTitlebarButtonView.swift Calix/Helpers/AccessibilityID.swift Calix.xcodeproj
git commit -m "feat: add IPCToggleTitlebarButtonView"
```

---

### Task 5: Combine both buttons into one titlebar accessory

**Files:**
- Create: `Calix/Views/MainWindow/TitlebarAccessoryView.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:32` (property), `:382` (init call site), `:620-640` (setup + builder methods), `:1074` (`refreshHostingView()`), `// MARK: - IPC` block (add `toggleIPC()`)

**Interfaces:**
- Consumes: `IPCToggleTitlebarButtonView` (Task 4), `GitChangesTitlebarButtonView` (existing), `AgentRegistry.shared.isServerRunning` (existing), `CalixMCPServer.shared.isRunning` (existing), `enableIPC()`/`disableIPC()` (Task 2/3 — unchanged signatures).
- Produces: `CalixWindowController.toggleIPC()`, `currentTitlebarAccessoryView()` — no other task depends on these.

- [ ] **Step 1: Create `TitlebarAccessoryView`**

Create `Calix/Views/MainWindow/TitlebarAccessoryView.swift`:

```swift
// TitlebarAccessoryView.swift
// Calix
//
// Combines IPCToggleTitlebarButtonView and GitChangesTitlebarButtonView
// into the window's one NSTitlebarAccessoryViewController (see
// CalixWindowController.setupTitlebarAccessory()). A second
// .right-attached accessory controller has no guaranteed ordering
// relative to this one, so both buttons share a single accessory's
// HStack instead. IPC comes first (left of the pair, i.e. closer to
// the window's center) since it's the more persistent global-state
// indicator; git-changes stays rightmost, matching where it already
// sat before this button was added alongside it.

import SwiftUI

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

- [ ] **Step 2: Rename the stored hosting-view property**

In `Calix/Views/MainWindow/CalixWindowController.swift:32`, change:

```swift
    private var gitChangesAccessoryHostingView: NSHostingView<GitChangesTitlebarButtonView>?
```

to:

```swift
    private var titlebarAccessoryHostingView: NSHostingView<TitlebarAccessoryView>?
```

- [ ] **Step 3: Rename the init call site**

At `CalixWindowController.swift:382`, change:

```swift
        setupGitChangesTitlebarAccessory()
```

to:

```swift
        setupTitlebarAccessory()
```

- [ ] **Step 4: Rewrite the setup and builder methods**

Replace the span from `private func setupGitChangesTitlebarAccessory() {` through the closing brace of `currentGitChangesButtonView()` (originally lines 620-640) with:

```swift
    private func setupTitlebarAccessory() {
        guard let window else { return }
        let hosting = NSHostingView(rootView: currentTitlebarAccessoryView())
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        self.titlebarAccessoryHostingView = hosting
    }

    private func currentTitlebarAccessoryView() -> TitlebarAccessoryView {
        let gitChangesVisible: Bool = {
            if case .terminal = windowSession.activeGroup?.activeTab?.content { return true }
            return false
        }()
        return TitlebarAccessoryView(
            ipcEnabled: AgentRegistry.shared.isServerRunning,
            onToggleIPC: { [weak self] in self?.toggleIPC() },
            gitChangesOpen: gitChangesController.isChangesPanelVisible,
            gitChangesVisible: gitChangesVisible,
            onToggleGitChanges: { [weak self] in self?.toggleGitChangesPanel() }
        )
    }
```

- [ ] **Step 5: Update `refreshHostingView()`**

At `CalixWindowController.swift:1074`, change:

```swift
        gitChangesAccessoryHostingView?.rootView = currentGitChangesButtonView()
```

to:

```swift
        titlebarAccessoryHostingView?.rootView = currentTitlebarAccessoryView()
```

- [ ] **Step 6: Add `toggleIPC()`**

In the `// MARK: - IPC` section, immediately before `private func enableIPC() {`, add:

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

- [ ] **Step 7: Confirm no dangling references to the old names**

Run: `grep -rn "gitChangesAccessoryHostingView\|setupGitChangesTitlebarAccessory\|currentGitChangesButtonView" Calix/`
Expected: no output.

- [ ] **Step 8: Regenerate the Xcode project and build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Manual verification**

Using the `run` skill:
1. Launch the app. Confirm two buttons now sit in the titlebar's trailing area: the IPC toggle (antenna icon) and the existing git-changes toggle, adjacent, IPC on the left of the pair.
2. With IPC off, confirm the antenna icon renders in `.primary` (not accent-colored).
3. Click it. Confirm `enableIPC()` runs (same effect as the command-palette entry — check `AgentStatusView` populates), and the icon turns accent-colored.
4. Click it again. Confirm `disableIPC()` runs and the icon returns to `.primary`.
5. Switch to a non-terminal tab and confirm the git-changes button still hides per its existing `isVisible` rule, while the IPC button stays visible regardless.

- [ ] **Step 10: Commit**

```bash
git add Calix/Views/MainWindow/TitlebarAccessoryView.swift Calix/Views/MainWindow/CalixWindowController.swift Calix.xcodeproj
git commit -m "feat: add a titlebar toggle button for AI Agent IPC enable/disable"
```

---

### Task 6: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Full test suite**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Re-run the manual verification checklists from Tasks 2, 3, and 5 in one sitting**

Confirms nothing regressed across tasks: silent success / named-failure dialogs on both enable and disable, sidebar banner catching both hook-install and hook-removal failures, and the new titlebar button driving the same code path as the command palette.
