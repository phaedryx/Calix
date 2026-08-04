// SelectionEditHandlerTests.swift
// CalixTests
//
// Tests for SelectionEditHandler: terminal select+cut / select+delete logic.
// Verifies arrow-key navigation to selection end, backspace deletion,
// clipboard integration, and guard conditions (no selection, multi-row, newlines).

import Testing
@testable import Calix

// MARK: - Fakes

@MainActor
final class FakeSelectionReader: SelectionReading {
    var _hasSelection = true
    var _readSelection: (text: String, tlPxX: Double, tlPxY: Double)? = ("hello", 80.0, 0.0)
    var _cellDimensions: (cellW: Double, cellH: Double, cols: Int)? = (8.0, 16.0, 80)
    var _cursorPixelPosition: (x: Double, y: Double)? = (160.0, 0.0) // col 20

    func hasSelection() -> Bool { _hasSelection }
    func readSelection() -> (text: String, tlPxX: Double, tlPxY: Double)? { _readSelection }
    func cellDimensions() -> (cellW: Double, cellH: Double, cols: Int)? { _cellDimensions }
    func cursorPixelPosition() -> (x: Double, y: Double)? { _cursorPixelPosition }
}

@MainActor
final class FakeClipboardWriter: ClipboardWriting {
    var copiedText: String?
    func copyToClipboard(_ text: String) { copiedText = text }
}

enum FakeKeyAction: Equatable {
    case arrowLeft, arrowRight, backspace
}

@MainActor
final class FakeKeyDispatcher: KeyDispatching {
    var actions: [FakeKeyAction] = []
    func sendArrowLeft() { actions.append(.arrowLeft) }
    func sendArrowRight() { actions.append(.arrowRight) }
    func sendBackspace() { actions.append(.backspace) }
}

// MARK: - Tests

@Suite("SelectionEditHandler Tests")
struct SelectionEditHandlerTests {

    // MARK: - Happy Path: Cursor After Selection

