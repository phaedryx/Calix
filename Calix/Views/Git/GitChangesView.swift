// GitChangesView.swift
// Calix
//
// SwiftUI sidebar content for git changes display.

import SwiftUI

struct GitChangesView: View {
    let gitChangesState: GitChangesState
    let gitEntries: [GitFileEntry]
    let branchDeltaBase: String?
    let branchDeltaEntries: [BranchDiffEntry]

    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onBranchDeltaFileSelected: ((BranchDiffEntry) -> Void)?
    var onRefresh: (() -> Void)?

    @State private var isStagedExpanded = true
    @State private var isUnstagedExpanded = true
    @State private var isUntrackedExpanded = true
    @State private var isBranchDeltaExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer()
                Button(action: { onRefresh?() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Git.refreshButton)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            switch gitChangesState {
            case .notLoaded, .loading:
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            case .notRepository:
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Not a git repository")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { onRefresh?() }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        workingChangesSection
                        branchDeltaSection
                    }
                }
            }
        }
        .frame(minWidth: 180)
        .accessibilityIdentifier(AccessibilityID.Git.changesContainer)
    }

    // MARK: - Working Changes

    @ViewBuilder
    private var workingChangesSection: some View {
        let staged = gitEntries.filter { $0.isStaged }
        let unstaged = gitEntries.filter { !$0.isStaged && $0.status != .untracked }
        let untracked = gitEntries.filter { $0.status == .untracked }

        if !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !staged.isEmpty {
                    DisclosureGroup(isExpanded: $isStagedExpanded) {
                        ForEach(staged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Staged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(staged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isStagedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.stagedSection)
                }

                if !unstaged.isEmpty {
                    DisclosureGroup(isExpanded: $isUnstagedExpanded) {
                        ForEach(unstaged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Unstaged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(unstaged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isUnstagedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.unstagedSection)
                }

                if !untracked.isEmpty {
                    DisclosureGroup(isExpanded: $isUntrackedExpanded) {
                        ForEach(untracked) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Untracked")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(untracked.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isUntrackedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.untrackedSection)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Branch Delta

    @ViewBuilder
    private var branchDeltaSection: some View {
        if let base = branchDeltaBase, !branchDeltaEntries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                DisclosureGroup(isExpanded: $isBranchDeltaExpanded) {
                    ForEach(branchDeltaEntries) { entry in
                        GitFileRow(entry: entry)
                            .onTapGesture { onBranchDeltaFileSelected?(entry) }
                    }
                } label: {
                    HStack {
                        Text("Δ \(shortRemoteBranchName(base))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(branchDeltaEntries.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isBranchDeltaExpanded.toggle() }
                }
                .accessibilityIdentifier(AccessibilityID.Git.branchDeltaSection)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Git File Row

private struct GitFileRow<Entry: GitPathStatus>: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.status.rawValue)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(fileName)
                .font(.caption)
                .lineLimit(1)

            if let dir = directory {
                Text(dir)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.Git.fileEntry(entry.path))
    }

    private var fileName: String {
        (entry.path as NSString).lastPathComponent
    }

    private var directory: String? {
        let dir = (entry.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    private var statusColor: Color {
        switch entry.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .copied: .blue
        case .untracked: .gray
        case .unmerged: .purple
        case .typeChanged: .yellow
        }
    }
}
