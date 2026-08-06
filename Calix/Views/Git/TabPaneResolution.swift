// TabPaneResolution.swift
// Calix
//
// Decides what a SplitTree leaf renders as: a terminal surface (the
// implicit default, absent from a tab's paneContent) or a non-terminal pane
// (git-changes list, diff view) recorded explicitly in it.

import Foundation

enum ResolvedLeafContent: Equatable {
    case surface(UUID)
    case gitChanges
    case diff(DiffSource)
}

func resolvePaneContent(leafID: UUID, in paneContent: [UUID: TabPaneKind]) -> ResolvedLeafContent {
    switch paneContent[leafID] {
    case .none:
        return .surface(leafID)
    case .gitChanges:
        return .gitChanges
    case .diff(let source):
        return .diff(source)
    }
}
