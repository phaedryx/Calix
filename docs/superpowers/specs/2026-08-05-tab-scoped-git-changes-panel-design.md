# Tab-scoped git changes panel (design)

## Problem

The "Changes" sidebar and diff review are currently modeled as window-level
state with diff tabs as top-level siblings in the tab strip:

- `WindowSession` owns a single `gitEntries`/`branchDeltaEntries`/
  `gitChangesState`/`repoRoots`/`currentRepoRoot` for the *whole window*,
  regardless of how many terminal tabs (and repos) are open in it.
- Opening a changed file creates a brand-new `Tab` with `content: .diff(source:)`,
  appended as a sibling in `TabGroup.tabs` next to whatever terminal tab was
  active.
- Submitting review comments has to guess a destination terminal tab, because
  nothing links the diff tab back to the terminal tab it was opened from.

This produced two related bug classes, both fixed ad hoc this session:

1. `findWorkDir()` used to fall back to "any terminal tab in the group" to
   guess a diff's repo root — patched with `currentRepoRoot`, a single cached
   value on `GitChangesController`.
2. `sendReviewToAgent` used to fall back to "any agent-titled tab in the
   window" to guess a review's destination — patched with
   `diffOriginTabIDs: [UUID: UUID]`, a side-table on `GitChangesController`.

Both patches exist because "which repo/tab does this diff belong to" isn't
represented as a real relationship anywhere near `Tab`. Two different
features independently invented two different side-tables to route around
the same missing structure.

## Goal

Make git changes/diff review a per-tab concept, expressed as panes inside
the owning tab's existing `SplitTree`, instead of window-level state plus
sibling tabs plus side-tables. Layout target (user-specified):

```
[ terminal          ][ changes list ]
[ diff ][ diff ][ diff ]
```

## Why this fits the existing architecture

Two facts, verified by reading the code, make this a natural fit rather than
a new mechanism bolted onto old machinery:

- **`SplitTree` is already content-agnostic.** Its leaves are bare
  `.leaf(id: UUID)` (`Calix/Models/SplitTree.swift`) — nothing in the type
  references ghostty or terminal surfaces. The "leaf = terminal surface"
  association is imposed entirely externally, by `Tab.registry:
  SurfaceRegistry` (a separate UUID → surface map). Adding non-terminal leaf
  kinds requires no change to `SplitTree` itself.
- **Per-leaf close already exists**, independent of whole-tab close:
  `closeSurfaceAndCleanUp(tab:group:surfaceID:)` (`CalixWindowController.swift`)
  removes one leaf from a tab's tree today (used when a shell process exits
  from a split) without closing the tab. Closing an individual diff/changes
  pane generalizes this — it isn't new machinery.
- **Divider resize already works generically.** `SplitContainerView`/
  `SplitDividerView` render a draggable divider for any `SplitNode.split(...)`
  and call `setRatio` on drag, with no awareness of what either side
  contains. Changes/diff panes get resizable dividers for free.

## Data model

