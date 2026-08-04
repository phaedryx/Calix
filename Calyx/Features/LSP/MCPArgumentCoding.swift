//
//  MCPArgumentCoding.swift
//  Calyx
//
//  Argument-coercion and response-shaping helpers shared by every MCP LSP
//  tool. Extracted out of MCPLSPBridge so these pure, stateless functions
//  (they read only their own arguments, never bridge/session state) get
//  direct unit test coverage without needing a full bridge + session
//  fixture. MCPLSPBridgeError itself stays in MCPLSPBridge.swift — it is
//  the dispatcher's own error type (it also carries .unknownTool, which is
//  unrelated to argument coding) — and both files are the same module, so
//  no import is needed to reference it here.
//

import Foundation

enum MCPArgumentCoding {

    // MARK: - Argument coercion

    /// Decode the `AnyCodable` value at `key` as a `String`, throwing
    /// `MCPLSPBridgeError.missingArgument` if absent and
    /// `MCPLSPBridgeError.invalidArgument` if the underlying JSON is the
    /// wrong shape.
    static func requireString(arguments: [String: AnyCodable], key: String) throws -> String {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
        guard let value: String = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return value
    }

    /// Decode the `AnyCodable` value at `key` as an `Int`.
    static func requireInt(arguments: [String: AnyCodable], key: String) throws -> Int {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
        guard let value: Int = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return value
    }

