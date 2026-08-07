// IPCToggleTitlebarButtonView.swift
// Calix
//
// The AI Agent IPC enable/disable toggle, hosted alongside
// GitChangesTitlebarButtonView inside the window's single titlebar
// accessory (see TitlebarAccessoryView). Always visible -- unlike the
// git-changes button, IPC is app-global state, not tied to the active
// tab's content. isEnabled tracks AgentRegistry.shared.isServerRunning,
// the @Observable-friendly proxy AgentStatusView already relies on
// (CalixMCPServer.isRunning itself isn't @Observable, so nothing
// redraws off it directly). See CalixWindowController's
// currentTitlebarAccessoryView() for what drives isEnabled, and
// toggleIPC() for what onToggle calls.

import SwiftUI

struct IPCToggleTitlebarButtonView: View {
    var isEnabled: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        Button(action: { onToggle?() }) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .help(isEnabled ? "Disable AI Agent IPC" : "Enable AI Agent IPC")
        .accessibilityLabel("Toggle AI Agent IPC")
        .accessibilityAddTraits(isEnabled ? [.isSelected] : [])
        .accessibilityIdentifier(AccessibilityID.Titlebar.ipcToggleButton)
    }
}
