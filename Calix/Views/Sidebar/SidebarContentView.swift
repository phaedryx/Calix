// SidebarContentView.swift
// Calix
//
// SwiftUI sidebar showing tab groups and their tabs.

import SwiftUI
import AppKit

struct SidebarContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabID: UUID?
    @Binding var sidebarMode: SidebarMode
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onGroupColorChanged: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?
    var onMoveGroup: ((Int, Int) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Namespace private var togglePillNS
    @State private var groupReorderState = TabReorderState()

    @ViewBuilder
    private var togglePill: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sidebarMode = .tabs
                    }
                } label: {
                    Text("Workspace")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            if sidebarMode == .tabs {
                                Color.clear
                                    .overlay { togglePill }
                                    .matchedGeometryEffect(id: "togglePill", in: togglePillNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace")
                .accessibilityAddTraits(sidebarMode == .tabs ? [.isSelected] : [])

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sidebarMode = .agents
                    }
                } label: {
                    Text("Agents")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            if sidebarMode == .agents {
                                Color.clear
                                    .overlay { togglePill }
                                    .matchedGeometryEffect(id: "togglePill", in: togglePillNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agents")
                .accessibilityAddTraits(sidebarMode == .agents ? [.isSelected] : [])
                .accessibilityIdentifier(AccessibilityID.Sidebar.agentModeButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .opacity(controlActiveState == .key ? 1.0 : 0.5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar mode")
            .accessibilityValue({
                switch sidebarMode {
                case .tabs: return "Workspace"
                case .agents: return "Agents"
                }
            }())
            .accessibilityIdentifier(AccessibilityID.Git.modeToggle)

            switch sidebarMode {
            case .tabs:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            GroupSectionView(
                                group: group,
                                isActiveGroup: group.id == activeGroupID,
                                activeTabID: activeTabID,
                                reduceTransparency: reduceTransparency,
                                onGroupSelected: onGroupSelected,
                                onTabSelected: onTabSelected,
                                onCloseTab: onCloseTab,
                                onGroupRenamed: onGroupRenamed,
                                onGroupColorChanged: onGroupColorChanged,
                                onTabRenamed: onTabRenamed,
                                onCollapseToggled: onCollapseToggled,
                                onCloseAllTabsInGroup: onCloseAllTabsInGroup,
                                onMoveTab: onMoveTab,
                                onGroupDragChanged: { translation in
                                    guard groups.count > 1, onMoveGroup != nil else { return }
                                    if groupReorderState.draggedTabID == nil {
                                        groupReorderState.draggedTabID = group.id
                                        groupReorderState.draggedTabIndex = index
                                    }
                                    // Unanimated: must track the cursor 1:1.
                                    groupReorderState.dragOffset = translation.height
                                    if let frame = groupReorderState.tabFrames[group.id] {
                                        let midpoint = frame.midY + translation.height
                                        // Animated: makes sibling groups
                                        // visibly slide to make room. Not a
                                        // standing `.animation(value:)` on
                                        // the row -- see the matching tab-row
                                        // comment for why that force-animates
                                        // the reset-to-0 at release too and
                                        // races against the unanimated hard
                                        // refresh `onMoveGroup` triggers.
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            groupReorderState.updateInsertionSlot(dragMidpoint: midpoint, axis: .vertical)
                                        }
                                    }
                                },
                                onGroupDragEnded: {
                                    let moveFrom = groupReorderState.draggedTabIndex
                                    let moveTo = moveFrom.flatMap { groupReorderState.destinationIndex(fromIndex: $0, tabCount: groups.count) }
                                    if let from = moveFrom, let to = moveTo {
                                        // Real move: reset instantly, right
                                        // before the mutation that triggers
                                        // `refreshHostingView()`'s unanimated
                                        // full-tree rebuild -- see the
                                        // matching tab-row comment.
                                        groupReorderState.reset()
                                        onMoveGroup?(from, to)
                                    } else {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            groupReorderState.reset()
                                        }
                                    }
                                }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: GroupFramePreferenceKey.self,
                                        value: [group.id: geo.frame(in: .named("sidebarGroups"))]
                                    )
                                }
                            )
                            .offset(y: groupRowOffset(forGroupIndex: index, groupID: group.id))
                            .zIndex(groupReorderState.draggedTabID == group.id ? 1 : 0)
                            .scaleEffect(groupReorderState.draggedTabID == group.id ? 1.02 : 1.0)
                            .shadow(color: .black.opacity(groupReorderState.draggedTabID == group.id ? 0.15 : 0), radius: 8)
                        }
                    }
                    .coordinateSpace(name: "sidebarGroups")
                    .onPreferenceChange(GroupFramePreferenceKey.self) { frames in
                        groupReorderState.tabFrames = frames
                    }
                    .onChange(of: groups.map(\.id)) { _, _ in
                        groupReorderState.reset()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .padding(.top, 10)

                Rectangle()
                    .fill(Color.white.opacity(reduceTransparency ? 0.14 : 0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 8)

                Button(action: { onNewGroup?() }) {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .modifier(GlassButtonModifier(reduceTransparency: reduceTransparency))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier(AccessibilityID.Sidebar.newGroupButton)

            case .agents:
                AgentStatusView()
                    .padding(.top, 10)
            }
        }
        .frame(minWidth: SidebarLayout.minWidth)
        .modifier(SidebarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
    }

    // MARK: - Group Live Reflow

    /// Combines the dragged group's own real-time drag offset with the
    /// animated make-room offset applied to sibling groups. Mirrors
    /// `rowOffset`/`reflowOffset` on the tab-row side.
    private func groupRowOffset(forGroupIndex index: Int, groupID: UUID) -> CGFloat {
        if groupReorderState.draggedTabID == groupID {
            return groupReorderState.dragOffset
        }
        return groupReflowOffset(forGroupIndex: index)
    }

    private func groupReflowOffset(forGroupIndex index: Int) -> CGFloat {
        guard let from = groupReorderState.draggedTabIndex,
              let draggedID = groupReorderState.draggedTabID,
              index != from,
              let to = groupReorderState.destinationIndex(fromIndex: from, tabCount: groups.count)
        else { return 0 }

        // Group rows aren't uniform height (a collapsed group vs. one
        // expanded with several tabs can differ enormously), but the shift
        // amount for any affected row is still a constant: removing and
        // reinserting one row just opens/closes a gap the size of *that*
        // row (plus the 8pt spacing from the outer VStack at the call
        // site) -- every row in between slides by that same amount
        // regardless of its own height.
        let rowSpan = (groupReorderState.tabFrames[draggedID]?.height ?? 0) + 8
        if from < to {
            return (index > from && index <= to) ? -rowSpan : 0
        } else {
            return (index >= to && index < from) ? rowSpan : 0
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    let reduceTransparency: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.plain)
        } else {
            content
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.2))
                )
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
        }
    }
}

