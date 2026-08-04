import XCTest

final class SelectionEditUITests: CalixUITestCase {

    // MARK: - Helpers

    private func pasteToTerminal(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func pollFile(_ path: String, timeout: TimeInterval = 10) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: path),
               let s = try? String(contentsOfFile: path, encoding: .utf8),
               !s.isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Use the app's debug select mechanism (Ctrl+Shift+D) to create a terminal selection
    /// via ghostty FFI. The app reads selection params from the pasteboard as JSON.
    private func selectTerminalText(fromCol: Int, toCol: Int, row: Int) {
        let json = "{\"fromCol\":\(fromCol),\"toCol\":\(toCol),\"row\":\(row)}"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        app.typeKey("d", modifierFlags: [.control, .shift])
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Clear terminal so prompt is at row 0 of the visible viewport.
    private func clearTerminal() {
        pasteToTerminal("clear")
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - Tests

    /// clear → paste "echo TESTWORD >/tmp/e1" → select TESTWORD at row 0 →
    /// Cmd+X → clipboard has TESTWORD, file output lacks it.
    func test_cmdX_cutsSelectedText() {
        let outFile = "/tmp/e1"
        try? FileManager.default.removeItem(atPath: outFile)

        waitFor(app.windows.firstMatch)
        Thread.sleep(forTimeInterval: 2)

        clearTerminal()

        // After clear, prompt is at row 0.
        // Prompt ~32 chars + "echo " = 37 chars before TESTWORD.
        // TESTWORD = 8 chars at cols 37-44.
        let targetWord = "TESTWORD"
        pasteToTerminal("echo \(targetWord) >/tmp/e1")
        Thread.sleep(forTimeInterval: 2.0)

        selectTerminalText(fromCol: 37, toCol: 45, row: 0)

        // Cut
        NSPasteboard.general.clearContents()
        app.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(clip, targetWord, "Clipboard should contain the cut word")

        app.typeKey(.return, modifierFlags: [])
        let output = pollFile(outFile)
        XCTAssertFalse(output.contains(targetWord),
                        "Output must NOT contain the cut word")
    }

    /// clear → paste "echo DELETEME >/tmp/e2" → select DELETEME at row 0 →
    /// Delete → file output lacks DELETEME.
    func test_delete_removesSelectedText() {
        let outFile = "/tmp/e2"
        try? FileManager.default.removeItem(atPath: outFile)

        waitFor(app.windows.firstMatch)
        Thread.sleep(forTimeInterval: 2)

        clearTerminal()

        let targetWord = "DELETEME"
        pasteToTerminal("echo \(targetWord) >/tmp/e2")
        Thread.sleep(forTimeInterval: 2.0)

        selectTerminalText(fromCol: 37, toCol: 45, row: 0)

        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey(.return, modifierFlags: [])

        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outFile),
                       "Output file must exist")
        let output = pollFile(outFile)
        XCTAssertFalse(output.contains(targetWord),
                        "Output must NOT contain the deleted word")
    }

    /// Cmd+X without selection: clipboard unchanged, no crash.
    func test_noSelection_cmdXPassesThrough() {
        waitFor(app.windows.firstMatch)
        Thread.sleep(forTimeInterval: 2)

        pasteToTerminal("echo hello")
        Thread.sleep(forTimeInterval: 0.3)

        NSPasteboard.general.clearContents()

        app.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let clip = NSPasteboard.general.string(forType: .string)
        XCTAssertNil(clip, "Clipboard should remain empty without selection")
        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash")
    }
}
