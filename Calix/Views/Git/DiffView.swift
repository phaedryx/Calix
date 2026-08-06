// DiffView.swift
// Calix
//
// AppKit-based diff viewer with syntax coloring. Comment interaction (click
// a line to comment, drag across lines for a range comment) lives directly
// on the text view -- there is no separate gutter/ruler view. A gutter would
// need its own coordinate-space math to translate `NSTextView`'s (flipped)
// line geometry into its own (previously non-flipped) space, and getting
// that translation wrong is exactly what caused markers to render
// misaligned with their lines. Living in the same view as the text avoids
// that whole bug class.

import AppKit

@MainActor
final class DiffView: NSView {
    private let scrollView = NSScrollView()
    private let textView = DiffTextView()
    private(set) var currentDiff: FileDiff?
    var reviewStore: DiffReviewStore?
    private(set) var displayLines: [DisplayLine] = []
    private var activePopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Wire up line click/range-select callbacks
        textView.onLineClicked = { [weak self] displayLineIndex, displayLine in
            self?.handleLineClicked(displayLineIndex: displayLineIndex, displayLine: displayLine)
        }
        textView.onRangeSelected = { [weak self] startIdx, endIdx in
            self?.handleRangeSelected(startDisplayIdx: startIdx, endDisplayIdx: endIdx)
        }
    }

    func display(diff: FileDiff) {
        currentDiff = diff

        if diff.isBinary {
            displayBinaryMessage()
            return
        }

        rebuildDisplayLines()
        let attributed = buildAttributedString(from: displayLines)
        textView.textStorage?.setAttributedString(attributed)

        if diff.isTruncated {
            appendTruncationBanner()
        }
    }

    func redisplayWithComments() {
        guard let diff = currentDiff, !diff.isBinary else { return }
        rebuildDisplayLines()
        let attributed = buildAttributedString(from: displayLines)
        textView.textStorage?.setAttributedString(attributed)
        if diff.isTruncated {
            appendTruncationBanner()
        }
    }

    private func rebuildDisplayLines() {
        guard let diff = currentDiff else {
            displayLines = []
            textView.displayLines = []
            return
        }
        if let store = reviewStore {
            displayLines = store.buildDisplayLines(from: diff.lines)
        } else {
            displayLines = diff.lines.map { .diff($0) }
        }
        textView.displayLines = displayLines
    }

    private func displayBinaryMessage() {
        displayLines = []
        textView.displayLines = []
        let message = "Binary file — cannot display diff"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: "\n\n\t\(message)", attributes: attrs))
    }

    private func appendTruncationBanner() {
        let banner = "\n\n--- Diff truncated (file too large) ---\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.systemOrange,
            .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.1),
        ]
        textView.textStorage?.append(NSAttributedString(string: banner, attributes: attrs))
    }

    private func buildAttributedString(from displayLines: [DisplayLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        for (index, displayLine) in displayLines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            switch displayLine {
            case .diff(let line):
                // Truncate very long lines (minified files)
                var text = line.text
                if text.count > 10_000 {
                    text = String(text.prefix(10_000)) + " [truncated]"
                }

                let attrs: [NSAttributedString.Key: Any]
                switch line.type {
                case .addition:
                    let color = NSColor(named: "diffAdditionText") ?? NSColor.systemGreen
                    let background = NSColor.systemGreen.withAlphaComponent(0.08)
                    // The leading "+" is already the first character of `text`
                    // (the raw unified-diff line, kept verbatim by
                    // `DiffParser`) -- bold just that character so it reads
                    // as the line's change marker instead of blending into
                    // the code that follows it.
                    result.append(NSAttributedString(string: String(text.prefix(1)), attributes: [
                        .font: boldFont, .foregroundColor: color, .backgroundColor: background,
                    ]))
                    result.append(NSAttributedString(string: String(text.dropFirst()), attributes: [
                        .font: font, .foregroundColor: color, .backgroundColor: background,
                    ]))
                    continue
                case .deletion:
                    let color = NSColor(named: "diffDeletionText") ?? NSColor.systemRed
                    let background = NSColor.systemRed.withAlphaComponent(0.08)
                    result.append(NSAttributedString(string: String(text.prefix(1)), attributes: [
                        .font: boldFont, .foregroundColor: color, .backgroundColor: background,
                    ]))
                    result.append(NSAttributedString(string: String(text.dropFirst()), attributes: [
                        .font: font, .foregroundColor: color, .backgroundColor: background,
                    ]))
                    continue
                case .hunkHeader:
                    attrs = [
                        .font: boldFont,
                        .foregroundColor: NSColor.systemCyan,
                        .backgroundColor: NSColor.systemCyan.withAlphaComponent(0.06),
                    ]
                case .meta:
                    attrs = [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .obliqueness: 0.1 as NSNumber,
                    ]
                case .context:
                    attrs = [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                }
                result.append(NSAttributedString(string: text, attributes: attrs))

            case .commentBlock(let comment):
                let prefix: String
                if comment.endLineIndex != nil {
                    prefix = "[\(comment.displayLineNumber)] "
                } else {
                    prefix = ""
                }
                let commentText = "\u{1F4AC} \(prefix)\(comment.text)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.systemBlue,
                    .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.08),
                ]
                result.append(NSAttributedString(string: commentText, attributes: attrs))
            }
        }

        return result
    }

    // MARK: - Comment Interaction

    private func handleLineClicked(displayLineIndex: Int, displayLine: DisplayLine) {
        guard let store = reviewStore else { return }

        switch displayLine {
        case .diff(let line):
            // Only commentable types
            guard line.type == .addition || line.type == .deletion || line.type == .context else { return }

            // Find the original lineIndex in diff.lines by counting .diff entries
            var diffCount = 0
            for i in 0..<displayLineIndex {
                if case .diff = displayLines[i] {
                    diffCount += 1
                }
            }
            let originalIndex = diffCount

            showAddPopover(
                atDisplayLineIndex: displayLineIndex,
                originalDiffLineIndex: originalIndex,
                line: line,
                store: store
            )

        case .commentBlock(let comment):
            showEditPopover(
                atDisplayLineIndex: displayLineIndex,
                comment: comment,
                store: store
            )
        }
    }

    private func showAddPopover(atDisplayLineIndex: Int, originalDiffLineIndex: Int, line: DiffLine, store: DiffReviewStore) {
        activePopover?.close()

        let controller = DiffCommentPopoverController(mode: .add)
        controller.onAdd = { [weak self] text in
            store.addComment(
                lineIndex: originalDiffLineIndex,
                lineNumber: line.newLineNumber,
                oldLineNumber: line.oldLineNumber,
                lineType: line.type,
                text: text
            )
            self?.redisplayWithComments()
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: 80)
        popover.behavior = .transient
        activePopover = popover

        showPopover(popover, atDisplayLineIndex: atDisplayLineIndex)
    }

    private func showEditPopover(atDisplayLineIndex: Int, comment: ReviewComment, store: DiffReviewStore) {
        activePopover?.close()

        let rangeHeader: String?
        if comment.endLineIndex != nil {
            rangeHeader = comment.displayLineNumber
        } else {
            rangeHeader = nil
        }

        let controller = DiffCommentPopoverController(mode: .edit(existingText: comment.text), rangeHeader: rangeHeader)
        controller.onUpdate = { [weak self] text in
            store.updateComment(id: comment.id, text: text)
            self?.redisplayWithComments()
        }
        controller.onDelete = { [weak self] in
            store.removeComment(id: comment.id)
            self?.redisplayWithComments()
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: comment.endLineIndex != nil ? 100 : 80)
        popover.behavior = .transient
        activePopover = popover

        showPopover(popover, atDisplayLineIndex: atDisplayLineIndex)
    }

    private func handleRangeSelected(startDisplayIdx: Int, endDisplayIdx: Int) {
        guard let store = reviewStore, let diff = currentDiff else { return }

        guard let range = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: startDisplayIdx,
            endDisplayIdx: endDisplayIdx,
            displayLines: displayLines
        ) else { return }

        guard range.startOriginal >= 0, range.endOriginal < diff.lines.count else { return }
        let startLine = diff.lines[range.startOriginal]
        let endLine = diff.lines[range.endOriginal]
        let startNum = DiffReviewStore.displayNumber(for: startLine)
        let endNum = DiffReviewStore.displayNumber(for: endLine)

        showAddPopoverForRange(
            atDisplayLineIndex: endDisplayIdx,
            startOriginal: range.startOriginal,
            endOriginal: range.endOriginal,
            rangeHeader: "Lines \(startNum) – \(endNum)",
            store: store
        )
    }

    private func showAddPopoverForRange(
        atDisplayLineIndex: Int,
        startOriginal: Int,
        endOriginal: Int,
        rangeHeader: String,
        store: DiffReviewStore
    ) {
        guard let diff = currentDiff else { return }
        activePopover?.close()

        let controller = DiffCommentPopoverController(mode: .add, rangeHeader: rangeHeader)
        controller.onAdd = { [weak self] text in
            store.addRangeComment(
                startLineIndex: startOriginal,
                endLineIndex: endOriginal,
                lines: diff.lines,
                text: text
            )
            self?.redisplayWithComments()
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: 100)
        popover.behavior = .transient
        activePopover = popover

        showPopover(popover, atDisplayLineIndex: atDisplayLineIndex)
    }

    /// Anchors a popover to a narrow rect at the start of the given display
    /// line, entirely in `textView`'s own (flipped) coordinate space -- no
    /// cross-view conversion, so this can't drift out of alignment the way
    /// the old ruler-relative math could.
    private func showPopover(_ popover: NSPopover, atDisplayLineIndex displayLineIndex: Int) {
        guard let lineRect = textView.rect(forLineAt: displayLineIndex) else { return }
        let anchorRect = NSRect(x: lineRect.minX, y: lineRect.minY, width: 1, height: lineRect.height)
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxX)
    }
}