- `Tab` gains:
  ```swift
  var paneContent: [UUID: TabPaneKind] = [:]
  ```
  where `TabPaneKind` is `.gitChanges` or `.diff(source: DiffSource)`. A
  `splitTree` leaf present in this map renders as that pane; a leaf absent
  from it falls back to `registry` (today's only case — a terminal surface).
- `Tab` gains its own git-changes state, scoped to that tab's own repo:
  `gitEntries`, `branchDeltaEntries`, `gitChangesState`, `repoRoot`. These
  move off `WindowSession` (today they're window-wide, shared regardless of
  which tab/repo is active).
- `WindowSession.sidebarMode` and its `.changes` case are deleted. The left
  sidebar only ever shows tabs/groups; there is no separate "Changes" sidebar
  destination.
- `TabContent.diff(source:)` is deleted. Diff is never a whole tab's content
  anymore, only a pane inside a `.terminal` tab.
- `GitChangesController.diffOriginTabIDs`, the `currentRepoRoot`
  cross-tab-ambiguity guard, and `CalixWindowController.sendReviewToAgent`'s
  title-scanning fallback (`agentTabCandidates`, the multi-tab picker) are all
  **deleted, not migrated** — there is no separate tab to search for or point
  back to once a diff is a pane inside its own tab.

## Lifecycle

- **Open changes panel**: a per-tab toggle inserts a `.gitChanges` leaf via
  `splitTree.insert(at: <a terminal leaf>, direction: .horizontal)`. Toggling
  off removes it (`splitTree.remove`, which already handles collapse and
  refocus).
- **Open a diff**: clicking a file in the changes panel inserts a
  `.diff(source:)` leaf into the bottom row. Deduped by `DiffSource` equality,
  same as today's `openDiffTab` dedup — clicking an already-open file refocuses
  its existing leaf instead of duplicating it.
- **Close one pane**: generalizes `closeSurfaceAndCleanUp`'s pattern — if the
  leaf has a `paneContent` entry, skip ghostty teardown, remove it from
  `paneContent`, and call `splitTree.remove(leafID)`. Shows today's "Unsent
  Review Comments" alert if that specific diff pane has unsubmitted comments.
- **Close the tab**: mechanically unchanged (`tearDownSurfaces` +
  `removeTab`), but the pre-close check now scans every diff pane in the
  tab's tree for unsent comments (not one tracked diff-tab ID), and the
  warning message reports the total comment/file count across the whole tab.
  Closing the tab tears down its whole `SplitTree`, so every changes/diff pane
  goes with it — cascade-close falls out of reusing the existing tree, no
  special-case code required.
- **Submit a review**: no destination search. The target is always the
  terminal leaf(s) in the *same tab* as the diff pane. Exactly one terminal
  leaf → send there. Multiple (the tab itself is split into several
  terminals) → reuse today's picker UI, but scoped to this tab's own leaves
  only, never other tabs or groups.
- **Submit all**: becomes tab-scoped by construction — "all" now means every
  diff pane open in the *current* tab, submitted in one payload to that same
  tab's terminal leaf(s). There is no window-wide "submit every diff
  anywhere" anymore, since review state no longer spans tabs.

## Refresh / monitoring

One shared `GitChangesMonitor`/refresh pipeline per window, retargeted to
whichever tab is currently active — not one file-watcher per open changes
panel. Background tabs keep their last-cached `gitEntries` in memory. On
activating a tab whose changes panel is open, its cached entries render
immediately (no loading flash) and a refresh fires in the background,
updating the list when it completes. This avoids N simultaneous watchers, at
the cost of a background tab's panel not updating live while unfocused.

## Persistence

Changes/diff panes stay ephemeral: dropped on snapshot and not recreated on
restore, matching today's behavior (diff tabs are currently dropped from
snapshots entirely). No changes to `SessionSnapshot`'s shape beyond removing
whatever encoded the old `.diff` `TabContent` case.

## Testing

`DiffTabLifecycleTests.swift`'s scratch-git-repo fixture pattern still
applies, but assertions move from "a new `Tab` was appended to `group.tabs`"
to "a new leaf was inserted into `tab.splitTree` with a matching
`paneContent` entry." `submitDiffReview_targetsOriginTab_notGlobalScan`
(added this session) is deleted — there is no origin tab to target once a
diff is a pane inside its own tab — and replaced with a same-tab
multiple-terminal-leaves picker test.

## Explicitly out of scope

- Moving a tab between groups (no such feature exists today; confirmed no
  design implication since diff tabs never cross groups either way).
- Any tab type other than `.terminal` hosting a changes panel (browser tabs
  have no repo context).
- Live/independent monitoring per open changes panel (see Refresh/monitoring
  above — flagged as a recommendation, not a hard requirement, if it turns
  out background-tab staleness is a problem in practice).
