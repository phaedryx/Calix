// AgentHookScript.swift
// Calix
//
// The `calix-agent-hook` shell script installed under
// `~/Library/Application Support/Calix/bin/`. Forwards a Claude Code hook's
// stdin JSON to the local Calix IPC server's /agent-event endpoint.

import Foundation

enum AgentHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` to
    /// recognize its own `command` entries by path.
    static let fileName = "calix-agent-hook"

    /// Default install directory: `~/Library/Application Support/Calix/bin`.
    static var defaultInstallDirectory: String {
        (AgentEndpointFile.defaultDirectory as NSString).appendingPathComponent("bin")
    }

    /// Both `CALIX_SURFACE_ID` and `CALIX_SESSION_ID` unset means this
    /// pane wasn't launched by Calix at all (e.g. a plain Terminal.app
    /// tab running `claude`) — exit immediately so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token. Every exit path is `exit 0`: a failed or unreachable
    /// POST must never break the user's hook chain.
    ///
    /// `$1` is the agent kind, forwarded as the `X-Calix-Agent-Kind`
    /// header so the server can attribute the event to the right CLI.
    /// Defaulting to `claude-code` when `$1` is unset keeps this script
    /// compatible with Claude Code's own hook `command` entries (installed
    /// by `ClaudeHooksConfigManager`), which invoke it with no arguments;
    /// `CodexHooksConfigManager` installs Codex's entries as
    /// `"<scriptPath>" codex` to pass `codex` explicitly.
    ///
    /// The `X-Calix-Surface-ID` header value itself is
    /// `${CALIX_SESSION_ID:-$CALIX_SURFACE_ID}`: a persistent-session
    /// pane's calix-session ID survives ghostty surface re-creation
    /// (reconnect) while `CALIX_SURFACE_ID` does not, so `CALIX_SESSION_ID`
    /// is preferred whenever set, falling back to the ordinary
    /// `CALIX_SURFACE_ID` otherwise. The fail-open guard above checks
    /// both variables (not just `CALIX_SURFACE_ID`) so a hypothetical
    /// future caller that sets only `CALIX_SESSION_ID` still gets its
    /// event forwarded, rather than the guard silently depending on an
    /// invariant ("`CALIX_SESSION_ID` is only ever set alongside
    /// `CALIX_SURFACE_ID`") that happens to hold today but isn't
    /// enforced anywhere.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calix-agent-hook — forwards a Claude Code hook's stdin JSON to
    # Calix's local Agent Monitor IPC endpoint. Installed and removed by
    # ClaudeHooksConfigManager / CodexHooksConfigManager.

    if [ -z "$CALIX_SURFACE_ID" ] && [ -z "$CALIX_SESSION_ID" ]; then
        exit 0
    fi

    kind="${1:-claude-code}"

    endpoint_file="$HOME/Library/Application Support/Calix/agent-endpoint.json"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    curl -s -m 2 \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calix-Surface-ID: ${CALIX_SESSION_ID:-$CALIX_SURFACE_ID}" \\
        -H "X-Calix-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$port/agent-event" > /dev/null 2>&1

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path.
    static func install(toDirectory directory: String) throws -> String {
        try installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }

    /// Shared installer body: writes `body` to `fileName` inside
    /// `directory` (creating it if needed) and marks it executable
    /// (0755), returning the script's absolute path. Used by both
    /// `AgentHookScript.install(toDirectory:)` above and
    /// `ApprovalHookScript.install(toDirectory:)`, so the actual
    /// write-then-chmod logic exists in exactly one place.
    static func installScript(body: String, fileName: String, toDirectory directory: String) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let scriptPath = (directory as NSString).appendingPathComponent(fileName)
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }
}
