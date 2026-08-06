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
    let themeColor: NSColor
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?

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
                onDiscardAllReviews: onDiscardAllReviews
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
        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
        .accessibilityIdentifier(AccessibilityID.Diff.container)
    }
}
