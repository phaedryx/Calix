# Per-Agent IPC Checklist + cursor-agent Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose, per agent CLI, which ones participate in Calix's "Enable AI Agent IPC" action, and add `cursor-agent` as a fifth IPC-capable agent.

**Architecture:** A new `IPCAgent` enum (`claudeCode`/`codex`/`openCode`/`hermes`/`cursorAgent`) becomes the shared key for a new `AgentIPCSettings` preference store and for `IPCConfigManager`'s per-tool dispatch, replacing eight near-duplicate `enable<Tool>`/`disable<Tool>` private functions with two generic ones. `enableIPC()` skips agents disabled in Settings; `disableIPC()` never does (uncheck always cleans up, so a disabled agent's config can never orphan a dead-port entry). `cursor-agent` gets a new `CursorAgentConfigManager` modeled on `ClaudeConfigManager`, writing `~/.cursor/mcp.json`, deliberately omitting the `X-Calix-Surface-ID` header (unconfirmed interpolation support in cursor-agent's own config format) and the `type` field (not required for a remote/HTTP MCP server per Cursor's docs). Settings gets five new one-switch-per-agent rows in the existing Agents pane, following the codebase's established `controlRow(label:control:)` pattern exactly.

**Tech Stack:** Swift 6, AppKit (macOS native, no SwiftUI in Settings), XCTest (`CalixTests` target), `xcodebuild test` via CLI, `xcodegen` for project-file generation.

**Spec:** `docs/superpowers/specs/2026-08-06-per-agent-ipc-checklist-and-cursor-agent-design.md`

## Global Constraints

- Every task must leave the app building (`xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`) and `CalixTests` green before commit.
- **This project uses `xcodegen`**: `Calix.xcodeproj` is generated from `project.yml` and is entirely gitignored (`.gitignore:4`). Run `xcodegen generate` once before the first build in a fresh worktree, and again any time a `.swift` file is added or removed — the `Calix`/`CalixTests` targets use directory-glob `sources:` in `project.yml`, not an individually-listed file list, so a new file just needs `xcodegen generate` re-run. **No manual `project.pbxproj` editing**, despite what an isolated look at the `.pbxproj` format might suggest.
- **Truth table (from the spec — pin this exactly):** checkbox ON + server running → write now; checkbox ON + server stopped → persist preference only; checkbox OFF (either state) → always remove that agent's config; global "Enable AI Agent IPC" → writes only agents whose preference is `true`; global "Disable AI Agent IPC" → removes from all five regardless of preference (unchanged from today).
- Default every `AgentIPCSettings` preference to `true` — shipping this must not change behavior for an existing user until they actively uncheck something.
- `IPCConfigResult`, `AgentIPCSettings`, and `IPCConfigManager`'s dispatch functions all key off `IPCAgent.allCases` — a sixth agent added later should mean touching `IPCAgent`'s switch statements, not re-deriving a fifth hand-rolled `enable<Tool>()`/`disable<Tool>()` pair.
- `cursor-agent`'s config manager omits the `X-Calix-Surface-ID` header. Do not add it without first re-verifying cursor-agent's `${env:...}` interpolation supports an unset-variable default — see the spec's "Named limitation" note.

---

### Task 1: `IPCAgent` enum + `AgentIPCSettings` preference store

**Files:**
- Modify: `Calix/Features/IPC/IPCConfigManager.swift` (add `IPCAgent` enum only — no other changes yet)
- Modify: `Calix/Features/AgentMonitor/AgentToolPaths.swift` (add `cursorAgentConfigDirectory`)
- Create: `Calix/Features/IPC/AgentIPCSettings.swift`
- Test: `CalixTests/IPC/AgentIPCSettingsTests.swift`

**Interfaces:**
- Produces: `enum IPCAgent: String, CaseIterable, Sendable { case claudeCode, codex, openCode, hermes, cursorAgent }` with `.displayName: String` and `.configDirectory: String`. `AgentToolPaths.cursorAgentConfigDirectory: String`. `AgentIPCSettings.isEnabled(_ agent: IPCAgent) -> Bool`, `AgentIPCSettings.setEnabled(_ enabled: Bool, for agent: IPCAgent)`, `AgentIPCSettings._testUseSuite(named:)`, `AgentIPCSettings._testTeardownSuite(named:)`. Consumed by every later task.

- [ ] **Step 1: Write the failing test**

Create `CalixTests/IPC/AgentIPCSettingsTests.swift`:

```swift
//
//  AgentIPCSettingsTests.swift
//  CalixTests
//
//  TDD Red Phase for AgentIPCSettings: per-IPCAgent preference store
//  gating IPCConfigManager.enableIPC. Defaults true for every agent --
//  shipping this must not change behavior until the user unchecks
//  something.
//

import XCTest
@testable import Calix

final class AgentIPCSettingsTests: XCTestCase {

    private let suiteName = "com.calix.tests.AgentIPCSettingsTests"

    override func setUp() {
        super.setUp()
        AgentIPCSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        AgentIPCSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_isEnabled_defaultsTrueForEveryAgent_whenKeyNeverWritten() {
        for agent in IPCAgent.allCases {
            XCTAssertTrue(AgentIPCSettings.isEnabled(agent),
                         "\(agent) must default to enabled when its key has never been written")
        }
    }

    func test_setEnabled_falseThenTrue_roundTrips() {
        AgentIPCSettings.setEnabled(false, for: .codex)
        XCTAssertFalse(AgentIPCSettings.isEnabled(.codex))

        AgentIPCSettings.setEnabled(true, for: .codex)
        XCTAssertTrue(AgentIPCSettings.isEnabled(.codex))
    }

    func test_setEnabled_isIndependentPerAgent() {
        AgentIPCSettings.setEnabled(false, for: .hermes)

        XCTAssertFalse(AgentIPCSettings.isEnabled(.hermes))
        for agent in IPCAgent.allCases where agent != .hermes {
            XCTAssertTrue(AgentIPCSettings.isEnabled(agent),
                         "Disabling hermes must not affect \(agent)")
        }
    }

    func test_testStoreIsolation_neverTouchesStandardDefaults() {
        AgentIPCSettings.setEnabled(false, for: .claudeCode)

        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(rawSuite.bool(forKey: "calix.ipc.claudeCodeEnabled"),
                      "Setting must actually persist into the isolated test suite")

        let otherSuiteName = suiteName + ".other"
        AgentIPCSettings._testUseSuite(named: otherSuiteName)
        XCTAssertTrue(AgentIPCSettings.isEnabled(.claudeCode),
                     "A fresh isolated suite must read the default (true), not leak state from a previously-used suite")
        AgentIPCSettings._testTeardownSuite(named: otherSuiteName)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/AgentIPCSettingsTests`
Expected: FAIL to build — `Cannot find 'AgentIPCSettings' in scope` / `Cannot find type 'IPCAgent' in scope`.

- [ ] **Step 3: Add `IPCAgent` to `IPCConfigManager.swift`**

In `Calix/Features/IPC/IPCConfigManager.swift`, add immediately after the existing `enum ConfigStatus` block (before `IPCConfigResult`):

```swift
// MARK: - IPCAgent

/// One agent CLI Calix can register its `calix-ipc` MCP server with.
enum IPCAgent: String, CaseIterable, Sendable {
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

    /// This agent's on-disk config-root directory. A missing directory
    /// means the tool isn't installed, so IPCConfigManager skips it
    /// rather than creating a config file for a tool that doesn't exist.
    var configDirectory: String {
        switch self {
        case .claudeCode: return AgentToolPaths.claudeConfigDirectory
        case .codex: return AgentToolPaths.codexConfigDirectory
        case .openCode: return AgentToolPaths.openCodeConfigDirectory
        case .hermes: return NSHomeDirectory() + "/.hermes/"
        case .cursorAgent: return AgentToolPaths.cursorAgentConfigDirectory
        }
    }
}
```

- [ ] **Step 4: Add `cursorAgentConfigDirectory` to `AgentToolPaths.swift`**

In `Calix/Features/AgentMonitor/AgentToolPaths.swift`, add after `openCodeConfigDirectory`:

```swift
    /// cursor-agent's config root: `~/.cursor`.
    static var cursorAgentConfigDirectory: String {
        NSHomeDirectory() + "/.cursor"
    }
```

- [ ] **Step 5: Create `AgentIPCSettings.swift`**

Create `Calix/Features/IPC/AgentIPCSettings.swift`:

```swift
// AgentIPCSettings.swift
// Calix
//
// UserDefaults-backed store for which IPCAgents participate in "Enable
// AI Agent IPC". Same SettingsStore-backed pattern as CockpitSettings/
// CommandTrackingSettings. Defaults ON for every agent -- shipping this
// must not change behavior for an existing user until they actively
// uncheck something in Settings > Agents.
//
// Gates IPCConfigManager.enableIPC only. disableIPC always removes
// every agent's config regardless of this preference -- see that
// type's own header comment for the truth table and why (uncheck must
// always clean up, or a disabled agent's config could orphan a
// calix-ipc entry pointing at a dead port).

import Foundation

struct AgentIPCSettings: Sendable {

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    private static func key(for agent: IPCAgent) -> String {
        "calix.ipc.\(agent.rawValue)Enabled"
    }

    /// Documented default: `true` when the key has never been written --
    /// same `object(forKey:) == nil` absence check as
    /// CommandTrackingSettings.trackingEnabled.
    static func isEnabled(_ agent: IPCAgent) -> Bool {
        let key = key(for: agent)
        if store.object(forKey: key) == nil {
            return true
        }
        return store.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, for agent: IPCAgent) {
        store.set(enabled, forKey: key(for: agent))
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/AgentIPCSettingsTests`
Expected: all pass.

- [ ] **Step 7: Full build check**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **` (this task only adds new symbols, nothing existing changes behavior).

- [ ] **Step 8: Commit**

```bash
git add Calix/Features/IPC/IPCConfigManager.swift Calix/Features/AgentMonitor/AgentToolPaths.swift Calix/Features/IPC/AgentIPCSettings.swift CalixTests/IPC/AgentIPCSettingsTests.swift
git commit -m "feat: add IPCAgent enum and AgentIPCSettings preference store"
```

---

### Task 2: `CursorAgentConfigManager`

**Files:**
- Create: `Calix/Features/IPC/CursorAgentConfigManager.swift`
- Test: `CalixTests/IPC/CursorAgentConfigManagerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `CursorAgentConfigManager.enableIPC(port: Int, token: String, configPath: String? = nil) throws`, `.disableIPC(configPath: String? = nil) throws`, `.isIPCEnabled(configPath: String? = nil) -> Bool`. Consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Create `CalixTests/IPC/CursorAgentConfigManagerTests.swift`:

```swift
import XCTest
@testable import Calix

final class CursorAgentConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
        configPath = tempDir + "/mcp.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ content: String) {
        FileManager.default.createFile(
            atPath: configPath,
            contents: Data(content.utf8)
        )
    }

    private func readConfigDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // MARK: - enableIPC

    func test_enableIPC_createsConfigFromScratch() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        try CursorAgentConfigManager.enableIPC(port: 41830, token: "abc123", configPath: configPath)

        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers, "mcpServers key should exist")

        let calixIPC = mcpServers?["calix-ipc"] as? [String: Any]
        XCTAssertNotNil(calixIPC, "calix-ipc entry should exist")
        XCTAssertEqual(calixIPC?["url"] as? String, "http://127.0.0.1:41830/mcp")
        XCTAssertNil(calixIPC?["type"], "type must be omitted -- Cursor only requires it for stdio servers")

        let headers = calixIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123")
        XCTAssertEqual(headers?.count, 1,
                       "headers must contain only Authorization -- X-Calix-Surface-ID is deliberately omitted " +
                       "(unconfirmed whether cursor-agent's ${env:...} interpolation supports an unset-variable default)")
    }

    func test_enableIPC_addsToExistingConfig() throws {
        let existingJSON = """
        {
            "mcpServers": {
                "other-server": {
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeConfig(existingJSON)

        try CursorAgentConfigManager.enableIPC(port: 41830, token: "tok1", configPath: configPath)

        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers?["calix-ipc"], "calix-ipc should be added")
        XCTAssertNotNil(mcpServers?["other-server"], "other-server should be preserved")
    }

    func test_enableIPC_updatesExistingEntry() throws {
        let existingJSON = """
        {
            "mcpServers": {
                "calix-ipc": {
                    "url": "http://localhost:40000/mcp",
                    "headers": { "Authorization": "Bearer old-token" }
                }
            }
        }
        """
        writeConfig(existingJSON)

        try CursorAgentConfigManager.enableIPC(port: 55555, token: "new-token", configPath: configPath)

        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calixIPC = mcpServers?["calix-ipc"] as? [String: Any]
        XCTAssertEqual(calixIPC?["url"] as? String, "http://127.0.0.1:55555/mcp")
        let headers = calixIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer new-token")
    }

    func test_enableIPC_invalidJSON_throws() {
        writeConfig("this is not json {{{")

        XCTAssertThrowsError(
            try CursorAgentConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { _ in
            let content = try? String(contentsOfFile: self.configPath, encoding: .utf8)
            XCTAssertEqual(content, "this is not json {{{",
                           "Invalid JSON file should not be overwritten")
        }
    }

    func test_enableIPC_createsBackup() throws {
        writeConfig("{ \"mcpServers\": {} }")

        try CursorAgentConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath))
        let bakContent = try String(contentsOfFile: bakPath, encoding: .utf8)
        XCTAssertFalse(bakContent.contains("calix-ipc"))
    }

    func test_enableIPC_preservesOtherKeys() throws {
        let existingJSON = """
        {
            "someOtherKey": "value",
            "mcpServers": {}
        }
        """
        writeConfig(existingJSON)

        try CursorAgentConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertEqual(dict["someOtherKey"] as? String, "value")
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers?["calix-ipc"])
    }

    // MARK: - disableIPC

    func test_disableIPC_removesCalixEntry() throws {
        let existingJSON = """
        {
            "mcpServers": {
                "calix-ipc": { "url": "http://localhost:41830/mcp", "headers": { "Authorization": "Bearer tok" } },
                "other-server": { "url": "http://localhost:9999/mcp" }
            }
        }
        """
        writeConfig(existingJSON)

        try CursorAgentConfigManager.disableIPC(configPath: configPath)

        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNil(mcpServers?["calix-ipc"])
        XCTAssertNotNil(mcpServers?["other-server"])
    }

    func test_disableIPC_removesMcpServersIfEmpty() throws {
        let existingJSON = """
        {
            "mcpServers": {
                "calix-ipc": { "url": "http://localhost:41830/mcp", "headers": { "Authorization": "Bearer tok" } }
            },
            "otherKey": "value"
        }
        """
        writeConfig(existingJSON)

        try CursorAgentConfigManager.disableIPC(configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertNil(dict["mcpServers"])
        XCTAssertEqual(dict["otherKey"] as? String, "value")
    }

    func test_disableIPC_noConfigFile() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
        XCTAssertNoThrow(try CursorAgentConfigManager.disableIPC(configPath: configPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueWhenPresent() {
        writeConfig("""
        { "mcpServers": { "calix-ipc": { "url": "http://localhost:41830/mcp" } } }
        """)
        XCTAssertTrue(CursorAgentConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseWhenAbsent() {
        writeConfig("""
        { "mcpServers": { "other-server": { "url": "http://localhost:9999/mcp" } } }
        """)
        XCTAssertFalse(CursorAgentConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseWhenNoFile() {
        XCTAssertFalse(CursorAgentConfigManager.isIPCEnabled(configPath: configPath))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/CursorAgentConfigManagerTests`
Expected: FAIL to build — `Cannot find 'CursorAgentConfigManager' in scope`.

- [ ] **Step 3: Create `CursorAgentConfigManager.swift`**

Create `Calix/Features/IPC/CursorAgentConfigManager.swift`:

```swift
// CursorAgentConfigManager.swift
// Calix
//
// Manages reading/writing ~/.cursor/mcp.json for the Calix IPC MCP
// server. Modeled on ClaudeConfigManager, with two deliberate
// deviations confirmed against Cursor's own docs (cursor.com/docs/mcp,
// cursor.com/docs/cli/mcp):
//
// - No "type" field: Cursor requires "type" only for stdio servers: a
//   bare "url" is enough for a remote/HTTP one.
// - No X-Calix-Surface-ID header: Claude's entry sends the
//   `${CALIX_SURFACE_ID:-}` bash-style empty-default placeholder.
//   cursor-agent's own interpolation syntax is `${env:VAR}`, and
//   whether it supports a default-on-unset form is unconfirmed --
//   guessing wrong risks breaking cursor-agent's config parse
//   entirely, the same failure mode ClaudeConfigManager's own comment
//   warns about. CalixMCPServer already treats a missing
//   X-Calix-Surface-ID header identically to an empty one (both mean
//   "no binding for this connection" -- see parseSurfaceID), so
//   omitting it here is safe server-side. Known limitation: cursor-agent
//   panes get no automatic surface -> peer binding.

import Foundation

struct CursorAgentConfigManager: Sendable {

    private static let mcpServersKey = "mcpServers"
    private static let calixIPCKey = "calix-ipc"

    // MARK: - Public API

    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        var mcpServers = config[mcpServersKey] as? [String: Any] ?? [:]

        let calixEntry: [String: Any] = [
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)"
            ]
        ]
        mcpServers[calixIPCKey] = calixEntry
        config[mcpServersKey] = mcpServers

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        guard var mcpServers = config[mcpServersKey] as? [String: Any] else {
            return
        }

        mcpServers.removeValue(forKey: calixIPCKey)

        if mcpServers.isEmpty {
            config.removeValue(forKey: mcpServersKey)
        } else {
            config[mcpServersKey] = mcpServers
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    /// Returns `false` (rather than throwing) when `configPath`'s symlink
    /// chain can't be resolved -- this is a read-only status check, same
    /// contract as ClaudeConfigManager.isIPCEnabled.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return false }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let config = parsed as? [String: Any],
              let mcpServers = config[mcpServersKey] as? [String: Any] else {
            return false
        }

        return mcpServers[calixIPCKey] != nil
    }

    // MARK: - Private

    private static var defaultConfigPath: String {
        NSHomeDirectory() + "/.cursor/mcp.json"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/CursorAgentConfigManagerTests`
Expected: all pass.

- [ ] **Step 5: Full build check**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Calix/Features/IPC/CursorAgentConfigManager.swift CalixTests/IPC/CursorAgentConfigManagerTests.swift
git commit -m "feat: add CursorAgentConfigManager for cursor-agent IPC registration"
```

---

### Task 3: Wire `cursorAgent` + preference gating into `IPCConfigManager`

**Files:**
- Modify: `Calix/Features/IPC/IPCConfigManager.swift`
- Modify: `CalixTests/IPC/IPCConfigManagerTests.swift`
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:3836-3843` (`configStatusMessage`), `:3878-3884` (`isAIAgentTitle`'s comment)

**Interfaces:**
- Consumes: `IPCAgent` (Task 1), `AgentIPCSettings.isEnabled`/`setEnabled` (Task 1), `CursorAgentConfigManager` (Task 2), `CalixMCPServer.shared.{isRunning,port,token}` (existing).
- Produces: `IPCConfigResult.cursorAgent: ConfigStatus` (new field — every existing call site constructing `IPCConfigResult` directly must add this parameter). `IPCConfigManager.setAgentEnabled(_ agent: IPCAgent, enabled: Bool) -> ConfigStatus?` — new public API consumed by Task 5's Settings UI.

This task rewrites `IPCConfigManager.swift`'s `enableIPC`/`disableIPC`/`isIPCEnabled` plus the eight private per-tool functions into a generic per-`IPCAgent` dispatch, and applies the preference-gating truth table. Because `IPCConfigResult` gains a required field, every existing test constructing it directly will fail to compile until updated — that's this task's RED phase.

- [ ] **Step 1: Update existing construction sites to fail (RED)**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/IPCConfigManagerTests` *before* touching any file.
Expected (baseline, to confirm current green state before the RED step below): all pass.

Now add the write step immediately below and re-run to see RED.

- [ ] **Step 2: Replace `IPCConfigManager.swift`'s body**

Replace the full contents of `Calix/Features/IPC/IPCConfigManager.swift` (keep the `IPCAgent` enum added in Task 1 as-is) with:

```swift
// IPCConfigManager.swift
// Calix
//
// Coordinates IPC config registration across every IPCAgent, collecting
// results independently so one agent failing does not block the
// others. enableIPC() is gated per-agent by AgentIPCSettings; disableIPC()
// is not -- unchecking an agent in Settings always removes its config
// immediately (see AgentIPCSettings and SettingsWindowController's
// per-agent switch handlers), so a disabled agent's on-disk entry can
// never point at a stale port. See the design spec's truth table:
// docs/superpowers/specs/2026-08-06-per-agent-ipc-checklist-and-cursor-agent-design.md

import Foundation

// MARK: - ConfigStatus

enum ConfigStatus: Sendable {
    case success
    case skipped(reason: String)
    case failed(Error)
}

// MARK: - IPCAgent

/// One agent CLI Calix can register its `calix-ipc` MCP server with.
enum IPCAgent: String, CaseIterable, Sendable {
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

    /// This agent's on-disk config-root directory. A missing directory
    /// means the tool isn't installed, so IPCConfigManager skips it
    /// rather than creating a config file for a tool that doesn't exist.
    var configDirectory: String {
        switch self {
        case .claudeCode: return AgentToolPaths.claudeConfigDirectory
        case .codex: return AgentToolPaths.codexConfigDirectory
        case .openCode: return AgentToolPaths.openCodeConfigDirectory
        case .hermes: return NSHomeDirectory() + "/.hermes/"
        case .cursorAgent: return AgentToolPaths.cursorAgentConfigDirectory
        }
    }
}

// MARK: - IPCConfigResult

struct IPCConfigResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus
    let hermes: ConfigStatus
    let cursorAgent: ConfigStatus

    var anySucceeded: Bool {
        if case .success = claudeCode { return true }
        if case .success = codex { return true }
        if case .success = openCode { return true }
        if case .success = hermes { return true }
        if case .success = cursorAgent { return true }
        return false
    }
}

