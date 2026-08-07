// GitChangesTitlebarButtonView.swift
// Calix
//
// The git-changes panel toggle, hosted as a titlebar accessory
// (NSTitlebarAccessoryViewController) on the window's right side.
// Replaces the button that used to live inside the now-deleted
// TabBarContentView -- same icon, same visibility/highlight rules,
// relocated because the tab strip it lived in was redundant with the
// Workspace sidebar's own tab list. Deliberately plain (.buttonStyle
// .plain, no GlassButtonModifier): the strip's version used this
// codebase's glass-chrome system, but a native window titlebar isn't
// part of that chrome, so a plain button fits its surroundings better.
// See CalixWindowController's refreshHostingView() for what drives
// isOpen/isVisible.

import SwiftUI

struct GitChangesTitlebarButtonView: View {
    var isOpen: Bool
    var isVisible: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        if isVisible {
            Button(action: { onToggle?() }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help(isOpen ? "Hide Git Changes" : "Show Git Changes")
            .accessibilityLabel("Toggle Git Changes Panel")
            .accessibilityAddTraits(isOpen ? [.isSelected] : [])
            .accessibilityIdentifier(AccessibilityID.Titlebar.gitChangesButton)
        }
    }
}
