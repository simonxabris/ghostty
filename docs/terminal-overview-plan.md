# Terminal Overview Command Plan

## Goal

Implement a command-driven, Safari-style overview in Ghostty on macOS that shows all open terminals (across projects and windows) as mini window cards, and lets the user switch directly to any terminal.

## Product Target

- Trigger via `toggle_tab_overview`.
- Display a dimmed overlay with a grid of terminal cards.
- Include terminals from:
  - the active workspace,
  - stored workspaces in the project sidebar model,
  - all open Ghostty terminal windows/controllers.
- Selecting a card focuses that terminal (and switches project/tab/window as needed).
- `Esc` closes the overlay.

## Implementation Phases

### Phase 1: Command plumbing

1. Implement `GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW` in:
   - `macos/Sources/Ghostty/Ghostty.App.swift`
2. Add a dedicated notification in:
   - `macos/Sources/Ghostty/Package.swift`
   - Example: `ghosttyToggleTabOverview`
3. Remove `"toggle_tab_overview"` from unsupported command keys in:
   - `macos/Sources/Ghostty/Ghostty.Command.swift`

### Phase 2: View-model and state

1. Extend terminal view model state in:
   - `macos/Sources/Features/Terminal/TerminalView.swift`
   - `macos/Sources/Features/Terminal/BaseTerminalController.swift`
2. Add:
   - `terminalOverviewIsShowing: Bool`
   - `TerminalOverviewItem` model with:
     - `projectID`
     - `tabID`
     - `surfaceID`
     - title/cwd/status metadata
     - thumbnail reference/cache key
3. In:
   - `macos/Sources/Features/Terminal/TerminalController.swift`
   add a collector that merges:
   - active `mainPanelTabStates`
   - `mainPanelTabStatesByWorkspace`
   - `TerminalController.all` windows/controllers

### Phase 3: Thumbnail capture

1. Use existing surface snapshot support:
   - `macos/Sources/Ghostty/Surface View/SurfaceView+Image.swift`
2. Add a thumbnail cache keyed by surface UUID.
3. Downscale snapshots for performance.
4. Fallback behavior:
   - If snapshot unavailable, render metadata card (title + cwd + running/idle).

### Phase 4: Overlay UI

1. Add a new SwiftUI overview view in:
   - `macos/Sources/Features/Terminal/` (new file)
2. Mount overlay in:
   - `macos/Sources/Features/Terminal/TerminalView.swift`
3. UX layout:
   - Dimmed background
   - Adaptive card grid
   - Card chrome/header similar to mini-window treatment
   - Optional search/filter bar (MVP optional)
4. Interactions:
   - Click card => activate destination terminal
   - `Esc` => dismiss overview

### Phase 5: Focus and switching logic

1. Add a direct activation helper in:
   - `macos/Sources/Features/Terminal/TerminalController.swift`
2. Activation algorithm:
   - Resolve project -> tab -> surface.
   - If in same controller, switch and focus directly.
   - If in different controller/window, bring that window front and focus surface.
3. Keep existing focus semantics:
   - Preserve current behavior for normal project switching and tab selection.

### Phase 6: Validation

1. Manual validation matrix:
   - Multiple projects
   - Multiple tabs per project
   - Split surfaces
   - Multiple windows
   - Running + idle processes
2. Verify no regression:
   - Existing project sidebar behavior remains intact.
   - Existing close/confirm and focus behaviors remain intact.
3. Run test suite:
   - `zig build test`

## Design Decision (MVP)

- Card granularity: **one card per terminal surface** (split-aware).
- Alternative (future): one card per tab, with split indicators.

## Known Constraints

- Some terminals may be non-visible/offscreen at capture time; fallback cards are required.
- `toggle_tab_overview` currently exists in core action space and should be reused rather than introducing a new action.

## Deliverables

1. Action support wired end-to-end on macOS.
2. New terminal overview overlay UI.
3. Cross-project and cross-window terminal switching from overview.
4. Basic thumbnail cache with fallback rendering.