// MARK: - IPCConfigManager

struct IPCConfigManager: Sendable {

    // MARK: - Public API

    /// Enables IPC MCP server config in every IPCAgent whose
    /// AgentIPCSettings preference is `true`. An agent whose preference
    /// is `false` is reported `.skipped(reason: "disabled in settings")`
    /// without touching its config file at all. Each agent is handled
    /// independently -- one failing does not prevent the others.
    static func enableIPC(port: Int, token: String) -> IPCConfigResult {
        IPCConfigResult(
            claudeCode: enableIfPreferred(.claudeCode, port: port, token: token),
            codex: enableIfPreferred(.codex, port: port, token: token),
            openCode: enableIfPreferred(.openCode, port: port, token: token),
            hermes: enableIfPreferred(.hermes, port: port, token: token),
            cursorAgent: enableIfPreferred(.cursorAgent, port: port, token: token)
        )
    }

    /// Disables IPC MCP server config in every IPCAgent, regardless of
    /// AgentIPCSettings. Does not check directory existence -- the
    /// individual managers handle missing files as no-ops.
    static func disableIPC() -> IPCConfigResult {
        IPCConfigResult(
            claudeCode: disableAgent(.claudeCode),
            codex: disableAgent(.codex),
            openCode: disableAgent(.openCode),
            hermes: disableAgent(.hermes),
            cursorAgent: disableAgent(.cursorAgent)
        )
    }

