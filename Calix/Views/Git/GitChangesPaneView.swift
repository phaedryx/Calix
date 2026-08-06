// GitChangesPaneView.swift
// Calix
//
// Renders a tab's git-changes list as a split-tree pane. Reads directly off
// `tab` (an `@Observable` class) so the enclosing `NSHostingView`'s body
// re-evaluates whenever `tab.gitEntries`/`gitChangesState`/etc. change --
// which `SplitContainerView.refreshPaneContent()` triggers explicitly by
// reassigning `rootView`, per this codebase's "mutate then refresh"
// convention.

import SwiftUI

struct GitChangesPaneView: View {
    let tab: Tab
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onBranchDeltaFileSelected: ((BranchDiffEntry) -> Void)?
    var onRefresh: (() -> Void)?

    var body: some View {
        GitChangesView(
            gitChangesState: tab.gitChangesState,
            gitEntries: tab.gitEntries,
            branchDeltaBase: tab.branchDeltaBase,
            branchDeltaEntries: tab.branchDeltaEntries,
            onWorkingFileSelected: onWorkingFileSelected,
            onBranchDeltaFileSelected: onBranchDeltaFileSelected,
            onRefresh: onRefresh
        )
    }
}