private struct SidebarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    private var chromeScheme: ColorScheme {
        let tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(.all, edges: .top))
        } else {
            content
                .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}

private struct GroupSectionView: View {
    let group: TabGroup
    let isActiveGroup: Bool
    let activeTabID: UUID?
    let reduceTransparency: Bool
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onGroupColorChanged: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?
    var onGroupDragChanged: ((CGSize) -> Void)?
    var onGroupDragEnded: (() -> Void)?

    @State private var isEditing = false
    @State private var isHoveringHeader = false
    @State private var reorderState = TabReorderState()

    /// A small filled-circle bitmap, explicitly non-template so AppKit
    /// renders it in its actual color inside a menu item instead of
    /// recoloring it to the menu's monochrome tint.
    private static func swatchImage(for nsColor: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group header
            if isEditing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(subduedDotColor(group.color.nsColor))
                        .frame(width: 6, height: 6)
                        .opacity(isActiveGroup ? 1.0 : 0.5)
                    InlineTextField(
                        initialText: group.name,
                        accessibilityID: AccessibilityID.Sidebar.groupNameTextField(group.id),
                        fontSize: 12,
                        fontWeight: .semibold,
                        onCommit: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                group.name = trimmed
                            }
                            isEditing = false
                            onGroupRenamed?()
                        },
                        onCancel: {
                            isEditing = false
                        }
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency
                ))
            } else {
                TabClickContainer(
                    isEnabled: !isEditing,
                    onSingleClick: { onGroupSelected?(group.id) },
                    onDoubleClick: { isEditing = true },
                    onDragChanged: onGroupDragChanged,
                    onDragEnded: onGroupDragEnded
                ) {
                    HStack(spacing: 0) {
                        // Left: group name area (visual content only; click
                        // handled by surrounding TabClickContainer)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(subduedDotColor(group.color.nsColor))
                                .frame(width: 6, height: 6)
                                .opacity(isActiveGroup ? 1.0 : 0.5)
                            Text(group.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .tracking(0.4)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.tabs.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .contextMenu {
                            ForEach(TabGroupColor.allCases, id: \.self) { color in
                                Button {
                                    group.color = color
                                    onGroupColorChanged?()
                                } label: {
                                    // AppKit treats an SF Symbol used as a
                                    // menu-item icon as a monochrome
                                    // "template" image and discards any
                                    // `.foregroundStyle` tint -- that's why
                                    // every swatch rendered white/plain.
                                    // A real (non-template) bitmap image
                                    // keeps its actual color instead.
                                    let title = color.rawValue.capitalized + (group.color == color ? "  \u{2713}" : "")
                                    Label {
                                        Text(title)
                                    } icon: {
                                        Image(nsImage: Self.swatchImage(for: color.nsColor))
                                    }
                                }
                            }
                        }

                        // Close all tabs button (shown on hover)
                        Button(action: { onCloseAllTabsInGroup?(group.id) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .opacity(isHoveringHeader ? 1 : 0)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isHoveringHeader)
                        .closeButtonHoverHighlight(size: 20, isVisible: isHoveringHeader, hoverOpacity: 0.08)
                        .accessibilityIdentifier(AccessibilityID.Sidebar.groupCloseAllButton(group.id))

                        // Right: collapse toggle button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                group.isCollapsed.toggle()
                            }
                            onCollapseToggled?()
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(group.isCollapsed ? .zero : .degrees(90))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.Sidebar.groupCollapseButton(group.id))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .modifier(GroupHeaderBackgroundModifier(
                        isActiveGroup: isActiveGroup,
                        reduceTransparency: reduceTransparency
                    ))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Sidebar.group(group.id))
                // The group-name `Text` lives inside the header's
                // `TabClickContainer` `NSHostingView` and is otherwise
                // invisible to XCUITest / assistive tech (the `.contain`
                // container does not surface hosted children). Carry the
                // name explicitly so the group announces itself and
                // name-based lookups (e.g. after a rename) resolve it.
                .accessibilityLabel(group.name)
                .onAssumeInsideHover($isHoveringHeader)
            }

            // Tabs in this group (only show if not collapsed)
            if !group.isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRowItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID && isActiveGroup,
                            onSelected: { onTabSelected?(tab.id) },
                            onClose: { onCloseTab?(tab.id) },
                            onTabRenamed: onTabRenamed,
                            onDragChanged: { translation in
                                // Tab reorder: equivalent to the former
                                // SwiftUI `DragGesture.onChanged`, but
                                // driven by `ClickContainerNSView` so no
                                // `PlatformGroupContainer` compositing
                                // layer is created on top of the row.
                                guard group.tabs.count > 1, onMoveTab != nil else { return }
                                if reorderState.draggedTabID == nil {
                                    reorderState.draggedTabID = tab.id
                                    reorderState.draggedTabIndex = index
                                }
                                // Unanimated: must track the cursor 1:1.
                                reorderState.dragOffset = translation.height
                                if let frame = reorderState.tabFrames[tab.id] {
                                    let midpoint = frame.midY + translation.height
                                    // Animated: this is what makes sibling
                                    // rows visibly slide to make room as
                                    // the insertion slot changes. Deliberately
                                    // NOT a standing `.animation(value:)` on
                                    // the row -- that would also catch (and
                                    // force-animate) the reset-to-0 at
                                    // release, racing against the unanimated
                                    // hard refresh `onMoveTab` triggers.
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        reorderState.updateInsertionSlot(dragMidpoint: midpoint, axis: .vertical)
                                    }
                                }
                            },
                            onDragEnded: {
                                let moveFrom = reorderState.draggedTabIndex
                                let moveTo = moveFrom.flatMap { reorderState.destinationIndex(fromIndex: $0, tabCount: group.tabs.count) }
                                if let from = moveFrom, let to = moveTo {
                                    // A real move is about to trigger
                                    // `onMoveTab` -> `refreshHostingView()`,
                                    // an imperative full-tree rebuild that
                                    // isn't animation-aware (see its doc
                                    // comment). Reset instantly rather than
                                    // animating: the reflow math already
                                    // lines this row's dragged offset up
                                    // with its true destination slot, so an
                                    // unanimated reset followed by the
                                    // unanimated rebuild lands on the same
                                    // position instead of visibly jumping.
                                    reorderState.reset()
                                    onMoveTab?(group.id, from, to)
                                } else {
                                    // No move: nothing will trigger a hard
                                    // refresh, so animate the snap-back to
                                    // this row's original slot.
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        reorderState.reset()
                                    }
                                }
                            }
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [tab.id: geo.frame(in: .named("sidebarGroup-\(group.id.uuidString)"))]
                                )
                            }
                        )
                        .offset(y: rowOffset(forRowIndex: index, tabID: tab.id, in: group))
                        .zIndex(reorderState.draggedTabID == tab.id ? 1 : 0)
                        .scaleEffect(reorderState.draggedTabID == tab.id ? 1.03 : 1.0)
                        .shadow(color: .black.opacity(reorderState.draggedTabID == tab.id ? 0.15 : 0), radius: 8)
                        // NOTE: `.gesture(tabDragGesture(...))` was removed
                        // here. Drag tracking now happens inside
                        // `ClickContainerNSView` via `mouseDragged` /
                        // `mouseUp` to avoid a `PlatformGroupContainer`
                        // compositing layer that would intercept clicks.
                        .accessibilityValue(AccessibilityID.Sidebar.tabAtIndex(group.id, index))
                    }
                }
                .coordinateSpace(name: "sidebarGroup-\(group.id.uuidString)")
                .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                    reorderState.tabFrames = frames
                }
            }
        }
        .padding(.bottom, 4)
        .onChange(of: group.tabs.map(\.id)) { _, _ in
            reorderState.reset()
        }
    }

    private func subduedDotColor(_ nsColor: NSColor) -> Color {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s * 0.7), brightness: Double(b * 0.9), opacity: Double(a))
    }

    // MARK: - Live Reflow

    /// Combines the dragged row's own real-time drag offset with the
    /// animated make-room offset applied to its siblings, so both are
    /// driven by a single `.offset` modifier per row.
    private func rowOffset(forRowIndex index: Int, tabID: UUID, in group: TabGroup) -> CGFloat {
        if reorderState.draggedTabID == tabID {
            return reorderState.dragOffset
        }
        return reflowOffset(forRowIndex: index, in: group)
    }

    /// How far a sibling row (not the one being dragged) should slide to
    /// open a gap at the drop destination, replacing the former static
    /// insertion-line indicator with rows that visibly make room.
    private func reflowOffset(forRowIndex index: Int, in group: TabGroup) -> CGFloat {
        guard let from = reorderState.draggedTabIndex,
              let draggedID = reorderState.draggedTabID,
              index != from,
              let to = reorderState.destinationIndex(fromIndex: from, tabCount: group.tabs.count)
        else { return 0 }

        let rowHeight = reorderState.tabFrames[draggedID]?.height ?? 0
        if from < to {
            return (index > from && index <= to) ? -rowHeight : 0
        } else {
            return (index >= to && index < from) ? rowHeight : 0
        }
    }
}

