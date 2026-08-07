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
    @MainActor
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
