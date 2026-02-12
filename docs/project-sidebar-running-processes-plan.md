# Project Sidebar Running Processes Plan

## Goal

Add a process section to the project sidebar that shows, for each project:

1. A count of active/running processes.
2. A list of active processes that are running in any tab for that project.
3. No change to the active terminal behavior in the main panel (switching projects must still keep the current terminal focus/selection behavior that already exists).

This plan is written for an agent with zero prior context.

## Scope and Constraints

- Target platform in this fork: macOS app code (`macos/Sources/...`).
- Existing project sidebar and project scoped tabs already exist in `TerminalController`.
- Do not add new persistence for process list data. It should be runtime only.
- Current public API does **not** expose process command name or PID for active processes.
- Use current process state signals only for MVP:
  - `Ghostty.SurfaceView.needsConfirmQuit`
  - `Ghostty.SurfaceView.processExited`

## Existing Architecture (What Already Exists)

### Sidebar and tab state

- `macos/Sources/Features/Terminal/BaseTerminalController.swift`
  - Owns published SwiftUI state (`projectSidebarItems`, `selectedProjectSidebarItemID`, `mainPanelTabs`, etc.).
  - Conforms to `TerminalViewModel`.

- `macos/Sources/Features/Terminal/TerminalController.swift`
  - Fork-specific project workspace logic:
    - `mainPanelTabStates: [MainPanelTabState]`
    - `mainPanelTabStatesByWorkspace: [MainPanelWorkspaceKey: [MainPanelTabState]]`
    - `selectedMainPanelTabIDByWorkspace`
  - Each `MainPanelTabState` stores a `SplitTree<Ghostty.SurfaceView>`.
  - Project switching loads the tab state for that project workspace.

- `macos/Sources/Features/Terminal/TerminalView.swift`
  - Defines `TerminalViewModel` protocol.
  - Defines `ProjectSidebarItem`, `MainPanelTabItem`.

- `macos/Sources/Features/Terminal/TerminalViewContainer.swift`
  - Renders the sidebar (`ProjectSidebarView`, `ProjectSidebarRowView`).

### Process/running semantics that already exist

- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  - `var needsConfirmQuit: Bool`
  - `var processExited: Bool`

- `src/Surface.zig` (`needsConfirmQuit`)
  - This is effectively a "unsafe to close / command still running" signal.
  - For `confirm_close_surface = true`, it returns true when cursor is not at prompt.
  - It returns false once child has exited.

This is the best available "running" signal without extending core APIs.

### Important limitation for richer labels

- `include/ghostty.h` defines `GHOSTTY_ACTION_COMMAND_FINISHED`, but `macos/Sources/Ghostty/Ghostty.App.swift` does not implement it yet.
- Therefore, do not attempt to show exact command names in MVP.

## Product Definition (MVP)

For each project row in sidebar:

1. Show a badge with running count.
2. For the selected project, show a list of running process entries below/inside the project section.

Each entry should include:

- A primary label:
  - Surface title if non-empty.
  - Else tab title fallback (`Tab N` / project name behavior already used in `TerminalController`).
- A secondary label:
  - `surface.pwd?.abbreviatedPath` if available, else empty.

## Data Model Changes

### 1) Extend terminal view model types

File: `macos/Sources/Features/Terminal/TerminalView.swift`

Add:

- `RunningProcessItem` model:
  - `id: UUID` (use `surface.id`)
  - `projectID: UUID`
  - `tabID: UUID`
  - `tabTitle: String`
  - `primaryText: String`
  - `secondaryText: String?`

Add protocol requirements to `TerminalViewModel`:

- `var runningProcessesByProjectID: [UUID: [RunningProcessItem]] { get }`
- `func runningProcessCount(for projectID: UUID) -> Int`

### 2) Add default published state at controller base layer

File: `macos/Sources/Features/Terminal/BaseTerminalController.swift`

Add:

- `@Published var runningProcessesByProjectID: [UUID: [RunningProcessItem]] = [:]`
- default helper:
  - `func runningProcessCount(for projectID: UUID) -> Int { runningProcessesByProjectID[projectID]?.count ?? 0 }`

This keeps UI bindings valid even for subclasses that do not implement a sidebar.

## Controller Implementation Plan

File: `macos/Sources/Features/Terminal/TerminalController.swift`

### 1) Add recomputation pipeline

Implement private methods:

1. `isRunningSurface(_ surface: Ghostty.SurfaceView) -> Bool`
2. `workspaceProjectID(for key: MainPanelWorkspaceKey) -> UUID?`
3. `runningItems(for workspaceKey: MainPanelWorkspaceKey, tabStates: [MainPanelTabState]) -> [RunningProcessItem]`
4. `refreshRunningProcesses()`

Rules:

- Include only project workspaces (`.project(UUID)`), not `.unscoped`.
- A surface is considered running when:
  - `surface.needsConfirmQuit == true`
  - `surface.processExited == false`
- Iterate all tabs in all project workspaces:
  - active workspace: `mainPanelTabStates`
  - stored workspaces: `mainPanelTabStatesByWorkspace`
- Walk each tab's split tree leaves (`state.surfaceTree` values).
- Build `RunningProcessItem` with stable sort:
  - by project name/path order (match `projectSidebarItems` order)
  - then by tab order
  - then by surface focus recency if available (`focusInstant`) or insertion order

