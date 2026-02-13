import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    private static let projectSidebarStorageKey = "com.mitchellh.ghostty.projects.sidebar.v1"

    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"
        
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.ghostty.config
        
        // If we have no window decorations, there's no reason to do anything but
        // the default titlebar (because there will be no titlebar).
        if !config.windowDecorations {
            return defaultValue
        }
        
        let nib = switch config.macosTitlebarStyle {
        case "native": "Terminal"
        case "hidden": "TerminalHiddenTitlebar"
        case "transparent": "TerminalTransparentTitlebar"
        case "tabs":
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                "TerminalTabsTitlebarTahoe"
            } else {
                "TerminalTabsTitlebarVentura"
            }
#else
            "TerminalTabsTitlebarVentura"
#endif
        default: defaultValue
        }
        
        return nib
    }
    
    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false
    
    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0
    
    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// Stable identifier for overview routing.
    private let controllerID = UUID()
    
    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig
    
    
    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []
    
    /// This will be set to the initial frame of the window from the xib on load.
    private var initialFrame: NSRect? = nil

    private struct MainPanelTabState {
        var id: UUID
        var surfaceTree: SplitTree<Ghostty.SurfaceView>
    }

    private enum MainPanelWorkspaceKey: Hashable {
        case project(UUID)
        case unscoped
    }

    private var mainPanelTabStates: [MainPanelTabState] = []
    private var mainPanelTabStatesByWorkspace: [MainPanelWorkspaceKey: [MainPanelTabState]] = [:]
    private var selectedMainPanelTabIDByWorkspace: [MainPanelWorkspaceKey: UUID] = [:]
    private var runningProcessRefreshTimer: Timer?

    /// Cache terminal overview thumbnails by surface UUID.
    private var terminalOverviewThumbnailCache: [UUID: NSImage] = [:]

    override var showsProjectSidebar: Bool { true }

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""
        
        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)
        
        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        bootstrapProjectSidebar(
            withBaseConfig: base,
            preserveCurrentSurfaceTree: tree != nil
        )
        bootstrapMainPanelTabs()
        
        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoProject),
            name: Ghostty.Notification.ghosttyGotoProject,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onToggleTabOverview),
            name: Ghostty.Notification.ghosttyToggleTabOverview,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )

        startRunningProcessRefreshTimer()
        refreshRunningProcesses()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }
    
    deinit {
        runningProcessRefreshTimer?.invalidate()
        runningProcessRefreshTimer = nil

        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }
    
    // MARK: Base Controller Overrides
    
    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        
        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
        
        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        if !to.isEmpty {
            syncActiveMainPanelTabState()
            refreshMainPanelTabs()
            refreshRunningProcesses()
            return
        }

        refreshRunningProcesses()
        closeTabImmediately()
    }
    
    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }
        
        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    override func selectProjectSidebarItem(id: UUID) {
        refreshProjectSidebarGitBranches(for: [id])
        guard selectedProjectSidebarItemID != id else { return }
        guard let project = projectSidebarItems.first(where: { $0.id == id }) else { return }

        let nextWorkspaceKey = workspaceKey(for: id)
        let nextWorkspaceStates = mainPanelTabStatesByWorkspace[nextWorkspaceKey]
        let nextSelectedTabID = selectedMainPanelTabIDByWorkspace[nextWorkspaceKey]

        if let nextWorkspaceStates, !nextWorkspaceStates.isEmpty {
            syncActiveMainPanelTabState()
            selectedProjectSidebarItemID = id
            mainPanelTabStates = nextWorkspaceStates
            if let nextSelectedTabID,
               nextWorkspaceStates.contains(where: { $0.id == nextSelectedTabID }) {
                selectedMainPanelTabID = nextSelectedTabID
            } else {
                selectedMainPanelTabID = nextWorkspaceStates.first?.id
            }
            applySelectedMainPanelTabState()
            persistCurrentMainPanelWorkspaceState()
            refreshMainPanelTabs()
            refreshRunningProcesses()
            return
        }

        guard let createdTree = makeProjectSurfaceTree(for: project) else { return }
        syncActiveMainPanelTabState()
        selectedProjectSidebarItemID = id
        let initialState = MainPanelTabState(id: UUID(), surfaceTree: createdTree)
        mainPanelTabStates = [initialState]
        selectedMainPanelTabID = initialState.id
        activateProjectSurfaceTree(createdTree)
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    override func addProjectSidebarItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Add Project"
        panel.message = "Choose a directory to add to the project sidebar."
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProjectSidebarItem(path: url.path)
    }

    override func removeProjectSidebarItem(id: UUID) {
        guard let removeIndex = projectSidebarItems.firstIndex(where: { $0.id == id }) else { return }

        let removedWorkspaceKey = workspaceKey(for: id)
        let isRemovingSelectedProject = selectedProjectSidebarItemID == id

        if isRemovingSelectedProject {
            syncActiveMainPanelTabState()
        }

        projectSidebarItems.remove(at: removeIndex)
        Self.persistProjectSidebarItems(projectSidebarItems)

        mainPanelTabStatesByWorkspace.removeValue(forKey: removedWorkspaceKey)
        selectedMainPanelTabIDByWorkspace.removeValue(forKey: removedWorkspaceKey)

        if isRemovingSelectedProject {
            selectedProjectSidebarItemID = nil
            mainPanelTabStatesByWorkspace[.unscoped] = mainPanelTabStates
            if let selectedMainPanelTabID {
                selectedMainPanelTabIDByWorkspace[.unscoped] = selectedMainPanelTabID
            } else {
                selectedMainPanelTabIDByWorkspace.removeValue(forKey: .unscoped)
            }
        }

        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    override func addMainPanelTab() {
        addMainPanelTab(withBaseConfig: nil)
    }

    override func selectMainPanelTab(id: UUID) {
        guard selectedMainPanelTabID != id else { return }
        guard let state = mainPanelTabStates.first(where: { $0.id == id }) else { return }

        syncActiveMainPanelTabState()
        selectedMainPanelTabID = id
        applyMainPanelTabState(state)
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
    }

    override func closeMainPanelTab(id: UUID) {
        guard let state = mainPanelTabStates.first(where: { $0.id == id }) else { return }

        if id == selectedMainPanelTabID {
            closeTab(nil)
            return
        }

        if !tabNeedsCloseConfirmation(state) {
            closeMainPanelTabImmediately(id: id)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeMainPanelTabImmediately(id: id)
        }
    }

    private func bootstrapProjectSidebar(
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?,
        preserveCurrentSurfaceTree: Bool
    ) {
        var storedProjects = Self.loadPersistedProjectSidebarItems()
        let startupPath = normalizedProjectPath(baseConfig?.workingDirectory ?? "")
        var startupProject: ProjectSidebarItem?

        if !startupPath.isEmpty {
            if let existingProject = storedProjects.first(
                where: { projectPathKey($0.path) == projectPathKey(startupPath) }
            ) {
                startupProject = existingProject
            } else {
                let newProject = ProjectSidebarItem(
                    id: UUID(),
                    name: projectNameFromPath(startupPath),
                    path: startupPath
                )
                storedProjects.append(newProject)
                Self.persistProjectSidebarItems(storedProjects)
                startupProject = newProject
            }
        }

        projectSidebarItems = storedProjects
        refreshProjectSidebarGitBranches()

        if preserveCurrentSurfaceTree {
            if let startupProject {
                selectedProjectSidebarItemID = startupProject.id
            }
            refreshRunningProcesses()
            return
        }

        guard let initialProject = startupProject ?? storedProjects.first else {
            selectedProjectSidebarItemID = nil
            refreshRunningProcesses()
            return
        }

        selectedProjectSidebarItemID = initialProject.id

        if !startupPath.isEmpty {
            refreshRunningProcesses()
            return
        }

        guard let initialTree = makeProjectSurfaceTree(for: initialProject) else {
            refreshRunningProcesses()
            return
        }
        activateProjectSurfaceTree(initialTree)
        refreshRunningProcesses()
    }

    private func bootstrapMainPanelTabs() {
        let initialState = MainPanelTabState(
            id: UUID(),
            surfaceTree: surfaceTree
        )
        mainPanelTabStates = [initialState]
        selectedMainPanelTabID = initialState.id
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    private func selectedMainPanelTabIndex() -> Int? {
        guard let selectedMainPanelTabID else { return nil }
        return mainPanelTabStates.firstIndex(where: { $0.id == selectedMainPanelTabID })
    }

    private func workspaceKey(for projectID: UUID?) -> MainPanelWorkspaceKey {
        if let projectID {
            return .project(projectID)
        }

        return .unscoped
    }

    private var activeMainPanelWorkspaceKey: MainPanelWorkspaceKey {
        workspaceKey(for: selectedProjectSidebarItemID)
    }

    private func startRunningProcessRefreshTimer() {
        runningProcessRefreshTimer?.invalidate()
        runningProcessRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshRunningProcesses()
        }
    }

    private func isRunningSurface(_ surface: Ghostty.SurfaceView) -> Bool {
        surface.needsConfirmQuit && !surface.processExited
    }

    private func workspaceProjectID(for key: MainPanelWorkspaceKey) -> UUID? {
        switch key {
        case .project(let projectID):
            return projectID
        case .unscoped:
            return nil
        }
    }

    private func runningItems(
        for workspaceKey: MainPanelWorkspaceKey,
        tabStates: [MainPanelTabState]
    ) -> [RunningProcessItem] {
        guard let projectID = workspaceProjectID(for: workspaceKey) else { return [] }

        struct Candidate {
            var item: RunningProcessItem
            var tabIndex: Int
            var surfaceOrder: Int
            var focusInstant: ContinuousClock.Instant?
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(tabStates.count)

        for (tabIndex, state) in tabStates.enumerated() {
            let tabTitle: String = {
                if let surface = state.surfaceTree.root?.leftmostLeaf() {
                    if !surface.title.isEmpty {
                        return surface.title
                    }

                    if let pwd = surface.pwd?.abbreviatedPath, !pwd.isEmpty {
                        return pwd
                    }
                }

                if tabStates.count == 1,
                   let project = projectSidebarItems.first(where: { $0.id == projectID }) {
                    return project.name
                }

                return "Tab \(tabIndex + 1)"
            }()

            for (surfaceOrder, surface) in state.surfaceTree.enumerated() where isRunningSurface(surface) {
                let primaryText = surface.title.isEmpty ? tabTitle : surface.title
                let secondaryText = surface.pwd?.abbreviatedPath
                candidates.append(.init(
                    item: .init(
                        id: surface.id,
                        projectID: projectID,
                        tabID: state.id,
                        tabTitle: tabTitle,
                        primaryText: primaryText,
                        secondaryText: secondaryText
                    ),
                    tabIndex: tabIndex,
                    surfaceOrder: surfaceOrder,
                    focusInstant: surface.focusInstant
                ))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.tabIndex != rhs.tabIndex {
                return lhs.tabIndex < rhs.tabIndex
            }

            switch (lhs.focusInstant, rhs.focusInstant) {
            case let (l?, r?) where l != r:
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            return lhs.surfaceOrder < rhs.surfaceOrder
        }

        return candidates.map(\.item)
    }

    private func refreshRunningProcesses() {
        var statesByWorkspace = mainPanelTabStatesByWorkspace
        statesByWorkspace[activeMainPanelWorkspaceKey] = mainPanelTabStates

        var result: [UUID: [RunningProcessItem]] = [:]
        var visitedProjects: Set<UUID> = []

        for project in projectSidebarItems {
            let workspaceKey: MainPanelWorkspaceKey = .project(project.id)
            guard let states = statesByWorkspace[workspaceKey], !states.isEmpty else { continue }
            let items = runningItems(for: workspaceKey, tabStates: states)
            if !items.isEmpty {
                result[project.id] = items
            }
            visitedProjects.insert(project.id)
        }

        let extraProjectKeys = statesByWorkspace.keys.compactMap { key -> UUID? in
            guard case .project(let projectID) = key else { return nil }
            guard !visitedProjects.contains(projectID) else { return nil }
            return projectID
        }.sorted { $0.uuidString < $1.uuidString }

        for projectID in extraProjectKeys {
            let workspaceKey: MainPanelWorkspaceKey = .project(projectID)
            guard let states = statesByWorkspace[workspaceKey], !states.isEmpty else { continue }
            let items = runningItems(for: workspaceKey, tabStates: states)
            if !items.isEmpty {
                result[projectID] = items
            }
        }

        if runningProcessesByProjectID != result {
            runningProcessesByProjectID = result
        }
    }

    private func persistCurrentMainPanelWorkspaceState() {
        let key = activeMainPanelWorkspaceKey
        mainPanelTabStatesByWorkspace[key] = mainPanelTabStates
        if let selectedMainPanelTabID {
            selectedMainPanelTabIDByWorkspace[key] = selectedMainPanelTabID
        } else {
            selectedMainPanelTabIDByWorkspace.removeValue(forKey: key)
        }
    }

    private func syncActiveMainPanelTabState() {
        guard let index = selectedMainPanelTabIndex() else { return }
        mainPanelTabStates[index].surfaceTree = surfaceTree
        persistCurrentMainPanelWorkspaceState()
        refreshRunningProcesses()
    }

    private func applyMainPanelTabState(_ state: MainPanelTabState) {
        activateProjectSurfaceTree(state.surfaceTree)
    }

    private func applySelectedMainPanelTabState() {
        guard let selectedMainPanelTabID,
              let state = mainPanelTabStates.first(where: { $0.id == selectedMainPanelTabID }) else { return }
        applyMainPanelTabState(state)
    }

    private func tabTitle(for state: MainPanelTabState, index: Int) -> String {
        if let surface = state.surfaceTree.root?.leftmostLeaf() {
            if !surface.title.isEmpty {
                return surface.title
            }

            if let pwd = surface.pwd?.abbreviatedPath, !pwd.isEmpty {
                return pwd
            }
        }

        if mainPanelTabStates.count == 1,
           let selectedProjectSidebarItemID,
           let project = projectSidebarItems.first(where: { $0.id == selectedProjectSidebarItemID }) {
            return project.name
        }

        return "Tab \(index + 1)"
    }

    private func refreshMainPanelTabs() {
        mainPanelTabs = mainPanelTabStates.enumerated().map { index, state in
            MainPanelTabItem(id: state.id, title: tabTitle(for: state, index: index))
        }
    }

    private func projectName(for projectID: UUID?) -> String? {
        guard let projectID else { return nil }
        return projectSidebarItems.first(where: { $0.id == projectID })?.name
    }

    private func allWorkspaceTabStates() -> [(projectID: UUID?, states: [MainPanelTabState], selectedTabID: UUID?)] {
        var statesByWorkspace = mainPanelTabStatesByWorkspace
        statesByWorkspace[activeMainPanelWorkspaceKey] = mainPanelTabStates

        var result: [(projectID: UUID?, states: [MainPanelTabState], selectedTabID: UUID?)] = []
        var seenKeys: Set<MainPanelWorkspaceKey> = []

        let activeKey = activeMainPanelWorkspaceKey
        if let states = statesByWorkspace[activeKey], !states.isEmpty {
            let selectedID = selectedMainPanelTabIDByWorkspace[activeKey] ?? selectedMainPanelTabID
            result.append((workspaceProjectID(for: activeKey), states, selectedID))
            seenKeys.insert(activeKey)
        }

        for project in projectSidebarItems {
            let key: MainPanelWorkspaceKey = .project(project.id)
            guard !seenKeys.contains(key),
                  let states = statesByWorkspace[key],
                  !states.isEmpty else { continue }
            result.append((project.id, states, selectedMainPanelTabIDByWorkspace[key]))
            seenKeys.insert(key)
        }

        if !seenKeys.contains(.unscoped),
           let states = statesByWorkspace[.unscoped],
           !states.isEmpty {
            result.append((nil, states, selectedMainPanelTabIDByWorkspace[.unscoped]))
            seenKeys.insert(.unscoped)
        }

        for (key, states) in statesByWorkspace where !seenKeys.contains(key) {
            guard !states.isEmpty else { continue }
            result.append((workspaceProjectID(for: key), states, selectedMainPanelTabIDByWorkspace[key]))
            seenKeys.insert(key)
        }

        return result
    }

    private func tabTitle(
        for state: MainPanelTabState,
        tabIndex: Int,
        workspaceProjectID: UUID?,
        stateCount: Int
    ) -> String {
        if let surface = state.surfaceTree.root?.leftmostLeaf() {
            if !surface.title.isEmpty {
                return surface.title
            }

            if let pwd = surface.pwd?.abbreviatedPath, !pwd.isEmpty {
                return pwd
            }
        }

        if stateCount == 1,
           let projectID = workspaceProjectID,
           let project = projectSidebarItems.first(where: { $0.id == projectID }) {
            return project.name
        }

        return "Tab \(tabIndex + 1)"
    }

    private func terminalOverviewThumbnail(for surface: Ghostty.SurfaceView) -> NSImage? {
        if let cached = terminalOverviewThumbnailCache[surface.id] {
            return cached
        }

        guard let snapshot = surface.asImage else { return nil }
        let scaled = downscaleTerminalOverviewImage(snapshot, maxDimension: 520)
        terminalOverviewThumbnailCache[surface.id] = scaled
        return scaled
    }

    private func downscaleTerminalOverviewImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }

        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }

        let targetSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let output = NSImage(size: targetSize)
        output.lockFocus()
        defer { output.unlockFocus() }
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        return output
    }

    private func collectTerminalOverviewItems() -> [TerminalOverviewItem] {
        for controller in TerminalController.all {
            controller.syncActiveMainPanelTabState()
        }

        var items: [TerminalOverviewItem] = []
        items.reserveCapacity(64)

        for controller in TerminalController.all {
            let workspaceStates = controller.allWorkspaceTabStates()

            for workspaceState in workspaceStates {
                for (tabIndex, tabState) in workspaceState.states.enumerated() {
                    let tabTitle = controller.tabTitle(
                        for: tabState,
                        tabIndex: tabIndex,
                        workspaceProjectID: workspaceState.projectID,
                        stateCount: workspaceState.states.count
                    )

                    for surface in tabState.surfaceTree {
                        let title: String = {
                            if !surface.title.isEmpty {
                                return surface.title
                            }

                            if let cwd = surface.pwd?.abbreviatedPath, !cwd.isEmpty {
                                return cwd
                            }

                            return tabTitle
                        }()

                        let status: TerminalOverviewItem.Status = (surface.needsConfirmQuit && !surface.processExited) ? .running : .idle
                        let cwd = surface.pwd?.abbreviatedPath
                        let projectName = controller.projectName(for: workspaceState.projectID)

                        items.append(.init(
                            id: UUID(),
                            controllerID: controller.controllerID,
                            projectID: workspaceState.projectID,
                            tabID: tabState.id,
                            surfaceID: surface.id,
                            title: title,
                            cwd: cwd,
                            projectName: projectName,
                            tabTitle: tabTitle,
                            status: status,
                            thumbnail: controller.terminalOverviewThumbnail(for: surface)
                        ))
                    }
                }
            }
        }

        items.sort { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .running
            }

            let lhsProject = lhs.projectName ?? ""
            let rhsProject = rhs.projectName ?? ""
            if lhsProject != rhsProject {
                return lhsProject.localizedCaseInsensitiveCompare(rhsProject) == .orderedAscending
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return items
    }

    private func makeMainPanelSurfaceTree(
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?
    ) -> SplitTree<Ghostty.SurfaceView>? {
        guard let ghosttyApp = ghostty.app else { return nil }
        var config = baseConfig ?? Ghostty.SurfaceConfiguration()

        if let selectedProjectID = selectedProjectSidebarItemID,
           let selectedProject = projectSidebarItems.first(where: { $0.id == selectedProjectID }) {
            config.workingDirectory = selectedProject.path
        }

        return .init(view: Ghostty.SurfaceView(ghosttyApp, baseConfig: config))
    }

    private func addMainPanelTab(withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?) {
        guard let newTree = makeMainPanelSurfaceTree(withBaseConfig: baseConfig) else { return }

        syncActiveMainPanelTabState()

        let newTab = MainPanelTabState(
            id: UUID(),
            surfaceTree: newTree
        )

        mainPanelTabStates.append(newTab)
        selectedMainPanelTabID = newTab.id
        activateProjectSurfaceTree(newTree)
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closeMainPanelTabImmediately(id: UUID) {
        guard let index = mainPanelTabStates.firstIndex(where: { $0.id == id }) else { return }
        guard mainPanelTabStates.count > 1 else {
            if totalMainPanelTabCount() > 1 {
                closeLastTabInCurrentWorkspace()
                return
            }
            closeWindow(nil)
            return
        }

        syncActiveMainPanelTabState()
        let wasSelected = selectedMainPanelTabID == id
        mainPanelTabStates.remove(at: index)

        if wasSelected {
            let nextIndex = min(index, mainPanelTabStates.count - 1)
            let nextTab = mainPanelTabStates[nextIndex]
            selectedMainPanelTabID = nextTab.id
            applyMainPanelTabState(nextTab)
        }

        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    private func tabNeedsCloseConfirmation(_ state: MainPanelTabState) -> Bool {
        state.surfaceTree.contains(where: { $0.needsConfirmQuit })
    }

    private func allMainPanelTabStates() -> [MainPanelTabState] {
        var allStates: [MainPanelTabState] = mainPanelTabStates
        for (key, states) in mainPanelTabStatesByWorkspace where key != activeMainPanelWorkspaceKey {
            allStates.append(contentsOf: states)
        }
        return allStates
    }

    private func totalMainPanelTabCount() -> Int {
        allMainPanelTabStates().count
    }

    private func anyMainPanelTabNeedsCloseConfirmation() -> Bool {
        allMainPanelTabStates().contains(where: tabNeedsCloseConfirmation(_:))
    }

    private func nextWorkspaceKey(afterClosing keyToRemove: MainPanelWorkspaceKey) -> MainPanelWorkspaceKey? {
        for project in projectSidebarItems {
            let candidate: MainPanelWorkspaceKey = .project(project.id)
            guard candidate != keyToRemove else { continue }
            if let states = mainPanelTabStatesByWorkspace[candidate], !states.isEmpty {
                return candidate
            }
        }

        if keyToRemove != .unscoped,
           let states = mainPanelTabStatesByWorkspace[.unscoped], !states.isEmpty {
            return .unscoped
        }

        for (candidate, states) in mainPanelTabStatesByWorkspace where candidate != keyToRemove {
            if !states.isEmpty {
                return candidate
            }
        }

        return nil
    }

    private func closeLastTabInCurrentWorkspace() {
        let closingWorkspace = activeMainPanelWorkspaceKey
        mainPanelTabStatesByWorkspace.removeValue(forKey: closingWorkspace)
        selectedMainPanelTabIDByWorkspace.removeValue(forKey: closingWorkspace)

        guard let nextWorkspace = nextWorkspaceKey(afterClosing: closingWorkspace),
              let nextStates = mainPanelTabStatesByWorkspace[nextWorkspace],
              !nextStates.isEmpty else {
            closeWindow(nil)
            return
        }

        switch nextWorkspace {
        case .project(let projectID):
            selectedProjectSidebarItemID = projectID
        case .unscoped:
            selectedProjectSidebarItemID = nil
        }

        mainPanelTabStates = nextStates
        if let restoredTabID = selectedMainPanelTabIDByWorkspace[nextWorkspace],
           nextStates.contains(where: { $0.id == restoredTabID }) {
            selectedMainPanelTabID = restoredTabID
        } else {
            selectedMainPanelTabID = nextStates.first?.id
        }
        applySelectedMainPanelTabState()
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    private func activateProjectSurfaceTree(_ tree: SplitTree<Ghostty.SurfaceView>) {
        let previousFocusedSurface = focusedSurface
        surfaceTree = tree
        let targetSurface = tree.root?.leftmostLeaf()
        focusedSurface = targetSurface
        if let targetSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: targetSurface, from: previousFocusedSurface)
            }
        }
    }

    private func makeProjectSurfaceTree(for project: ProjectSidebarItem) -> SplitTree<Ghostty.SurfaceView>? {
        guard let ghosttyApp = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = project.path
        return .init(view: Ghostty.SurfaceView(ghosttyApp, baseConfig: config))
    }

    private func addProjectSidebarItem(path: String) {
        let normalizedPath = normalizedProjectPath(path)
        guard !normalizedPath.isEmpty else { return }

        if let existingProject = projectSidebarItems.first(
            where: { projectPathKey($0.path) == projectPathKey(normalizedPath) }
        ) {
            selectProjectSidebarItem(id: existingProject.id)
            return
        }

        let project = ProjectSidebarItem(
            id: UUID(),
            name: projectNameFromPath(normalizedPath),
            path: normalizedPath
        )
        projectSidebarItems.append(project)
        Self.persistProjectSidebarItems(projectSidebarItems)
        refreshProjectSidebarGitBranches(for: [project.id])
        selectProjectSidebarItem(id: project.id)
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    private func refreshProjectSidebarGitBranches(for projectIDs: [UUID]? = nil) {
        let snapshot: [ProjectSidebarItem]
        if let projectIDs {
            let idSet = Set(projectIDs)
            snapshot = projectSidebarItems.filter { idSet.contains($0.id) }
        } else {
            snapshot = projectSidebarItems
        }
        guard !snapshot.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branchesByProjectID = snapshot.map { project in
                (project.id, Self.currentGitBranch(at: project.path))
            }

            DispatchQueue.main.async {
                guard let self else { return }

                for (projectID, gitBranch) in branchesByProjectID {
                    guard let index = self.projectSidebarItems.firstIndex(where: { $0.id == projectID }) else { continue }
                    self.projectSidebarItems[index].gitBranch = gitBranch
                }
            }
        }
    }

    private static func currentGitBranch(at path: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "-C", path, "branch", "--show-current"]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let branch = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty
        else {
            return nil
        }

        return branch
    }

    private func normalizedProjectPath(_ path: String) -> String {
        var result = (path as NSString).expandingTildeInPath
        result = (result as NSString).standardizingPath
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func projectNameFromPath(_ path: String) -> String {
        let projectName = URL(fileURLWithPath: path).lastPathComponent
        return projectName.isEmpty ? path : projectName
    }

    private func projectPathKey(_ path: String) -> String {
        normalizedProjectPath(path).replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func loadPersistedProjectSidebarItems() -> [ProjectSidebarItem] {
        guard let data = UserDefaults.standard.data(forKey: projectSidebarStorageKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([ProjectSidebarItem].self, from: data)
        } catch {
            Ghostty.logger.warning("failed to decode project sidebar entries: \(error)")
            return []
        }
    }

    private static func persistProjectSidebarItems(_ projects: [ProjectSidebarItem]) {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: projectSidebarStorageKey)
        } catch {
            Ghostty.logger.warning("failed to persist project sidebar entries: \(error)")
        }
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController? = nil

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window

        if let parent {
            if parent.styleMask.contains(.fullScreen) {
                // If our previous window was fullscreen then we want our new window to
                // be fullscreen. This behavior actually doesn't match the native tabbing
                // behavior of macOS apps where new windows create tabs when in native
                // fullscreen but this is how we've always done it. This matches iTerm2
                // behavior.
                c.toggleFullscreen(mode: .native)
            } else if ghostty.config.windowFullscreen {
                switch (ghostty.config.windowFullscreenMode) {
                case .native:
                    // Native has to be done immediately so that our stylemask contains
                    // fullscreen for the logic later in this method.
                    c.toggleFullscreen(mode: .native)

                case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                    // If we're non-native then we have to do it on a later loop
                    // so that the content view is setup.
                    DispatchQueue.main.async {
                        c.toggleFullscreen(mode: ghostty.config.windowFullscreenMode)
                    }
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        DispatchQueue.main.async {
            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if (!window.styleMask.contains(.fullScreen)) {
                    Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
                }
            }

            c.showWindow(self)

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withSurfaceTree: tree)

        // Calculate the target frame based on the tree's view bounds
        let treeSize: CGSize? = tree.root?.viewBounds()

        DispatchQueue.main.async {
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
                    }
                }
            }

            c.showWindow(self)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(ghostty, tree: tree)
                }
            }
        }

        return c
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        parentController.addMainPanelTab(withBaseConfig: baseConfig)
        return parentController
    }

    override func refreshTerminalOverviewItems() {
        terminalOverviewItems = collectTerminalOverviewItems()
    }

    override func activateTerminalOverviewItem(id: UUID) {
        guard let item = terminalOverviewItems.first(where: { $0.id == id }) else {
            terminalOverviewIsShowing = false
            return
        }

        activateTerminalOverviewDestination(item)
    }

    @IBAction override func toggleTabOverview(_ sender: Any?) {
        terminalOverviewIsShowing.toggle()
        if terminalOverviewIsShowing {
            refreshTerminalOverviewItems()
        }
    }

    private func activateTerminalOverviewDestination(_ item: TerminalOverviewItem) {
        guard let targetController = TerminalController.all.first(where: { $0.controllerID == item.controllerID }) else {
            terminalOverviewIsShowing = false
            return
        }

        for controller in TerminalController.all {
            controller.terminalOverviewIsShowing = false
        }

        targetController.syncActiveMainPanelTabState()
        guard targetController.selectWorkspaceContaining(tabID: item.tabID, preferredProjectID: item.projectID) else {
            return
        }

        if targetController.selectedMainPanelTabID != item.tabID {
            targetController.selectMainPanelTab(id: item.tabID)
        }

        guard let targetSurface = targetController.surfaceTree.first(where: { $0.id == item.surfaceID }) else { return }

        if let window = targetController.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        let previousFocusedSurface = targetController.focusedSurface
        targetController.focusedSurface = targetSurface
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: targetSurface, from: previousFocusedSurface)
        }
    }

    private func selectWorkspaceContaining(tabID: UUID, preferredProjectID: UUID?) -> Bool {
        syncActiveMainPanelTabState()

        var statesByWorkspace = mainPanelTabStatesByWorkspace
        statesByWorkspace[activeMainPanelWorkspaceKey] = mainPanelTabStates

        let preferredKey = workspaceKey(for: preferredProjectID)

        func statesContainTab(_ states: [MainPanelTabState]) -> Bool {
            states.contains(where: { $0.id == tabID })
        }

        let targetKey: MainPanelWorkspaceKey? = {
            if let preferredStates = statesByWorkspace[preferredKey], statesContainTab(preferredStates) {
                return preferredKey
            }

            for (key, states) in statesByWorkspace where statesContainTab(states) {
                return key
            }

            return nil
        }()

        guard let targetKey, let targetStates = statesByWorkspace[targetKey], !targetStates.isEmpty else {
            return false
        }

        if targetKey != activeMainPanelWorkspaceKey {
            switch targetKey {
            case .project(let projectID):
                selectedProjectSidebarItemID = projectID
            case .unscoped:
                selectedProjectSidebarItemID = nil
            }

            mainPanelTabStates = targetStates
            if let restoredTabID = selectedMainPanelTabIDByWorkspace[targetKey],
               targetStates.contains(where: { $0.id == restoredTabID }) {
                selectedMainPanelTabID = restoredTabID
            } else {
                selectedMainPanelTabID = targetStates.first?.id
            }

            applySelectedMainPanelTabState()
            persistCurrentMainPanelWorkspaceState()
            refreshMainPanelTabs()
            refreshRunningProcesses()
        }

        return mainPanelTabStates.contains(where: { $0.id == tabID })
    }
    
    //MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if (notification.object == nil) {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = window?.tabbedWindows?.count ?? 0 > 1

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let equiv = ghostty.config.keyboardShortcut(for: "goto_tab:\(tab)") {
                    window.keyEquivalent = "\(equiv)"
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }
    
    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If any other project/tab still exists, close only the current tab.
        if totalMainPanelTabCount() > 1 {
            closeTab(nil)
            return
        }

        // No additional tabs, closing the window.
        closeWindow(nil)
    }

    func closeTabImmediately(registerRedo: Bool = true) {
        guard let selectedMainPanelTabID else {
            closeWindowImmediately()
            return
        }

        _ = registerRedo
        closeMainPanelTabImmediately(id: selectedMainPanelTabID)
    }

    private func closeOtherTabsImmediately() {
        guard let selectedMainPanelTabID else { return }
        guard mainPanelTabStates.count > 1 else { return }

        syncActiveMainPanelTabState()
        mainPanelTabStates = mainPanelTabStates.filter { $0.id == selectedMainPanelTabID }
        if let selectedState = mainPanelTabStates.first {
            applyMainPanelTabState(selectedState)
        }
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    private func closeTabsOnTheRightImmediately() {
        guard let currentIndex = selectedMainPanelTabIndex() else { return }
        guard currentIndex < mainPanelTabStates.count - 1 else { return }

        syncActiveMainPanelTabState()
        mainPanelTabStates.removeSubrange((currentIndex + 1)..<mainPanelTabStates.count)
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
        refreshRunningProcesses()
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    func closeWindowImmediately() {
        guard let window = window else { return }

        registerUndoForCloseWindow()

        if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
            tabGroup.windows.forEach { window in
                // Clear out the surfacetree to ensure there is no undo state.
                // This prevents unnecessary undos registered since AppKit may
                // process them on later ticks so we can't just disable undo registration.
                if let controller = window.windowController as? TerminalController {
                    controller.surfaceTree = .init()
                }

                window.close()
            }
        } else {
            window.close()
        }
    }

    /// Registers undo for closing window(s), handling both single windows and tab groups.
    private func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let window else { return }

        // If we don't have a tab group or we don't have multiple tabs, then
        // do a normal single window close.
        guard let tabGroup = window.tabGroup,
              tabGroup.windows.count > 1 else {
            // No tabs, just save this window's state
            if let undoState {
                // Register undo action to restore the window
                undoManager.setActionName("Close Window")
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: undoExpiration) { ghostty in
                        // Restore the undo state
                        let newController = TerminalController(ghostty, with: undoState)

                        // Register redo action
                        undoManager.registerUndo(
                            withTarget: newController,
                            expiresAfter: newController.undoExpiration) { target in
                                target.closeWindowImmediately()
                            }
                    }
            }

            return
        }

        // Multiple windows in tab group - collect all undo states in sorted order
        // by tab ordering. Also track which window was key.
        let undoStates = tabGroup.windows
            .compactMap { tabWindow -> UndoState? in
                guard let controller = tabWindow.windowController as? TerminalController,
                      var undoState = controller.undoState else { return nil }
                // Clear the tab group reference since it is unneeded. It should be
                // garbage collected but we want to be extra sure we don't try to
                // restore into it because we're going to recreate it.
                undoState.tabGroup = nil
                return undoState
            }
            .sorted { (lhs, rhs) in
                switch (lhs.tabIndex, rhs.tabIndex) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return true
                }
            }

        // Find the index of the key window in our sorted states. This is a bit verbose
        // but we only need this for this style of undo so we don't want to add it to
        // UndoState.
        let keyWindowIndex: Int?
        if let keyWindow = tabGroup.windows.first(where: { $0.isKeyWindow }),
            let keyController = keyWindow.windowController as? TerminalController,
            let keyUndoState = keyController.undoState {
            keyWindowIndex = undoStates.firstIndex {
                $0.tabIndex == keyUndoState.tabIndex }
        } else {
            keyWindowIndex = nil
        }

        // Register undo action to restore all windows
        guard !undoStates.isEmpty else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            // Restore all windows in the tab group
            let controllers = undoStates.map { undoState in
                TerminalController(ghostty, with: undoState)
            }

            // The first controller becomes the parent window for all tabs.
            // If we don't have a first controller (shouldn't be possible?)
            // then we can't restore tabs.
            guard let firstController = controllers.first else { return }

            // Add all subsequent controllers as tabs to the first window
            for controller in controllers.dropFirst() {
                controller.showWindow(nil)
                if let firstWindow = firstController.window,
                   let newWindow = controller.window {
                    firstWindow.addTabbedWindow(newWindow, ordered: .above)
                }
            }

            // Make the appropriate window key. If we had a key window, restore it.
            // Otherwise, make the last window key.
            if let keyWindowIndex, keyWindowIndex < controllers.count {
                controllers[keyWindowIndex].window?.makeKeyAndOrderFront(nil)
            } else {
                controllers.last?.window?.makeKeyAndOrderFront(nil)
            }

            // Register redo action on the first controller
            undoManager.registerUndo(
                withTarget: firstController,
                expiresAfter: firstController.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        guard let confirmWindow = all
            .first(where: { $0.anyMainPanelTabNeedsCloseConfirmation() })?
            .window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if (response == .alertFirstButtonReturn) {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let tabColor: TerminalTabColor
    }

    convenience init(_ ghostty: Ghostty.App,
         with undoState: UndoState
    ) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree)

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindow(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindow(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }
            
            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
    }

    //MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if (restorable) {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        window.contentView = TerminalViewContainer(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self,
        )

        // If we have a default size, we want to apply it.
        if let defaultSize {
            switch (defaultSize) {
            case .frame:
                // Frames can be applied immediately
                defaultSize.apply(to: window)

            case .contentIntrinsicSize:
                // Content intrinsic size requires a short delay so that AppKit
                // can layout our SwiftUI views.
                DispatchQueue.main.asyncAfter(deadline: .now() + .microseconds(10_000)) { [weak self, weak window] in
                    guard let self, let window else { return }
                    defaultSize.apply(to: window)
                    if let screen = window.screen ?? NSScreen.main {
                        let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                        window.setFrameOrigin(frame.origin)
                    }
                }
            }
        }

        // Store our initial frame so we can know our default later. This MUST
        // be after the defaultSize call above so that we don't re-apply our frame.
        // Note: we probably want to set this on the first frame change or something
        // so it respects cascade.
        initialFrame = window.frame

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        if (!window.styleMask.contains(.fullScreen)) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch (scope) {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        self.relabelTabs()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: NSZeroPoint)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        if let window {
            LastWindowPosition.shared.save(window)
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        if let window {
            LastWindowPosition.shared.save(window)
        }

        // Remember our last main
        Self.lastMain = self
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard totalMainPanelTabCount() > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard mainPanelTabStates.count > 1 else { return }
        guard let selectedMainPanelTabID else { return }

        let tabsToClose = mainPanelTabStates.filter { $0.id != selectedMainPanelTabID }
        let needsConfirm = tabsToClose.contains(where: tabNeedsCloseConfirmation(_:))

        if !needsConfirm {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let currentIndex = selectedMainPanelTabIndex() else { return }
        guard currentIndex < mainPanelTabStates.count - 1 else { return }

        let tabsToClose = mainPanelTabStates[(currentIndex + 1)...]
        let needsConfirm = tabsToClose.contains(where: tabNeedsCloseConfirmation(_:))

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        syncActiveMainPanelTabState()
        let needsConfirm = anyMainPanelTabNeedsCloseConfirmation()
        if !needsConfirm {
            closeWindowImmediately()
            return
        }

        confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    //MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    //MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        syncActiveMainPanelTabState()
        guard let selectedIndex = selectedMainPanelTabIndex() else { return }
        guard !mainPanelTabStates.isEmpty else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = mainPanelTabStates.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        let movedState = mainPanelTabStates.remove(at: selectedIndex)
        mainPanelTabStates.insert(movedState, at: finalIndex)
        selectedMainPanelTabID = movedState.id
        persistCurrentMainPanelWorkspaceState()
        refreshMainPanelTabs()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard !mainPanelTabStates.isEmpty else { return }

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedIndex = selectedMainPanelTabIndex() else { return }

            if (tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue) {
                if (selectedIndex == 0) {
                    finalIndex = mainPanelTabStates.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue) {
                if (selectedIndex == mainPanelTabStates.count - 1) {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if (tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue) {
                finalIndex = mainPanelTabStates.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), mainPanelTabStates.count - 1)
        }

        guard finalIndex >= 0 else { return }
        selectMainPanelTab(id: mainPanelTabStates[finalIndex].id)
    }

    @objc private func onGotoProject(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        guard let projectEnumAny = notification.userInfo?[Ghostty.Notification.GotoProjectKey] else { return }
        guard let projectEnum = projectEnumAny as? ghostty_action_goto_project_e else { return }
        guard !projectSidebarItems.isEmpty else { return }

        let selectedIndex: Int? = selectedProjectSidebarItemID.flatMap { selectedID in
            projectSidebarItems.firstIndex(where: { $0.id == selectedID })
        }
        let projectIndex: Int32 = projectEnum.rawValue
        let finalIndex: Int

        if (projectIndex <= 0) {
            switch projectIndex {
            case GHOSTTY_GOTO_PROJECT_PREVIOUS.rawValue:
                guard projectSidebarItems.count > 1 else { return }
                if let selectedIndex {
                    finalIndex = selectedIndex == 0 ? projectSidebarItems.count - 1 : selectedIndex - 1
                } else {
                    finalIndex = projectSidebarItems.count - 1
                }

            case GHOSTTY_GOTO_PROJECT_NEXT.rawValue:
                guard projectSidebarItems.count > 1 else { return }
                if let selectedIndex {
                    finalIndex = selectedIndex == projectSidebarItems.count - 1 ? 0 : selectedIndex + 1
                } else {
                    finalIndex = 0
                }

            case GHOSTTY_GOTO_PROJECT_LAST.rawValue:
                finalIndex = projectSidebarItems.count - 1

            default:
                return
            }
        } else {
            finalIndex = min(Int(projectIndex - 1), projectSidebarItems.count - 1)
        }

        guard finalIndex >= 0, finalIndex < projectSidebarItems.count else { return }
        selectProjectSidebarItem(id: projectSidebarItems[finalIndex].id)
    }

    @objc private func onToggleTabOverview(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        toggleTabOverview(nil)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: String
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = "system"
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let currentIndex = selectedMainPanelTabIndex() else { return false }
            return currentIndex < mainPanelTabStates.count - 1
            
        case #selector(returnToDefaultSize):
            guard let window else { return false }
            
            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }
            
            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }
            
            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false
            
        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else if let initialFrame {
            // The initial frame we had when we started otherwise.
            return .frame(initialFrame)
        } else {
            return nil
        }
    }
}
