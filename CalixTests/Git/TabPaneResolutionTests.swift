// TabPaneResolutionTests.swift
// CalixTests

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Calix

@MainActor
struct TabPaneResolutionTests {
    @Test func resolvePaneContent_noPaneEntry_resolvesToSurface() {
        let leafID = UUID()
        let result = resolvePaneContent(leafID: leafID, in: [:])
        guard case .surface(let id) = result else {
            Issue.record("Expected .surface, got \(result)")
            return
        }
        #expect(id == leafID)
    }

    @Test func resolvePaneContent_gitChangesEntry_resolvesToGitChanges() {
        let leafID = UUID()
        guard case .gitChanges = resolvePaneContent(leafID: leafID, in: [leafID: .gitChanges]) else {
            Issue.record("Expected .gitChanges")
            return
        }
    }

    @Test func resolvePaneContent_diffEntry_resolvesToDiff() {
        let leafID = UUID()
        let source = DiffSource.unstaged(path: "one.txt", workDir: "/repo")
        guard case .diff(let resolvedSource) = resolvePaneContent(leafID: leafID, in: [leafID: .diff(source: source)]) else {
            Issue.record("Expected .diff")
            return
        }
        #expect(resolvedSource == source)
    }

    /// Regression guard for the purely-additive requirement of this task: a
    /// leaf with no `paneContent` entry whose surface is not (yet) registered
    /// must add NO subview at all -- exactly as before pane rendering existed.
    /// Without this, `layoutNode`'s new `else if let tab` branch would install
    /// an invisible `NSHostingView(EmptyView())` over a surface that registers
    /// a moment later.
    @Test func layoutNode_unregisteredSurfaceLeaf_addsNoHostingView() {
        let tab = Tab()
        let container = SplitContainerView(registry: tab.registry, tab: tab)
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        container.updateLayout(tree: SplitTree(leafID: UUID()))

        #expect(container.subviews.isEmpty)
    }

    /// Positive counterpart to the negative case above, which on its own only
    /// proved a leaf does NOT get treated as a surface -- nothing pinned that a
    /// pane leaf actually renders. A `.gitChanges` leaf with no registered
    /// ghostty surface must install an `NSHostingView` for the SwiftUI pane.
    @Test func layoutNode_gitChangesPaneLeaf_installsAHostingView() {
        let tab = Tab()
        let leafID = UUID()
        tab.paneContent[leafID] = .gitChanges
        let container = SplitContainerView(registry: tab.registry, tab: tab)
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        container.updateLayout(tree: SplitTree(leafID: leafID))

        let hostingViews = container.subviews.compactMap { $0 as? NSHostingView<AnyView> }
        #expect(hostingViews.count == 1)
        #expect(hostingViews.first?.frame == container.bounds)
    }

    /// Same for a `.diff` leaf. `gitChangesController` is wired deliberately:
    /// without it `paneView(for:in:)` falls through to `AnyView(EmptyView())`
    /// and still installs a hosting view, so a subview assertion would pass
    /// even with the diff branch broken.
    @Test func layoutNode_diffPaneLeaf_installsAHostingViewWithDiffContent() {
        let tab = Tab()
        let leafID = UUID()
        tab.paneContent[leafID] = .diff(source: .unstaged(path: "one.txt", workDir: "/repo"))
        let session = WindowSession(initialTab: tab)
        let gitChangesController = GitChangesController(
            windowSession: session, refresh: {}, switchToTab: { _ in }, deactivateCurrentTab: {},
            sendToAgent: { _ in .sent }
        )

        let container = SplitContainerView(registry: tab.registry, tab: tab)
        container.gitChangesController = gitChangesController
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        container.updateLayout(tree: SplitTree(leafID: leafID))

        let hostingViews = container.subviews.compactMap { $0 as? NSHostingView<AnyView> }
        #expect(hostingViews.count == 1)

        // Force SwiftUI to actually build the pane's body, so this fails if the
        // `.diff` branch renders nothing rather than a real `DiffPaneView`.
        guard let hostingView = hostingViews.first else { return }
        hostingView.layoutSubtreeIfNeeded()
        #expect(!hostingView.subviews.isEmpty, "the diff pane should render real content, not EmptyView")
    }

    /// Both kinds side by side in one tree: each pane leaf gets its own cached
    /// hosting view, and the surface-less terminal leaf still gets nothing.
    @Test func layoutNode_paneAndUnregisteredSurfaceLeaves_renderOnlyThePanes() {
        let tab = Tab()
        let terminalLeafID = UUID()
        let paneLeafID = UUID()
        tab.splitTree = SplitTree(leafID: terminalLeafID)
        (tab.splitTree, _) = tab.splitTree.insert(
            at: terminalLeafID, direction: .horizontal, newID: paneLeafID)
        tab.paneContent[paneLeafID] = .gitChanges

        let container = SplitContainerView(registry: tab.registry, tab: tab)
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        container.updateLayout(tree: tab.splitTree)

        #expect(container.subviews.compactMap { $0 as? NSHostingView<AnyView> }.count == 1)
    }
}
