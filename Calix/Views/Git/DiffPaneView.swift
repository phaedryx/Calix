// DiffPaneView.swift
// Calix
//
// Renders one diff as a split-tree pane. Extracted from the live inlined
// diff render path in `MainContentView` (DiffToolbarView +
// DiffGlassContentView), parameterized by `leafID` instead of "the tab's
// one active diff".

import AppKit
import SwiftUI

struct DiffPaneView: View {
    let leafID: UUID
    let source: DiffSource
    let controller: GitChangesController
    let reduceTransparency: Bool
    let glassOpacity: Double
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    /// Closes this one pane (Task 5), leaving the rest of the tab intact.
    var onClose: (() -> Void)?

    var body: some View {
        let reviewStore = controller.reviewStore(for: leafID)
        VStack(spacing: 0) {
            DiffToolbarView(
                source: source,
                reviewStore: reviewStore,
                onSubmitReview: onSubmitReview,
                onDiscardReview: onDiscardReview,
                totalReviewCommentCount: controller.totalReviewCommentCount,
                reviewFileCount: controller.reviewFileCount,
                onSubmitAllReviews: onSubmitAllReviews,
                onDiscardAllReviews: onDiscardAllReviews,
                onClose: onClose
            )
            switch controller.diffState(for: leafID) {
            case .none, .loading:
                VStack {
                    Spacer()
                    ProgressView("Loading diff...")
                    Spacer()
                }
            case .success(let diff):
                DiffGlassContentView(
                    diff: diff,
                    reduceTransparency: reduceTransparency,
                    glassOpacity: glassOpacity,
                    reviewStore: reviewStore
                )
                .accessibilityIdentifier(AccessibilityID.Diff.content)
            case .error(let message):
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        // Same reasoning as `GitChangesPaneView`'s leading-edge overlay: the
        // shared `SplitDividerView` between this pane and whatever sits
        // above it is a nearly-invisible 1pt hairline, so add a slightly
        // more visible edge of our own on the side that borders the
        // terminal/changes-panel row.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityIdentifier(AccessibilityID.Diff.container)
    }
}
