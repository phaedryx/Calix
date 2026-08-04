//
//  SimpleLSPTool.swift
//  Calyx
//
//  Generic engine for the ~44 MCPLSPTool conformers that do nothing but
//  parse a document URI + position/range/item out of `arguments`, call
//  `session.sendRequest(method:params:)`, and wrap the result via
//  `makeJSONContent`/`makeErrorContent`. Each conforming tool supplies
//  only data. Composite/AI tools (BatchTool, HoverBundleTool, ...) and
//  tools with response reshaping or installer/service-level dispatch do
//  NOT conform to this protocol.
//

import Foundation

protocol SimpleLSPTool: MCPLSPTool {
    associatedtype Params: Encodable & Sendable
    associatedtype Result: Codable & Sendable

    /// LSP wire method, e.g. `"textDocument/hover"`.
    static var method: String { get }

    /// Build the request params from the raw MCP `arguments`. Returns the
    /// document URI alongside `params` so the shared `handle()` can drive
    /// `ensureFileOpen`; pass `uri: nil` for tools with no associated
    /// open document.
    @MainActor
    static func makeParams(
        arguments: [String: AnyCodable],
        bridge: MCPLSPBridge
    ) throws -> (uri: DocumentUri?, params: Params)
}

extension SimpleLSPTool {
    @MainActor
    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, params) = try makeParams(arguments: arguments, bridge: bridge)
        if let uri {
            try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
        }
        do {
            let result: Result = try await session.sendRequest(
                method: method,
                params: params,
                resultType: Result.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}
