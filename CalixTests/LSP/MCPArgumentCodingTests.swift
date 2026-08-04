import XCTest
@testable import Calix

final class MCPArgumentCodingTests: XCTestCase {

    private func makeSession() -> LSPSession {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        return LSPSession(
            workspaceRoot: URL(fileURLWithPath: "/tmp/calix-argcoding-tests"),
            languageId: "swift",
            client: client
        )
    }

    func test_requireString_missingKeyThrowsMissingArgument() {
        XCTAssertThrowsError(try MCPArgumentCoding.requireString(arguments: [:], key: "file")) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .missingArgument("file"))
        }
    }

    func test_requireString_wrongTypeThrowsInvalidArgument() {
        XCTAssertThrowsError(
            try MCPArgumentCoding.requireString(arguments: ["file": AnyCodable(42)], key: "file")
        ) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .invalidArgument(name: "file", reason: "expected string"))
        }
    }

    func test_requireString_validReturnsValue() throws {
        let value = try MCPArgumentCoding.requireString(arguments: ["file": AnyCodable("/tmp/a.swift")], key: "file")
        XCTAssertEqual(value, "/tmp/a.swift")
    }

    func test_requireInt_missingKeyThrowsMissingArgument() {
        XCTAssertThrowsError(try MCPArgumentCoding.requireInt(arguments: [:], key: "line")) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .missingArgument("line"))
        }
    }

    func test_requireInt_fractionalDoubleThrowsInvalidArgument() {
        // Historical defect: 3.9 must not silently truncate to 3.
        XCTAssertThrowsError(
            try MCPArgumentCoding.requireInt(arguments: ["line": AnyCodable(3.9)], key: "line")
        ) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .invalidArgument(name: "line", reason: "expected integer"))
        }
    }

    func test_requireInt_validReturnsValue() throws {
        XCTAssertEqual(try MCPArgumentCoding.requireInt(arguments: ["line": AnyCodable(0)], key: "line"), 0)
    }

    func test_requireBool_integerOneIsNotCoercedToTrue() {
        XCTAssertThrowsError(
            try MCPArgumentCoding.requireBool(arguments: ["include_declaration": AnyCodable(1)], key: "include_declaration")
        ) { error in
            XCTAssertEqual(
                error as? MCPLSPBridgeError,
                .invalidArgument(name: "include_declaration", reason: "expected boolean")
            )
        }
    }

    func test_requireBool_validTrueAndFalse() throws {
        XCTAssertEqual(try MCPArgumentCoding.requireBool(arguments: ["x": AnyCodable(true)], key: "x"), true)
        XCTAssertEqual(try MCPArgumentCoding.requireBool(arguments: ["x": AnyCodable(false)], key: "x"), false)
    }

    func test_optionalInt_absentReturnsNil() throws {
        XCTAssertNil(try MCPArgumentCoding.optionalInt(arguments: [:], key: "limit"))
    }

    func test_optionalInt_wrongTypeThrowsInvalidArgument() {
        XCTAssertThrowsError(
            try MCPArgumentCoding.optionalInt(arguments: ["limit": AnyCodable("ten")], key: "limit")
        ) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .invalidArgument(name: "limit", reason: "expected integer"))
        }
    }

    func test_optionalBool_absentReturnsNil() throws {
        XCTAssertNil(try MCPArgumentCoding.optionalBool(arguments: [:], key: "strict"))
    }

    func test_optionalString_presentReturnsValue() throws {
        XCTAssertEqual(
            try MCPArgumentCoding.optionalString(arguments: ["section": AnyCodable("editor")], key: "section"),
            "editor"
        )
    }

    private struct Point: Decodable, Equatable {
        let x: Int
        let y: Int
    }

    func test_decodeFromAnyCodable_decodesNestedObject() throws {
        let payload = AnyCodable(["x": AnyCodable(1), "y": AnyCodable(2)] as [String: AnyCodable])
        let point = try MCPArgumentCoding.decodeFromAnyCodable(payload, as: Point.self, argumentName: "item")
        XCTAssertEqual(point, Point(x: 1, y: 2))
    }

    func test_decodeFromAnyCodable_shapeMismatchThrowsInvalidArgumentWithReason() {
        let payload = AnyCodable(["x": AnyCodable(1)] as [String: AnyCodable]) // missing required "y"
        XCTAssertThrowsError(
            try MCPArgumentCoding.decodeFromAnyCodable(payload, as: Point.self, argumentName: "item")
        ) { error in
            guard case let MCPLSPBridgeError.invalidArgument(name, reason) = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
            XCTAssertEqual(name, "item")
            XCTAssertTrue(reason.hasPrefix("failed to decode as Point:"), "got: \(reason)")
        }
    }

    func test_normalizeFileURI_rawAbsolutePath() {
        let result = MCPArgumentCoding.normalizeFileURI("/tmp/a.swift")
        XCTAssertEqual(result.uri, URL(fileURLWithPath: "/tmp/a.swift").absoluteString)
        XCTAssertEqual(result.fileURL, URL(fileURLWithPath: "/tmp/a.swift"))
    }

    func test_normalizeFileURI_rawPathAndFileSchemeConverge() {
        // Raw path and file:// input for the same file MUST produce the same
        // uri string, or LSPService.session(for:) would split one logical
        // workspace into two session-cache entries.
        let fromPath = MCPArgumentCoding.normalizeFileURI("/tmp/a.swift")
        let fromURI = MCPArgumentCoding.normalizeFileURI("file:///tmp/a.swift")
        XCTAssertEqual(fromPath.uri, fromURI.uri)
    }

    func test_normalizeFileURI_malformedBracketHostReturnsNilFileURL() {
        let result = MCPArgumentCoding.normalizeFileURI("file://[bad]/foo")
        XCTAssertNil(result.fileURL)
        XCTAssertEqual(result.uri, "file://[bad]/foo")
    }

    func test_normalizeFileURI_validRegisteredHostIsPreserved() {
        let result = MCPArgumentCoding.normalizeFileURI("file://myshare/foo/bar.swift")
        XCTAssertNotNil(result.fileURL)
        XCTAssertTrue(result.uri.hasPrefix("file://myshare/"), "got: \(result.uri)")
    }

    func test_fileURLFromPathOrUri_neverThrowsFallsBackForMalformedInput() {
        let url = MCPArgumentCoding.fileURL(fromPathOrUri: "file://[bad]/foo")
        XCTAssertEqual(url, URL(fileURLWithPath: "file://[bad]/foo"))
    }

    func test_documentUri_matchesNormalizeFileURIUri() {
        XCTAssertEqual(
            MCPArgumentCoding.documentUri(fromPathOrUri: "/tmp/a.swift"),
            MCPArgumentCoding.normalizeFileURI("/tmp/a.swift").uri
        )
    }

    private struct Sample: Encodable {
        let uri: String
        let count: Int
    }

    func test_makeJSONContent_sortsKeysAndDoesNotEscapeSlashes() throws {
        let content = try MCPArgumentCoding.makeJSONContent(Sample(uri: "file:///tmp/a.swift", count: 2))
        XCTAssertEqual(content.type, "text")
        XCTAssertEqual(content.text, #"{"count":2,"uri":"file:///tmp/a.swift"}"#)
    }

    func test_makeErrorContent_wrapsSessionClientServerError() {
        let error = LSPSessionError.clientError(.serverError(code: -32001, message: "No language service"))
        let content = MCPArgumentCoding.makeErrorContent(error)
        XCTAssertEqual(content.type, "text")
        XCTAssertEqual(content.text, "LSP error: server error -32001: No language service")
    }

    func test_makeErrorContent_wrapsBareLSPClientError() {
        let content = MCPArgumentCoding.makeErrorContent(LSPClientError.timeout)
        XCTAssertEqual(content.text, "LSP error: timeout")
    }

    private struct DummyError: Error {}

    func test_makeErrorContent_fallsBackToStringDescribingForUnknownErrors() {
        let content = MCPArgumentCoding.makeErrorContent(DummyError())
        XCTAssertTrue(content.text.hasPrefix("LSP error: "))
    }

    func test_extractPosition_validArgumentsIncludingZeroBoundary() throws {
        let args: [String: AnyCodable] = [
            "file": AnyCodable("/tmp/a.swift"), "line": AnyCodable(0), "column": AnyCodable(0),
        ]
        let (uri, position) = try MCPArgumentCoding.extractPosition(arguments: args)
        XCTAssertEqual(uri, MCPArgumentCoding.documentUri(fromPathOrUri: "/tmp/a.swift"))
        XCTAssertEqual(position, Position(line: 0, character: 0))
    }

    func test_extractPosition_missingLineThrowsMissingArgument() {
        let args: [String: AnyCodable] = ["file": AnyCodable("/tmp/a.swift"), "column": AnyCodable(0)]
        XCTAssertThrowsError(try MCPArgumentCoding.extractPosition(arguments: args)) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .missingArgument("line"))
        }
    }

    func test_extractDocumentUri_missingFileThrowsMissingArgument() {
        XCTAssertThrowsError(try MCPArgumentCoding.extractDocumentUri(arguments: [:])) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .missingArgument("file"))
        }
    }

    func test_extractRange_validArguments() throws {
        let args: [String: AnyCodable] = [
            "file": AnyCodable("/tmp/a.swift"),
            "start_line": AnyCodable(1), "start_column": AnyCodable(2),
            "end_line": AnyCodable(3), "end_column": AnyCodable(4),
        ]
        let (uri, range) = try MCPArgumentCoding.extractRange(arguments: args)
        XCTAssertEqual(uri, MCPArgumentCoding.documentUri(fromPathOrUri: "/tmp/a.swift"))
        XCTAssertEqual(range, LSPRange(start: Position(line: 1, character: 2), end: Position(line: 3, character: 4)))
    }

    func test_extractRange_missingEndColumnThrowsMissingArgument() {
        let args: [String: AnyCodable] = [
            "file": AnyCodable("/tmp/a.swift"),
            "start_line": AnyCodable(1), "start_column": AnyCodable(2),
            "end_line": AnyCodable(3),
        ]
        XCTAssertThrowsError(try MCPArgumentCoding.extractRange(arguments: args)) { error in
            XCTAssertEqual(error as? MCPLSPBridgeError, .missingArgument("end_column"))
        }
    }

    func test_ensureFileOpen_nonFileSchemeIsNoOp() async throws {
        let session = makeSession()
        try await MCPArgumentCoding.ensureFileOpen(session: session, uri: "untitled:Untitled-1")
        let openDocs = await session.openDocuments()
        XCTAssertFalse(openDocs.contains("untitled:Untitled-1"))
    }

    func test_ensureFileOpen_missingOnDiskFileIsNoOp() async throws {
        let session = makeSession()
        let uri = "file:///tmp/calix-argcoding-tests-missing-\(UUID().uuidString).swift"
        try await MCPArgumentCoding.ensureFileOpen(session: session, uri: uri)
        let openDocs = await session.openDocuments()
        XCTAssertFalse(openDocs.contains(uri))
    }

    func test_ensureFileOpen_malformedURIThrowsInvalidArgument() async {
        let session = makeSession()
        do {
            try await MCPArgumentCoding.ensureFileOpen(session: session, uri: "file://[bad]/foo")
            XCTFail("expected throw")
        } catch {
            guard case let MCPLSPBridgeError.invalidArgument(name, _) = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
            XCTAssertEqual(name, "uri")
        }
    }
}
