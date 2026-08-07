// TitlebarAccessoryView.swift
// Calix
//
// Combines IPCToggleTitlebarButtonView and GitChangesTitlebarButtonView
// into the window's one NSTitlebarAccessoryViewController (see
// CalixWindowController.setupTitlebarAccessory()). A second
// .right-attached accessory controller has no guaranteed ordering
// relative to this one, so both buttons share a single accessory's
// HStack instead. IPC comes first (left of the pair, i.e. closer to
// the window's center) since it's the more persistent global-state
// indicator; git-changes stays rightmost, matching where it already
// sat before this button was added alongside it.

import SwiftUI

struct TitlebarAccessoryView: View {
    var ipcEnabled: Bool
    var onToggleIPC: (() -> Void)?
    var gitChangesOpen: Bool
    var gitChangesVisible: Bool
    var onToggleGitChanges: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            IPCToggleTitlebarButtonView(isEnabled: ipcEnabled, onToggle: onToggleIPC)
            GitChangesTitlebarButtonView(isOpen: gitChangesOpen, isVisible: gitChangesVisible, onToggle: onToggleGitChanges)
        }
    }
}
