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