    @Test("Cursor after selection sends left arrows then backspaces")
    @MainActor func cursorAfterSelection_sendsLeftArrowsThenBackspaces() {
        // Cursor at col 20 (160px / 8px), selection "hello" at col 10 (80px / 8px)
        // displayWidth = 5, selEnd = 10 + 5 = 15
        // delta = 15 - 20 = -5 → 5 left arrows
        // grapheme clusters = 5 → 5 backspaces
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0) // col 10
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (160.0, 0.0) // col 20

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == true)

        let expectedActions: [FakeKeyAction] =
            Array(repeating: .arrowLeft, count: 5) +
            Array(repeating: .backspace, count: 5)
        #expect(dispatcher.actions == expectedActions)
    }

    // MARK: - Happy Path: Cursor Before Selection

    @Test("Cursor before selection sends right arrows then backspaces")
    @MainActor func cursorBeforeSelection_sendsRightArrowsThenBackspaces() {
        // Cursor at col 5 (40px / 8px), selection "hello" at col 10 (80px / 8px)
        // displayWidth = 5, selEnd = 10 + 5 = 15
        // delta = 15 - 5 = 10 → 10 right arrows
        // grapheme clusters = 5 → 5 backspaces
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0) // col 10
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (40.0, 0.0) // col 5

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == true)

        let expectedActions: [FakeKeyAction] =
            Array(repeating: .arrowRight, count: 10) +
            Array(repeating: .backspace, count: 5)
        #expect(dispatcher.actions == expectedActions)
    }

    // MARK: - Happy Path: Cursor at Selection End

    @Test("Cursor at selection end sends only backspaces")
    @MainActor func cursorAtSelectionEnd_sendsOnlyBackspaces() {
        // Cursor at col 15 (120px / 8px), selection "hello" at col 10 (80px / 8px)
        // displayWidth = 5, selEnd = 10 + 5 = 15
        // delta = 15 - 15 = 0 → 0 arrows
        // grapheme clusters = 5 → 5 backspaces
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0) // col 10
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (120.0, 0.0) // col 15

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == true)

        let expectedActions: [FakeKeyAction] =
            Array(repeating: .backspace, count: 5)
        #expect(dispatcher.actions == expectedActions)
    }

    // MARK: - Guard: No Selection

    @Test("No selection returns false and sends no keys")
    @MainActor func noSelection_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = false

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: Empty Selection Text

    @Test("Empty selection text returns false and sends no keys")
    @MainActor func emptySelection_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("", 80.0, 0.0)

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: Multi-Row Selection

    @Test("Multi-row selection returns false and sends no keys")
    @MainActor func multiRowSelection_returnsFalse() {
        // Cursor Y = 0 (row 0), selection Y = 16 (row 1) — different rows
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 16.0) // Y=16 → row 1
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (160.0, 0.0) // Y=0 → row 0

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: Newline in Selection

    @Test("Newline in selection returns false and sends no keys")
    @MainActor func newlineInSelection_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello\nworld", 80.0, 0.0)

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Clipboard: Cut Copies

    @Test("Cut mode copies selection text to clipboard")
    @MainActor func cut_copiesToClipboard() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0)
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (120.0, 0.0) // col 15 = selEnd

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: true
        )

        #expect(result == true)
        #expect(clipboard.copiedText == "hello")
    }

    // MARK: - Clipboard: Delete Does Not Copy

    @Test("Delete mode does not copy to clipboard")
    @MainActor func delete_doesNotCopyToClipboard() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0)
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (120.0, 0.0)

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == true)
        #expect(clipboard.copiedText == nil)
    }

    // MARK: - Guard: readSelection Fails

    @Test("readSelection returning nil returns false and sends no keys")
    @MainActor func readSelectionFails_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = nil

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: cellDimensions Fails

    @Test("cellDimensions returning nil returns false and sends no keys")
    @MainActor func cellDimensionsFails_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0)
        reader._cellDimensions = nil

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: cursorPixelPosition Fails

    @Test("cursorPixelPosition returning nil returns false and sends no keys")
    @MainActor func cursorPixelPositionFails_returnsFalse() {
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 80.0, 0.0)
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = nil

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Guard: Delta Exceeds Terminal Columns

    @Test("Delta exceeding terminal columns returns false")
    @MainActor func deltaExceedsColumns_returnsFalse() {
        // 5-column terminal, selection "hello" at col 0, cursor at col 100 (800px)
        // selEnd = 0 + 5 = 5, delta = 5 - 100 = -95, abs(95) >= cols(5) → false
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("hello", 0.0, 0.0)
        reader._cellDimensions = (8.0, 16.0, 5)
        reader._cursorPixelPosition = (800.0, 0.0)

        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: nil,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == false)
        #expect(dispatcher.actions.isEmpty)
    }

    // MARK: - Wide Characters (CJK)

    @Test("Wide CJK characters use display width for arrow count")
    @MainActor func wideCharacters_usesDisplayWidth() {
        // Selection "日本語" at col 10 (80px / 8px)
        // displayWidth = 6 (each CJK char = 2 cells), selEnd = 10 + 6 = 16
        // Cursor at col 20 (160px / 8px)
        // delta = 16 - 20 = -4 → 4 left arrows
        // grapheme clusters = 3 → 3 backspaces
        let reader = FakeSelectionReader()
        reader._hasSelection = true
        reader._readSelection = ("日本語", 80.0, 0.0) // col 10
        reader._cellDimensions = (8.0, 16.0, 80)
        reader._cursorPixelPosition = (160.0, 0.0) // col 20

        let clipboard = FakeClipboardWriter()
        let dispatcher = FakeKeyDispatcher()

        let result = SelectionEditHandler.handleSelectionEdit(
            reader: reader,
            clipboard: clipboard,
            dispatcher: dispatcher,
            copyToClipboard: false
        )

        #expect(result == true)

        let expectedActions: [FakeKeyAction] =
            Array(repeating: .arrowLeft, count: 4) +
            Array(repeating: .backspace, count: 3)
        #expect(dispatcher.actions == expectedActions)
    }
}

// MARK: - unicodeDisplayWidth Tests

@Suite("unicodeDisplayWidth Tests")
struct UnicodeDisplayWidthTests {

    @Test("ASCII characters are 1 cell each")
    func displayWidth_asciiOneCellEach() {
        #expect(unicodeDisplayWidth("hello") == 5)
    }

    @Test("CJK characters are 2 cells each")
    func displayWidth_cjkTwoCellsEach() {
        #expect(unicodeDisplayWidth("日本") == 4)
    }

    @Test("Mixed ASCII and CJK yields correct width")
    func displayWidth_mixed() {
        // "a" = 1, "日" = 2, "b" = 1 → total 4
        #expect(unicodeDisplayWidth("a日b") == 4)
    }
}