    /// Decode an optional `Bool` argument; returns `nil` when absent.
    static func optionalBool(arguments: [String: AnyCodable], key: String) throws -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let value: Bool = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected boolean")
        }
        return value
    }

    /// Decode a required `Bool` argument; throws `missingArgument` when
    /// absent and `invalidArgument` when the underlying JSON is the wrong
    /// shape (e.g. a stray integer or string instead of a boolean).
    static func requireBool(arguments: [String: AnyCodable], key: String) throws -> Bool {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
        guard let value: Bool = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected boolean")
        }
        return value
    }

    /// Decode an optional `Int` argument; returns `nil` when absent.
    static func optionalInt(arguments: [String: AnyCodable], key: String) throws -> Int? {
        guard let raw = arguments[key] else { return nil }
        guard let value: Int = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return value
    }

    /// Decode an optional `String` argument; returns `nil` when absent.
    static func optionalString(arguments: [String: AnyCodable], key: String) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value: String = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return value
    }

    /// Decode an `AnyCodable` payload (typically a nested JSON object such
    /// as a `CallHierarchyItem` / `TypeHierarchyItem`) into a typed
    /// `Decodable` value by round-tripping through JSON. Used by the
    /// item-based hierarchy tools to turn the raw `item` argument into the
    /// strongly-typed parameter expected by the LSP request.
    static func decodeFromAnyCodable<T: Decodable>(
        _ value: AnyCodable,
        as type: T.Type,
        argumentName: String
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MCPLSPBridgeError.invalidArgument(
                name: argumentName,
                reason: "failed to decode as \(T.self): \(error)"
            )
        }
    }

    /// `AnyCodable.storage` is private; recover the underlying primitive
    /// by round-tripping through `JSONEncoder` + `JSONSerialization`.
    ///
    /// `Int` and `Bool` use strict numeric discrimination:
    ///   - `Int` rejects fractional doubles (`3.9` → nil, not truncated to 3)
    ///     and CFBoolean values.
    ///   - `Bool` only accepts actual `CFBoolean` instances, not arbitrary
    ///     `NSNumber`s coerced via `boolValue` (a JSON `42` must not become
    ///     `true` just because it is non-zero).
    private static func decodeValue<T>(_ raw: AnyCodable) -> T? {
        guard let data = try? JSONEncoder().encode(raw),
              let any = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              )
        else { return nil }

        // Bool: reject NSNumbers that aren't a CFBoolean. This is the only
        // way to distinguish JSON `true`/`false` from JSON `1`/`0` — the
        // standard `as? Bool` cast happily succeeds for any 0/1 NSNumber.
        if T.self == Bool.self {
            guard let n = any as? NSNumber,
                  CFGetTypeID(n) == CFBooleanGetTypeID()
            else { return nil }
            return n.boolValue as? T
        }

        // Int: require a whole-number NSNumber. Reject fractional doubles
        // (truncating 3.9 to 3 was the historical defect) and CFBooleans
        // (so `include_declaration: true` does not silently become `1`).
        if T.self == Int.self {
            guard let n = any as? NSNumber else { return nil }
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d.isFinite,
                  d == d.rounded(.toNearestOrEven),
                  d == floor(d)
            else { return nil }
            return Int(truncating: n) as? T
        }

        if let value = any as? T { return value }
        return nil
    }

    /// Normalize `input` (either an absolute filesystem path or a
    /// `file://` URI) into a `(uri, fileURL)` pair where both fields are
    /// derived from the same canonical path. The two forms (raw path vs
    /// `file://`) MUST converge so the session-cache key in
    /// `LSPService.session(for:)` doesn't split a single logical
    /// workspace into two sessions.
    ///
    /// Returns `fileURL == nil` only for truly unparseable `file://`
    /// inputs (e.g. `file://[bad]/foo bar baz`) whose path component
    /// doesn't even start with `/`. Callers that need to react to that
    /// case (`ensureFileOpen` throws an `invalidArgument` error) inspect
    /// the optional directly.
    static func normalizeFileURI(_ input: String) -> (uri: String, fileURL: URL?) {
        // A registered-name host (RFC 3986 §3.2.2) is composed of
        // unreserved + sub-delims + percent-encoded octets. We accept
        // the conservative subset that covers SMB-share / DNS hostnames
        // in practice (ASCII letters, digits, `.`, `-`, `_`, `~`) and
        // reject everything else — in particular `[`, `]`, whitespace,
        // and `/` which would indicate a malformed authority component
        // (e.g. `file://[bad]/...`).
        func isValidRegisteredHost(_ host: String) -> Bool {
            guard !host.isEmpty else { return false }
            for scalar in host.unicodeScalars {
                let v = scalar.value
                let isASCIILetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                let isDigit = v >= 0x30 && v <= 0x39
                let isOtherUnreserved = scalar == "." || scalar == "-"
                    || scalar == "_" || scalar == "~"
                if !(isASCIILetter || isDigit || isOtherUnreserved) {
                    return false
                }
            }
            return true
        }

        if input.hasPrefix("file://") {
            // Fast path: a well-formed `file://` URI with no query /
            // fragment. `URL(string:)` correctly percent-decodes the
            // path portion and round-trips spaces and friends through
            // `.absoluteString`. We bail to the rebuild path when:
            //   * URL(string:) returns nil (someone smuggled in totally
            //     malformed text after the scheme)
            //   * isFileURL is false (the scheme was rewritten)
            //   * query / fragment are present (a `?` in the filename is
            //     a perfectly legal POSIX path char but URL(string:)
            //     misinterprets it as a query delimiter — the rebuild
            //     path correctly re-encodes it)
            //
            // Per RFC 8089 §3 the `file://<host>/<path>` form is valid
            // (SMB shares, Windows UNC paths). We accept both the
            // empty-host (`file:///path`) and the non-empty-host
            // (`file://server/share/path`) forms here, provided the
            // path component is absolute. A non-empty host must look
            // like a registered name — anything that looks like a
            // malformed IP-literal (`[bad]`) or carries forbidden host
            // characters is rejected so the caller can surface a
            // structured "unparseable URI" error.
            if let url = URL(string: input),
               url.isFileURL,
               url.query == nil,
               url.fragment == nil,
               url.path.hasPrefix("/") {
                // Use URLComponents.host because it preserves the
                // square-bracket form for IP-literals — e.g.
                // `file://[bad]/...` exposes host=="[bad]" via
                // URLComponents but host=="bad" via URL.host, and the
                // bracketed form is the one we must reject as a
                // malformed registered name.
                let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? ""
                if host.isEmpty || isValidRegisteredHost(host) {
                    return (url.absoluteString, url)
                }
            }
            // Strip the scheme and inspect what comes next. A
            // well-formed file URI is either:
            //   * `file:///<absolute-path>` — empty host, path starts at
            //     the third `/`.
            //   * `file://<host>/<absolute-path>` (RFC 8089 §3) — host
            //     ends at the first `/` after the scheme, path is
            //     everything from that `/` onwards.
            // For the empty-host form we can hand the absolute path to
            // `URL(fileURLWithPath:)` directly. For the host form we
            // must preserve the host on the rebuild so the
            // percent-encoded output keeps the `file://<host>/<path>`
            // shape.
            let pathPart = String(input.dropFirst("file://".count))
            if pathPart.hasPrefix("/") {
                let fileURL = URL(fileURLWithPath: pathPart)
                return (fileURL.absoluteString, fileURL)
            }
            // Host form: split on the first `/` after the scheme. The
            // remainder MUST start with `/` (an absolute path) — anything
            // else is malformed (`file://server` with no path, etc.).
            if let slashIdx = pathPart.firstIndex(of: "/") {
                let host = String(pathPart[..<slashIdx])
                let absolutePath = String(pathPart[slashIdx...])
                if isValidRegisteredHost(host), absolutePath.hasPrefix("/") {
                    // Build a `file://<host><absolute-path>` URL via
                    // URLComponents so the host is preserved and the
                    // path is percent-encoded consistently with the
                    // empty-host fast path.
                    var comps = URLComponents()
                    comps.scheme = "file"
                    comps.host = host
                    comps.path = absolutePath
                    if let url = comps.url, url.isFileURL {
                        return (url.absoluteString, url)
                    }
                }
            }
            // Anything else is malformed; return nil so `ensureFileOpen`
            // can throw a structured error instead of silently inventing
            // a relative path.
            return (input, nil)
        }
        let fileURL = URL(fileURLWithPath: input)
        return (fileURL.absoluteString, fileURL)
    }

    /// Convert a workspace path (either an absolute filesystem path or a
    /// `file://` URI) into a `URL` suitable for `LSPService.session(for:)`.
    /// The result is derived from `normalizeFileURI` so raw-path and
    /// `file://` callers converge on the same `URL` (and therefore the
    /// same session-cache key).
    static func fileURL(fromPathOrUri input: String) -> URL {
        if let url = normalizeFileURI(input).fileURL {
            return url
        }
        // Fall back to a permissive `URL(fileURLWithPath:)` on the raw
        // input so this helper never returns nil for legitimate workspace
        // paths. `ensureFileOpen` is the surface that surfaces
        // "unparseable" as a structured error, not this helper.
        return URL(fileURLWithPath: input)
    }

    /// Convert an absolute path or `file://` URI into the LSP
    /// `DocumentUri` (string) form. Goes through `normalizeFileURI` so
    /// raw-path callers and `file://` callers produce the same
    /// percent-encoded string for the same logical file.
    static func documentUri(fromPathOrUri input: String) -> DocumentUri {
        normalizeFileURI(input).uri
    }

    // MARK: - Response shaping helpers

    /// Encode a result as a single-text-block `MCPContent`. Used by every
    /// success path.
    static func makeJSONContent<T: Encodable>(_ value: T) throws -> MCPContent {
        let encoder = JSONEncoder()
        // Stable key order keeps test snapshots deterministic.
        // `.withoutEscapingSlashes` keeps file:// URIs (and other slashed
        // strings) human-readable instead of emitting `file:\/\/` escapes
        // — important for MCP callers that grep the JSON payload.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8) ?? "null"
        return MCPContent(type: "text", text: text)
    }

    /// Map an LSPSession error (or any other thrown error) into a
    /// human-readable text payload. JSON-RPC server errors are surfaced
    /// inline so the MCP caller can read the diagnostic instead of
    /// receiving an opaque thrown error.
    static func makeErrorContent(_ error: Error) -> MCPContent {
        let message: String
        switch error {
        case let LSPSessionError.clientError(inner):
            message = describe(clientError: inner)
        case let inner as LSPClientError:
            message = describe(clientError: inner)
        default:
            message = String(describing: error)
        }
        return MCPContent(type: "text", text: "LSP error: \(message)")
    }

    private static func describe(clientError: LSPClientError) -> String {
        switch clientError {
        case .serverError(let code, let message):
            return "server error \(code): \(message)"
        case .responseDecodingFailed(let reason):
            return "response decoding failed: \(reason)"
        case .malformedFraming(let reason):
            return "malformed framing: \(reason)"
        case .methodNotFound(let m):
            return "method not found: \(m)"
        case .timeout:
            return "timeout"
        case .transportClosed:
            return "transport closed"
        case .alreadyStarted:
            return "client already started"
        case .notStarted:
            return "client not started"
        }
    }

    /// Pull `file`, `line`, `column` from `arguments` and build the
    /// `(uri, position)` pair shared by every position-based LSP request.
    static func extractPosition(arguments: [String: AnyCodable]) throws -> (uri: DocumentUri, position: Position) {
        let file = try MCPArgumentCoding.requireString(arguments: arguments, key: "file")
        let line = try MCPArgumentCoding.requireInt(arguments: arguments, key: "line")
        let column = try MCPArgumentCoding.requireInt(arguments: arguments, key: "column")
        let uri = MCPArgumentCoding.documentUri(fromPathOrUri: file)
        return (uri, Position(line: line, character: column))
    }

    /// Pull just the `file` key (used by `documentSymbol`).
    static func extractDocumentUri(arguments: [String: AnyCodable]) throws -> DocumentUri {
        let file = try MCPArgumentCoding.requireString(arguments: arguments, key: "file")
        return MCPArgumentCoding.documentUri(fromPathOrUri: file)
    }

    /// Pull `file`, `start_line`, `start_column`, `end_line`, `end_column`
    /// from `arguments` and build the `(uri, range)` pair shared by every
    /// range-based LSP request (`lsp_code_action`, `lsp_inlay_hint`,
    /// `lsp_inline_value`).
    static func extractRange(arguments: [String: AnyCodable]) throws -> (uri: DocumentUri, range: LSPRange) {
        let uri = try extractDocumentUri(arguments: arguments)
        let startLine = try MCPArgumentCoding.requireInt(arguments: arguments, key: "start_line")
        let startCol = try MCPArgumentCoding.requireInt(arguments: arguments, key: "start_column")
        let endLine = try MCPArgumentCoding.requireInt(arguments: arguments, key: "end_line")
        let endCol = try MCPArgumentCoding.requireInt(arguments: arguments, key: "end_column")
        let range = LSPRange(
            start: Position(line: startLine, character: startCol),
            end: Position(line: endLine, character: endCol)
        )
        return (uri, range)
    }

    // MARK: - didOpen orchestration

    /// Ensure that `uri` is registered as an open document on `session`
    /// before a position/range/file-based LSP request is dispatched.
    ///
    /// Most language servers (sourcekit-lsp, gopls, rust-analyzer, the
    /// TypeScript server, …) refuse to answer `textDocument/*` requests
    /// for a URI that the client has not previously announced via
    /// `textDocument/didOpen`; sourcekit-lsp surfaces the failure as the
    /// `-32001 "No language service for '...' found"` JSON-RPC error.
    /// MCP tool calls are stateless from the caller's point of view, so
    /// the bridge has to lazily synthesise the didOpen on first contact.
    ///
    /// Behaviour:
    ///   * No-op when the session already tracks the URI (idempotent).
    ///   * No-op for non-`file://` URIs (`untitled:`, `jdt://`, …) — the
    ///     bridge has no on-disk source to read for those.
    ///   * No-op when the file does not exist or can't be read; the
    ///     downstream request will surface a more informative error than
    ///     "we failed before even asking the server."
    ///   * Best-effort: any error from `session.didOpen` is silently
    ///     absorbed so a missing didOpen never replaces the actual
    ///     diagnostic the caller wanted (e.g. a server crash).
    ///
    /// `nonisolated static` so the per-tool handlers (which only carry an
    /// `LSPSession` reference, not the `@MainActor` bridge) can call it
    /// without an extra actor hop.
    ///
    /// Throws when the URI is truly unparseable (`normalizeFileURI` returns
    /// nil for the file:// case), or when the file exists on disk but
    /// cannot be decoded as text in any encoding (UTF-8 attempt followed by
    /// `usedEncoding:` sniff). Non-file URIs (untitled:, jdt://, …) and
    /// file URIs that point at a missing on-disk source are left as silent
    /// no-ops so the downstream LSP request can produce its own diagnostic.
    static func ensureFileOpen(
        session: LSPSession,
        uri: DocumentUri
    ) async throws {
        // Idempotency guard: skip work when the URI is already tracked.
        let openDocs = await session.openDocuments()
        if openDocs.contains(uri) {
            return
        }

        // Only file:// URIs map to a readable on-disk source. Anything
        // else (untitled:, jdt://, vscode-notebook-cell:, …) is left
        // alone — the caller is responsible for opening those via the
        // bridge's notebook / explicit didOpen surface.
        guard uri.hasPrefix("file://") else { return }

        // Normalize via the shared helper so unparseable inputs surface
        // as a structured error instead of a silent no-op.
        let normalized = normalizeFileURI(uri)
        guard let url = normalized.fileURL, url.isFileURL else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "uri",
                reason: "unparseable file URI: \(uri)"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Try UTF-8 first; fall back to a tolerant `usedEncoding:` sniff
        // so non-UTF-8 sources still surface a didOpen instead of a
        // silent skip that hides the encoding issue behind a server-side
        // "no language service" error. As a final safety net, attempt
        // `isoLatin1` — every byte 0x00-0xFF maps to a Unicode codepoint
        // in Latin-1, so the decode is guaranteed to succeed for any
        // file that opens at all. The throw on the very last branch
        // therefore only fires when even opening the file fails (e.g.
        // permissions revoked between the existence check and the read).
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else {
            var used = String.Encoding.utf8
            if let sniffed = try? String(contentsOf: url, usedEncoding: &used) {
                text = sniffed
            } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
                text = latin1
            } else {
                throw MCPLSPBridgeError.invalidArgument(
                    name: "uri",
                    reason: "file not readable as text (utf-8 decode and encoding sniff both failed): \(uri)"
                )
            }
        }

        // Use the session's default languageId. `didOpen` is itself
        // idempotent inside the session (it dedups on `openDocs`), so a
        // race between two MCP tool calls that both reach this point
        // before either has finished only sends one notification.
        try? await session.didOpen(
            uri: uri,
            languageId: session.languageId,
            version: 1,
            text: text
        )
    }
}