### 2) Keep recomputation synchronized

Call `refreshRunningProcesses()` at all mutation points where tab/surface/workspace may change:

- End of `bootstrapProjectSidebar(...)`
- End of `bootstrapMainPanelTabs()`
- `selectProjectSidebarItem(id:)` after applying state
- `addProjectSidebarItem(path:)`
- `removeProjectSidebarItem(id:)`
- `addMainPanelTab(withBaseConfig:)`
- `closeMainPanelTabImmediately(id:)`
- `closeOtherTabsImmediately()`
- `closeTabsOnTheRightImmediately()`
- `closeLastTabInCurrentWorkspace()`
- `surfaceTreeDidChange(from:to:)`
- `syncActiveMainPanelTabState()` (or call only from callers if preferred)

### 3) Add periodic refresh for prompt transitions

Reason: running state changes when shell returns to prompt are not guaranteed to emit controller-level notifications.

Add to `TerminalController`:

- `private var runningProcessRefreshTimer: Timer?`
- start in `init` with 1 second interval on main run loop.
- stop in `deinit`.
- timer callback just calls `refreshRunningProcesses()`.

Optimization:

- In callback, compare previous and new map; publish only if changed.

## UI Plan

File: `macos/Sources/Features/Terminal/TerminalViewContainer.swift`

### 1) Sidebar row badge

In `ProjectSidebarRowView`:

- Add `runningCount: Int` input.
- Show badge at trailing side when `runningCount > 0`.
- Keep existing remove button hover behavior.

### 2) Running process list for selected project

In `ProjectSidebarView`:

- For each row:
  - compute `runningItems = viewModel.runningProcessesByProjectID[project.id] ?? []`
  - pass `runningCount`.
- If row is selected and `runningItems` non-empty, render a compact list under the row:
  - Header text: `Running`
  - One line per `RunningProcessItem`:
    - Primary text in standard font
    - Secondary text in smaller secondary style

UI constraints:

- Must not break collapsed sidebar mode.
- Must preserve existing row click and remove interactions.
- Keep list lightweight; no nested scroll region inside the row.

## Suggested Pseudocode

```swift
private func isRunningSurface(_ surface: Ghostty.SurfaceView) -> Bool {
    surface.needsConfirmQuit && !surface.processExited
}

private func refreshRunningProcesses() {
    var result: [UUID: [RunningProcessItem]] = [:]

    func consume(workspaceKey: MainPanelWorkspaceKey, states: [MainPanelTabState]) {
        guard let projectID = workspaceProjectID(for: workspaceKey) else { return }
        for (tabIndex, state) in states.enumerated() {
            let tabTitle = tabTitle(for: state, index: tabIndex)
            for surface in state.surfaceTree where isRunningSurface(surface) {
                let primary = !surface.title.isEmpty ? surface.title : tabTitle
                let secondary = surface.pwd?.abbreviatedPath
                result[projectID, default: []].append(.init(
                    id: surface.id,
                    projectID: projectID,
                    tabID: state.id,
                    tabTitle: tabTitle,
                    primaryText: primary,
                    secondaryText: secondary
                ))
            }
        }
    }

    consume(workspaceKey: activeMainPanelWorkspaceKey, states: mainPanelTabStates)
    for (key, states) in mainPanelTabStatesByWorkspace where key != activeMainPanelWorkspaceKey {
        consume(workspaceKey: key, states: states)
    }

    if runningProcessesByProjectID != result {
        runningProcessesByProjectID = result
    }
}
```

## Validation Checklist

1. Add two projects A and B.
2. In A:
   - Tab 1 idle prompt.
   - Tab 2 running command (`sleep 999`).
   - Expect A badge `1`, one running entry.
3. In B:
   - two running commands across different tabs/splits.
   - Expect B badge `2`.
4. Switch projects repeatedly:
   - Active main panel tab switching behavior remains unchanged.
5. Close running tab:
   - Existing close confirmation still appears.
   - Sidebar count updates immediately after close.
6. Command completes naturally:
   - Within <= 1 second timer tick, running entry disappears.
7. Remove selected project:
   - No stale running entries for removed project.
8. Collapsed sidebar:
   - No layout regressions.

## Build/Test Steps

Run:

```bash
zig build
zig build test
```

Manual UI verification is required because this is sidebar rendering/state behavior.

## Risks and Mitigations

1. Risk: recompute too often.
   - Mitigation: compare old/new maps before publishing.
2. Risk: duplicate entries when state exists in active and cached maps.
   - Mitigation: skip cached map for `activeMainPanelWorkspaceKey`.
3. Risk: unscoped workspace leakage into project counts.
   - Mitigation: include only `.project(UUID)` keys.

## Non-Goals (MVP)

- Exact command string/PID display.
- Cross-window global aggregation of project process counts.
- Persisting process list across app restarts.

## Future Phase (Optional)

If richer process metadata is required:

1. Implement command lifecycle actions in `macos/Sources/Ghostty/Ghostty.App.swift` for `GHOSTTY_ACTION_COMMAND_FINISHED` (and related start action if available).
2. Add app notifications carrying command metadata.
3. Track foreground command per surface in `SurfaceView`.
4. Replace MVP labels with command-aware labels.