private struct GroupHeaderBackgroundModifier: ViewModifier {
    let isActiveGroup: Bool
    let reduceTransparency: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(isActiveGroup ? 0.18 : 0.05))
            )
        } else if isActiveGroup {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
        } else {
            content
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
        }
    }
}

private struct TabRowItemView: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isEditing = false
    @State private var isHovering = false

    private var tabIcon: String {
        switch tab.content {
        case .terminal: "terminal"
        case .browser: "globe"
        }
    }

    private var isWorking: Bool {
        ClaudeTitleHeuristic.classify(title: tab.title) == .working
    }

    private var visibleTitle: String {
        tab.titleOverride ?? ClaudeTitleHeuristic.stripLeadingSpinnerGlyph(from: tab.title)
    }

    private var titleColor: Color {
        if isWorking { return .green }
        if tab.unreadNotifications > 0 { return .yellow }
        return .primary
    }

    var body: some View {
        let displayText = visibleTitle.isEmpty ? fallbackTitle : visibleTitle
        let closeIsActive = (isHovering || isActive) && !isEditing

        // CLOSE BUTTON (geometry-only, no SwiftUI Button):
        // The close button is rendered as a visual-only
        // `Image(systemName: "xmark")` inside the HStack. Click hit
        // detection happens entirely in `ClickContainerNSView.mouseDown`
        // by computing a 16x16 right-aligned rect inset 14pt from the
        // trailing edge and matching it against the press location.
        // When `closeButtonEnabled` is true and the press lands inside
        // that rect, `onClose` fires directly. See the matching comment
        // in `TabItemButton` for the full rationale.
        TabClickContainer(
            isEnabled: !isEditing,
            onSingleClick: {
                onSelected?()
            },
            onDoubleClick: {
                isEditing = true
            },
            onClose: {
                onClose?()
            },
            closeButtonEnabled: closeIsActive,
            closeButtonInsetFromTrailing: 14,
            closeButtonSize: 16,
            onDragChanged: { translation in
                onDragChanged?(translation)
            },
            onDragEnded: {
                onDragEnded?()
            }
        ) {
            HStack(spacing: 4) {
                Image(systemName: tabIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isEditing {
                    InlineTextField(
                        initialText: displayText,
                        accessibilityID: AccessibilityID.Sidebar.tabNameTextField(tab.id),
                        fontSize: 12.5,
                        fontWeight: .semibold,
                        onCommit: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            tab.titleOverride = trimmed.isEmpty ? nil : trimmed
                            isEditing = false
                            onTabRenamed?()
                        },
                        onCancel: {
                            isEditing = false
                        }
                    )
                } else {
                    Text(displayText)
                        .lineLimit(1)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(titleColor)
                }
                if let branch = tab.gitBranch, !branch.isEmpty, branch != "HEAD" {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(branch)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
                    .layoutPriority(-1)
                }
                Spacer()
                // Visual-only close icon. No `.onTapGesture`, no
                // `Button`. Hit detection is done in
                // `ClickContainerNSView.mouseDown` against the same
                // 16x16 rect inset 14pt from the trailing edge.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .frame(width: 16, height: 16)
                    .opacity(closeIsActive ? 1 : 0)
                    .closeButtonHoverHighlight(size: 16, isVisible: closeIsActive)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.tabCloseButton(tab.id))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 31)
            .modifier(TabChromeModifier(
                isActive: isActive,
                cornerRadius: 12,
                reduceTransparency: reduceTransparency
            ))
        }
        .onAssumeInsideHover($isHovering)
        .onChange(of: tab.renameRequestID) { _, newValue in
            if newValue != nil { isEditing = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.tab(tab.id))
        // The title `Text` lives inside the `TabClickContainer`'s
        // `NSHostingView`, whose subtree the `.contain` container does not
        // surface to XCUITest / assistive tech. Carry the name explicitly on
        // the container so the row announces its title (and so name-based
        // lookups resolve it), matching `TabItemButton` in the tab bar.
        .accessibilityLabel(displayText)
    }

    private var fallbackTitle: String {
        if case .browser(let url) = tab.content {
            return url.host() ?? url.absoluteString
        }
        return "Terminal"
    }
}

extension TabContent {
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }
}
