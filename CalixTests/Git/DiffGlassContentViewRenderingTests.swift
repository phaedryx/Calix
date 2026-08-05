// DiffGlassContentViewRenderingTests.swift
// CalixTests
//
// Isolates the SwiftUI/AppKit rendering bridge for diff tabs from the
// GitChangesController data layer (already covered by
// DiffTabLifecycleTests). Verifies that swapping `DiffGlassContentView`'s
// `diff` directly from one `.success` value to another -- with no
// intermediate `.loading` frame in between, mirroring a fast-completing
// second file fetch in the real app -- actually replaces the rendered
// content instead of leaving the previous file's diff on screen.

import AppKit
import SwiftUI
import Testing
@testable import Calix

@MainActor
struct DiffGlassContentViewRenderingTests {
    @Test func secondDiffReplacesFirstWithoutIntermediateLoadingFrame() throws {
        let diff1 = FileDiff(
            path: "one.txt",
            lines: [DiffLine(type: .addition, text: "one-changed", oldLineNumber: nil, newLineNumber: 1)],
            isBinary: false, isTruncated: false
        )
        let diff2 = FileDiff(
            path: "two.txt",
            lines: [
                DiffLine(type: .addition, text: "two-changed", oldLineNumber: nil, newLineNumber: 1),
                DiffLine(type: .addition, text: "second line", oldLineNumber: nil, newLineNumber: 2),
            ],
            isBinary: false, isTruncated: false
        )

        let hostingView = NSHostingView(
            rootView: DiffGlassContentView(diff: diff1, reduceTransparency: true, glassOpacity: 1))
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let diffView1 = findDiffView(in: hostingView) else {
            Issue.record("Could not find DiffView in hosting hierarchy after first render")
            return
        }
        #expect(diffView1.currentDiff?.path == "one.txt")
        #expect(diffView1.displayLines.count == diff1.lines.count)

        // Swap straight to diff2's `.success` value -- no intermediate `.loading`
        // render in between, mirroring the real app's fast-completing second fetch.
        hostingView.rootView = DiffGlassContentView(diff: diff2, reduceTransparency: true, glassOpacity: 1)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let diffView2 = findDiffView(in: hostingView) else {
            Issue.record("Could not find DiffView after swapping to diff2")
            return
        }
        #expect(diffView2.currentDiff?.path == "two.txt")
        #expect(diffView2.displayLines.count == diff2.lines.count)
    }

    private func findDiffView(in view: NSView) -> DiffView? {
        if let diffView = view as? DiffView { return diffView }
        for subview in view.subviews {
            if let found = findDiffView(in: subview) { return found }
        }
        return nil
    }

    /// Same scenario, but through the EXACT sequence the real app drives:
    /// tab1 starts `.loading`, flips to `.success(diff1)`, tab2 starts
    /// `.loading` again, then flips to `.success(diff2)` -- and wrapped
    /// with a sibling toolbar view exactly like `MainContentView`'s
    /// `VStack { DiffToolbarView(...); switch diffState { ... } }`, not
    /// `DiffGlassContentView` in isolation.
    @Test func realisticLoadingSuccessSequenceAcrossTwoTabs() throws {
        let diff1 = FileDiff(
            path: "one.txt",
            lines: [DiffLine(type: .addition, text: "one-changed", oldLineNumber: nil, newLineNumber: 1)],
            isBinary: false, isTruncated: false
        )
        let diff2 = FileDiff(
            path: "two.txt",
            lines: [DiffLine(type: .addition, text: "two-changed", oldLineNumber: nil, newLineNumber: 1)],
            isBinary: false, isTruncated: false
        )

        func render(_ state: DiffLoadState, source: DiffSource) -> some View {
            VStack(spacing: 0) {
                DiffToolbarView(source: source)
                switch state {
                case .loading:
                    ProgressView("Loading diff...")
                case .success(let diff):
                    DiffGlassContentView(diff: diff, reduceTransparency: true, glassOpacity: 1)
                case .error(let message):
                    Text(message)
                }
            }
        }

        let source1 = DiffSource.unstaged(path: "one.txt", workDir: "/repo")
        let source2 = DiffSource.unstaged(path: "two.txt", workDir: "/repo")

        let hostingView = NSHostingView(rootView: AnyView(render(.loading, source: source1)))
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView

        func pump() {
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        pump() // tab1: .loading
        hostingView.rootView = AnyView(render(.success(diff1), source: source1))
        pump() // tab1: .success(diff1)

        guard let diffView1 = findDiffView(in: hostingView) else {
            Issue.record("Could not find DiffView after tab1 .success")
            return
        }
        #expect(diffView1.currentDiff?.path == "one.txt")

        hostingView.rootView = AnyView(render(.loading, source: source2))
        pump() // tab2: .loading (should tear down tab1's DiffGlassContentView)

        let diffViewDuringLoading = findDiffView(in: hostingView)
        #expect(diffViewDuringLoading == nil, "DiffView should not exist during tab2's .loading frame")

        hostingView.rootView = AnyView(render(.success(diff2), source: source2))
        pump() // tab2: .success(diff2)

        guard let diffView2 = findDiffView(in: hostingView) else {
            Issue.record("Could not find DiffView after tab2 .success")
            return
        }
        #expect(diffView2.currentDiff?.path == "two.txt")
        #expect(diffView2.displayLines.count == diff2.lines.count)
    }
}