    /// Returns whether IPC is currently enabled in each tool's config.
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool, cursorAgent: Bool) {
        (
            claudeCode: isAgentIPCEnabled(.claudeCode),
            codex: isAgentIPCEnabled(.codex),
            openCode: isAgentIPCEnabled(.openCode),
            hermes: isAgentIPCEnabled(.hermes),
            cursorAgent: isAgentIPCEnabled(.cursorAgent)
        )
    }

    /// Live single-agent write/remove for a Settings checkbox flipped
    /// while the master IPC server is already running. Returns `nil`
    /// when the server isn't running -- there is nothing to write yet,
    /// since the AgentIPCSettings preference alone is enough until the
    /// next "Enable AI Agent IPC". `enabled: false` always removes the
    /// agent's config (same truth table as disableIPC) -- it is never
    /// gated on the preference, since the preference is what's changing.
    static func setAgentEnabled(_ agent: IPCAgent, enabled: Bool) -> ConfigStatus? {
        guard CalixMCPServer.shared.isRunning else { return nil }
        return enabled
            ? enableAgent(agent, port: CalixMCPServer.shared.port, token: CalixMCPServer.shared.token)
            : disableAgent(agent)
    }

    // MARK: - Private

    private static func enableIfPreferred(_ agent: IPCAgent, port: Int, token: String) -> ConfigStatus {
        guard AgentIPCSettings.isEnabled(agent) else {
            return .skipped(reason: "disabled in settings")
        }
        return enableAgent(agent, port: port, token: token)
    }

    private static func enableAgent(_ agent: IPCAgent, port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: agent.configDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try enableIPCConfig(for: agent, port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableAgent(_ agent: IPCAgent) -> ConfigStatus {
        do {
            try disableIPCConfig(for: agent)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func isAgentIPCEnabled(_ agent: IPCAgent) -> Bool {
        switch agent {
        case .claudeCode: return ClaudeConfigManager.isIPCEnabled()
        case .codex: return CodexConfigManager.isIPCEnabled()
        case .openCode: return OpenCodeConfigManager.isIPCEnabled()
        case .hermes: return HermesConfigManager.isIPCEnabled()
        case .cursorAgent: return CursorAgentConfigManager.isIPCEnabled()
        }
    }

    private static func enableIPCConfig(for agent: IPCAgent, port: Int, token: String) throws {
        switch agent {
        case .claudeCode: try ClaudeConfigManager.enableIPC(port: port, token: token)
        case .codex: try CodexConfigManager.enableIPC(port: port, token: token)
        case .openCode: try OpenCodeConfigManager.enableIPC(port: port, token: token)
        case .hermes: try HermesConfigManager.enableIPC(port: port, token: token)
        case .cursorAgent: try CursorAgentConfigManager.enableIPC(port: port, token: token)
        }
    }

    private static func disableIPCConfig(for agent: IPCAgent) throws {
        switch agent {
        case .claudeCode: try ClaudeConfigManager.disableIPC()
        case .codex: try CodexConfigManager.disableIPC()
        case .openCode: try OpenCodeConfigManager.disableIPC()
        case .hermes: try HermesConfigManager.disableIPC()
        case .cursorAgent: try CursorAgentConfigManager.disableIPC()
        }
    }
}
```

- [ ] **Step 3: Update `IPCConfigManagerTests.swift`**

Every existing `IPCConfigResult(claudeCode:, codex:, openCode:, hermes:)` literal in `CalixTests/IPC/IPCConfigManagerTests.swift` now fails to compile — add `cursorAgent: .skipped(reason: "not installed")` as the trailing argument to every one of the 8 existing constructions in that file (the ones building `test_anySucceeded_*`). Then add three new tests mirroring the existing `openCode`/`hermes` axis tests, appended at the end of the `// MARK: - IPCConfigResult.anySucceeded (hermes axis)` section:

```swift
    // MARK: - IPCConfigResult.anySucceeded (cursorAgent axis)

    func test_anySucceeded_onlyCursorAgent() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .success
        )
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when only cursorAgent succeeded")
    }

    func test_anySucceeded_cursorAgentFailedOthersSkipped() {
        let error = NSError(domain: "test", code: 6)
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            cursorAgent: .failed(error)
        )
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when cursorAgent failed and others skipped")
    }

    func test_anySucceeded_cursorAgentSuccessOthersFailed() {
        let error = NSError(domain: "test", code: 7)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            cursorAgent: .success
        )
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when cursorAgent succeeded despite other failures")
    }
```

Also add a new `// MARK: - Preference gating` section at the end of the file, before the closing brace:

```swift
    // MARK: - Preference gating (enableIPC respects AgentIPCSettings, disableIPC does not)

    private let prefsSuiteName = "com.calix.tests.IPCConfigManagerTests.prefs"

    func test_enableIPC_skipsAgentDisabledInSettings() {
        AgentIPCSettings._testUseSuite(named: prefsSuiteName)
        defer { AgentIPCSettings._testTeardownSuite(named: prefsSuiteName) }

        AgentIPCSettings.setEnabled(false, for: .codex)

        let result = IPCConfigManager.enableIPC(port: 1, token: "t")

        guard case .skipped(let reason) = result.codex else {
            XCTFail("Expected codex to be skipped when disabled in settings, got \(result.codex)")
            return
        }
        XCTAssertEqual(reason, "disabled in settings")
    }

    func test_setAgentEnabled_returnsNilWhenServerNotRunning() {
        XCTAssertFalse(CalixMCPServer.shared.isRunning,
                       "Precondition: this test assumes no other test left the shared MCP server running")
        XCTAssertNil(IPCConfigManager.setAgentEnabled(.claudeCode, enabled: true))
    }
```

- [ ] **Step 4: Update `CalixWindowController.configStatusMessage`**

In `Calix/Views/MainWindow/CalixWindowController.swift`, replace:

```swift
    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        [
            configStatusLabel(result.claudeCode, name: "Claude Code", verb: "configured"),
            configStatusLabel(result.codex, name: "Codex", verb: "configured"),
            configStatusLabel(result.openCode, name: "OpenCode", verb: "configured"),
            configStatusLabel(result.hermes, name: "Hermes", verb: "configured"),
        ].joined(separator: "\n")
    }
```

with:

```swift
    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        [
            configStatusLabel(result.claudeCode, name: "Claude Code", verb: "configured"),
            configStatusLabel(result.codex, name: "Codex", verb: "configured"),
            configStatusLabel(result.openCode, name: "OpenCode", verb: "configured"),
            configStatusLabel(result.hermes, name: "Hermes", verb: "configured"),
            configStatusLabel(result.cursorAgent, name: "Cursor Agent", verb: "configured"),
        ].joined(separator: "\n")
    }
```

- [ ] **Step 5: Update `isAIAgentTitle`'s comment**

In the same file, replace the comment above `isAIAgentTitle` (currently reading `/// Keep the agent list in sync with \`IPCConfigResult\` axes.`) with:

```swift
    /// cursor-agent is deliberately excluded here: this pass's cursor-agent
    /// support is config-registration only (see IPCConfigResult.cursorAgent),
    /// with no hooks/sidebar tracking, so there is no title-based detection
    /// need for it yet. Keep the remaining agent list in sync with
    /// IPCConfigResult's other four axes.
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/IPCConfigManagerTests`
Expected: all pass, including the 5 new tests.

- [ ] **Step 7: Full build check**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Manual verification (required — not covered by the unit tests above)**

The unit tests above prove the JSON round-trips correctly; they do not prove cursor-agent can actually use the entry. With `cursor-agent` installed:
1. Run the app, invoke "Enable AI Agent IPC" from the command palette.
2. Run `cursor-agent mcp list` in a terminal.
3. Confirm `calix-ipc` appears in the list and shows as connected (not errored).

If it fails to connect, do not proceed to Task 5 until diagnosed — this determines whether the omitted headers/type field assumption in Task 2 was correct.

- [ ] **Step 9: Commit**

```bash
git add Calix/Features/IPC/IPCConfigManager.swift CalixTests/IPC/IPCConfigManagerTests.swift Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "feat: wire cursorAgent into IPCConfigManager, gate enableIPC on AgentIPCSettings"
```

---

### Task 4: All-agents-disabled short-circuit in `CalixWindowController.enableIPC()`

**Files:**
- Modify: `Calix/Views/MainWindow/CalixWindowController.swift:3747-3798` (`enableIPC()`)
- Test: manual (no automated UI test harness covers `NSAlert` content in this codebase's unit-test target — see Step 3)

**Interfaces:**
- Consumes: `IPCAgent.allCases`, `AgentIPCSettings.isEnabled` (Task 1).

If every `IPCAgent` preference is `false`, today's `enableIPC()` would start `CalixMCPServer`, get an all-`.skipped` `IPCConfigResult`, hit the existing `!result.anySucceeded` branch, and show a misleading "No agent configs found. Configure manually if needed." This task adds an earlier, more specific check.

- [ ] **Step 1: Modify `enableIPC()`**

In `Calix/Views/MainWindow/CalixWindowController.swift`, at the very top of `private func enableIPC()` (before the `do {` block), add:

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
```

(Leave the rest of the existing method body — the `do { ... }` block generating the token, starting the server, calling `IPCConfigManager.enableIPC`, etc. — unchanged below this new guard.)

- [ ] **Step 2: Run the full build**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification**

Using the `run` skill (or launching the built app directly):
1. Open Settings → Agents, uncheck all 5 IPC agent switches (added in Task 5 — if Task 5 isn't done yet, temporarily call `AgentIPCSettings.setEnabled(false, for: agent)` for all `IPCAgent.allCases` from a debug breakpoint or a throwaway call, then revert).
2. Invoke "Enable AI Agent IPC" from the command palette.
3. Confirm the alert reads "All agents are disabled in Settings → Agents..." and that `CalixMCPServer.shared.isRunning` is still `false` afterward (no server was started).

- [ ] **Step 4: Commit**

```bash
git add Calix/Views/MainWindow/CalixWindowController.swift
git commit -m "fix: short-circuit Enable AI Agent IPC with a clear message when every agent is disabled"
```

---

### Task 5: Settings UI checklist

**Files:**
- Modify: `Calix/Features/Settings/SettingsRow.swift`
- Modify: `Calix/Features/Settings/SettingsWindowController.swift`
- Modify: `Calix/Helpers/AccessibilityID.swift`
- Modify: `CalixTests/Features/Settings/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: `IPCAgent.allCases`/`.displayName`/`.configDirectory` (Task 1), `AgentIPCSettings.isEnabled`/`.setEnabled` (Task 1), `IPCConfigManager.setAgentEnabled` (Task 3), `ConfigFileUtils.directoryExists` (existing), `CalixMCPServer.shared.isRunning` (existing).

- [ ] **Step 1: Write the failing test**

In `CalixTests/Features/Settings/SettingsPaneTests.swift`, extend `expectedRows` (add these 5 entries immediately after the `("agentHookApproval", .agents)` line, since the new rows land right after it in `SettingsRow`'s declared order):

```swift
        ("agentHookApproval", .agents),
        ("ipcClaudeCode", .agents),
        ("ipcCodex", .agents),
        ("ipcOpenCode", .agents),
        ("ipcHermes", .agents),
        ("ipcCursorAgent", .agents),
        ("openSessionBrowserButton", .sessions),
```

(Only the five new lines are additions; `("agentHookApproval", .agents)` and `("openSessionBrowserButton", .sessions)` already exist — replace that two-line span with the seven-line span above.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/SettingsPaneTests`
Expected: FAIL — `SettingsRow is missing a case for 'ipcClaudeCode'` (and similarly for the other 4), plus the case-count assertion failing.

- [ ] **Step 3: Add the 5 cases to `SettingsRow.swift`**

In `Calix/Features/Settings/SettingsRow.swift`, add the 5 new cases to the `enum SettingsRow` declaration right after `agentHookApproval`:

```swift
    case agentHookApproval
    case ipcClaudeCode
    case ipcCodex
    case ipcOpenCode
    case ipcHermes
    case ipcCursorAgent
    case openSessionBrowserButton
```

And add them to the `.agents` case of the `pane` switch:

```swift
        case .agentResume, .agentResumeAutoExecute, .cockpitAutoApprove, .commandTracking, .agentHookApproval,
             .ipcClaudeCode, .ipcCodex, .ipcOpenCode, .ipcHermes, .ipcCursorAgent:
            return .agents
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests/SettingsPaneTests`
Expected: all pass.

- [ ] **Step 5: Add AccessibilityID identifiers**

In `Calix/Helpers/AccessibilityID.swift`, add to `enum Settings` after `agentHookApprovalSwitch`:

```swift
        static let ipcClaudeCodeSwitch = "calix.settings.agents.ipcClaudeCodeSwitch"
        static let ipcCodexSwitch = "calix.settings.agents.ipcCodexSwitch"
        static let ipcOpenCodeSwitch = "calix.settings.agents.ipcOpenCodeSwitch"
        static let ipcHermesSwitch = "calix.settings.agents.ipcHermesSwitch"
        static let ipcCursorAgentSwitch = "calix.settings.agents.ipcCursorAgentSwitch"
```

- [ ] **Step 6: Wire the section heading**

In `Calix/Features/Settings/SettingsWindowController.swift`, in `sectionHeading(for:)`, add a case for `.ipcClaudeCode` (the first of the five, so it carries the heading) right after the existing `.agentHookApproval` case:

```swift
        case .agentHookApproval:
            return SectionHeading(
                title: "Agent Hook Approval",
                subtitle: "Routes CLI agents' (Claude Code, Codex) tool-permission prompts to the Calix approval banner. Off = agents prompt in their own pane, as before."
            )
        case .ipcClaudeCode:
            return SectionHeading(
                title: "IPC-Enabled Agents",
                subtitle: "Choose which agent tools get the Calix IPC MCP server when you enable IPC. A grayed-out switch means that tool isn't installed."
            )
```

And add the other 4 new cases to the existing `return nil` case list at the bottom of that switch:

```swift
        case .themeColorWell, .themeColorHex, .lspRequireConfirmation,
             .historyPersistence, .agentResumeAutoExecute,
             .openSessionBrowserButton, .ipcCodex, .ipcOpenCode, .ipcHermes, .ipcCursorAgent:
            return nil
```

- [ ] **Step 7: Wire `contentView(for:)`**

In the same file, add to `contentView(for settingsRow: SettingsRow) -> NSView`'s switch, right after the `.agentHookApproval` case:

```swift
        case .agentHookApproval:
            return agentHookApprovalRow()
        case .ipcClaudeCode:
            return ipcAgentRow(.claudeCode, accessibilityID: AccessibilityID.Settings.ipcClaudeCodeSwitch)
        case .ipcCodex:
            return ipcAgentRow(.codex, accessibilityID: AccessibilityID.Settings.ipcCodexSwitch)
        case .ipcOpenCode:
            return ipcAgentRow(.openCode, accessibilityID: AccessibilityID.Settings.ipcOpenCodeSwitch)
        case .ipcHermes:
            return ipcAgentRow(.hermes, accessibilityID: AccessibilityID.Settings.ipcHermesSwitch)
        case .ipcCursorAgent:
            return ipcAgentRow(.cursorAgent, accessibilityID: AccessibilityID.Settings.ipcCursorAgentSwitch)
```

- [ ] **Step 8: Add `ipcAgentRow` and its action handler**

In the same file, add a new row-builder function right after `agentHookApprovalRow()`:

```swift
    /// Builds one IPC-agent checklist row. The switch reflects the
    /// AgentIPCSettings *preference*, not live server status -- toggling
    /// it ON while CalixMCPServer isn't running only persists the
    /// preference (nothing to write yet); toggling it OFF always removes
    /// that agent's config immediately via IPCConfigManager.setAgentEnabled,
    /// regardless of server state, so a disabled agent's config can never
    /// be left pointing at a stale port. An agent whose config directory
    /// doesn't exist is shown disabled with "(not installed)" appended,
    /// since there is nothing meaningful to toggle for a tool that isn't
    /// on this machine.
    private func ipcAgentRow(_ agent: IPCAgent, accessibilityID: String) -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(accessibilityID)
        toggleSwitch.state = AgentIPCSettings.isEnabled(agent) ? .on : .off

        let isInstalled = ConfigFileUtils.directoryExists(at: agent.configDirectory)
        toggleSwitch.isEnabled = isInstalled

        toggleSwitch.target = self
        toggleSwitch.action = #selector(ipcAgentSwitchDidChange(_:))
        toggleSwitch.tag = IPCAgent.allCases.firstIndex(of: agent) ?? 0

        let label = isInstalled ? agent.displayName : "\(agent.displayName) (not installed)"
        return controlRow(label: label, control: toggleSwitch)
    }

    @objc private func ipcAgentSwitchDidChange(_ sender: NSSwitch) {
        guard IPCAgent.allCases.indices.contains(sender.tag) else { return }
        let agent = IPCAgent.allCases[sender.tag]
        let enabled = sender.state == .on

        AgentIPCSettings.setEnabled(enabled, for: agent)

        if let liveStatus = IPCConfigManager.setAgentEnabled(agent, enabled: enabled),
           case .failed(let error) = liveStatus {
            showIPCAlert(title: "IPC Error", message: "\(agent.displayName): \(error.localizedDescription)")
        }
    }
```

`IPCAgent.allCases.firstIndex(of:)` relies on `IPCAgent`'s declaration order (`claudeCode, codex, openCode, hermes, cursorAgent`) matching the 5 `ipcAgentRow` call sites' order in Step 7 above — both already match.

`showIPCAlert` is `private` on `CalixWindowController`; this new method is added to that same type, so it's directly callable.

- [ ] **Step 9: Run the full build and test suite**

Run: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests`
Expected: `** TEST SUCCEEDED **`, full suite green.

- [ ] **Step 10: Manual verification**

Using the `run` skill:
1. Open Settings → Agents. Confirm a new "IPC-Enabled Agents" section appears after "Agent Hook Approval" with 5 switches, all ON by default.
2. Uncheck one (e.g. Codex). If Codex has a `~/.codex` directory and IPC is already enabled, confirm its `calix-ipc` entry disappears from `~/.codex/config.toml` immediately.
3. Re-check it while IPC is running; confirm the entry reappears.
4. Uncheck it again, then invoke "Enable AI Agent IPC" from the command palette (after first disabling IPC via the palette, to test the global path) — confirm Codex is skipped ("Codex: disabled in settings (skipped)" in the resulting alert) while the other four still configure.

- [ ] **Step 11: Commit**

```bash
git add Calix/Features/Settings/SettingsRow.swift Calix/Features/Settings/SettingsWindowController.swift Calix/Helpers/AccessibilityID.swift CalixTests/Features/Settings/SettingsPaneTests.swift
git commit -m "feat: add per-agent IPC checklist to Settings > Agents"
```

---

## Final verification

- [ ] Full build: `xcodegen generate && xcodebuild -project Calix.xcodeproj -scheme Calix -configuration Debug build` → `** BUILD SUCCEEDED **`.
- [ ] Full test suite: `xcodebuild test -project Calix.xcodeproj -scheme Calix -destination 'platform=macOS' -only-testing:CalixTests` → `** TEST SUCCEEDED **`.
- [ ] `cursor-agent mcp list` (Task 3, Step 8) confirms `calix-ipc` connects for a real cursor-agent installation.
- [ ] Manual pass through Task 4 Step 3 and Task 5 Step 10 together in one session: uncheck all 5, confirm the all-disabled alert; re-check all 5, confirm "Enable AI Agent IPC" configures every installed tool exactly as it did before this plan.
