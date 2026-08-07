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