// MARK: - DiffTextView (line click / range-select / comment-block editing)

@MainActor
final class DiffTextView: NSTextView {
    var displayLines: [DisplayLine] = []
    /// Fired for a plain click (no drag) on a commentable diff line or an
    /// existing comment block.
    var onLineClicked: ((Int, DisplayLine) -> Void)?
    /// Fired when a click-drag's resulting text selection spans more than
    /// one display line -- dragging to select the lines you want to
    /// comment on doubles as both "select this text" and "comment on this
    /// range," so it needs no separate gesture or reserved gutter space.
    var onRangeSelected: ((Int, Int) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoveredLineIndex: Int? {
        didSet { if oldValue != hoveredLineIndex { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLineIndex = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let idx = lineIndex(at: event), isInteractable(idx) else {
            hoveredLineIndex = nil
            return
        }
        hoveredLineIndex = idx
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Faint full-row highlight on hover -- the only discoverability
        // affordance a commentable line needs, since it lives in the same
        // coordinate space as the text itself and can't misalign with it.
        if let idx = hoveredLineIndex, let rect = rect(forLineAt: idx) {
            NSColor.systemBlue.withAlphaComponent(0.06).setFill()
            rect.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let clickedIdx = lineIndex(at: event)

        // `super`'s mouseDown runs its own tracking loop for click-drag text
        // selection and doesn't return until mouseUp, so by the time it
        // returns, `selectedRange()` already reflects the whole gesture.
        super.mouseDown(with: event)

        let selection = selectedRange()
        guard selection.length > 0 else {
            // Plain click, no drag: comment on (or edit) the clicked line.
            guard let idx = clickedIdx, idx < displayLines.count else { return }
            onLineClicked?(idx, displayLines[idx])
            return
        }

        // Dragged a selection: only treat it as a range-comment gesture if
        // it actually spans more than one line. A same-line selection is
        // left alone as ordinary copyable text.
        guard let startIdx = lineIndex(forCharacterIndex: selection.location),
              let endIdx = lineIndex(forCharacterIndex: max(selection.location, selection.location + selection.length - 1)),
              startIdx != endIdx else { return }
        onRangeSelected?(min(startIdx, endIdx), max(startIdx, endIdx))
    }

    private func isInteractable(_ index: Int) -> Bool {
        guard index < displayLines.count else { return false }
        switch displayLines[index] {
        case .diff(let line):
            return line.type == .addition || line.type == .deletion || line.type == .context
        case .commentBlock:
            return true
        }
    }

    /// The display-line index under an event's location, in this view's own
    /// (flipped) coordinate space.
    private func lineIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let adjustedPoint = NSPoint(x: point.x - textContainerInset.width,
                                    y: point.y - textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return lineIndex(forCharacterIndex: charIndex)
    }

    private func lineIndex(forCharacterIndex charIndex: Int) -> Int? {
        let lines = string.components(separatedBy: "\n")
        var offset = 0
        for (idx, line) in lines.enumerated() {
            let lineEnd = offset + line.utf16.count
            if charIndex >= offset && charIndex <= lineEnd {
                return idx
            }
            offset = lineEnd + 1 // +1 for \n
        }
        return nil
    }

    /// The bounding rect (this view's own coordinate space, full width) of
    /// the given display line. Used for both the hover highlight and
    /// popover anchoring -- one coordinate space, one source of truth.
    func rect(forLineAt index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let lines = string.components(separatedBy: "\n")
        guard index < lines.count else { return nil }

        var charOffset = 0
        for i in 0..<index {
            charOffset += lines[i].utf16.count + 1 // +1 for \n
        }

        let lineLength = max(1, lines[index].utf16.count)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: charOffset, length: lineLength),
            actualCharacterRange: nil
        )
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.x = 0
        lineRect.origin.y += textContainerInset.height
        lineRect.size.width = bounds.width
        return lineRect
    }
}
