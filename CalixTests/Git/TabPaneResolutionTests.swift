// TabPaneResolutionTests.swift
// CalixTests

import AppKit
import Foundation
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
}
