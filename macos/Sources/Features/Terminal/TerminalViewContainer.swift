import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let contentView: NSView

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?
    private var glassTopConstraint: NSLayoutConstraint?
    private var derivedConfig: DerivedConfig

    init(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.derivedConfig = DerivedConfig(config: ghostty.config)
        self.contentView = NSHostingView(rootView: TerminalWorkspaceView(
            ghostty: ghostty,
            viewModel: viewModel,
            delegate: delegate
        ))
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// To make ``TerminalController/DefaultSize/contentIntrinsicSize``
    /// work in ``TerminalController/windowDidLoad()``,
    /// we override this to provide the correct size.
    override var intrinsicContentSize: NSSize {
        contentView.intrinsicContentSize
    }

    private func setup() {
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }
        let newValue = DerivedConfig(config: config)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue
        DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
    }
}

// MARK: Glass

private extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    func addGlassEffectViewIfNeeded() -> NSGlassEffectView? {
        if let existed = glassEffectView as? NSGlassEffectView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = window?.contentView?.superview else {
            return nil
        }
        let effectView = NSGlassEffectView()
        addSubview(effectView, positioned: .below, relativeTo: contentView)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        glassTopConstraint = effectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: -themeFrameView.safeAreaInsets.top
        )
        if let glassTopConstraint {
            NSLayoutConstraint.activate([
                glassTopConstraint,
                effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
                effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            glassTopConstraint = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }
        switch derivedConfig.backgroundBlur {
        case .macosGlassRegular:
            effectView.style = NSGlassEffectView.Style.regular
        case .macosGlassClear:
            effectView.style = NSGlassEffectView.Style.clear
        default:
            break
        }
        let backgroundColor = (window as? TerminalWindow)?.preferredBackgroundColor ?? NSColor(derivedConfig.backgroundColor)
        effectView.tintColor = backgroundColor
            .withAlphaComponent(derivedConfig.backgroundOpacity)
        if let window, window.responds(to: Selector(("_cornerRadius"))), let cornerRadius = window.value(forKey: "_cornerRadius") as? CGFloat {
            effectView.cornerRadius = cornerRadius
        }
#endif // compiler(>=6.2)
    }

    func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle else {
            return
        }
        guard glassEffectView != nil else { return }
        guard let themeFrameView = window?.contentView?.superview else { return }
        glassTopConstraint?.constant = -themeFrameView.safeAreaInsets.top
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        var backgroundOpacity: Double = 0
        var backgroundBlur: Ghostty.Config.BackgroundBlur
        var backgroundColor: Color = .clear

        init(config: Ghostty.Config) {
            self.backgroundBlur = config.backgroundBlur
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundColor = config.backgroundColor
        }
    }
}

private struct TerminalWorkspaceView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var viewModel: ViewModel
    var delegate: (any TerminalViewDelegate)?

    var body: some View {
        Group {
            if viewModel.showsProjectSidebar {
                HStack(spacing: 0) {
                    ProjectSidebarView(viewModel: viewModel)
                    Divider()
                    panelContent
                }
            } else {
                panelContent
            }
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            if !viewModel.mainPanelTabs.isEmpty {
                MainPanelTabsView(viewModel: viewModel)
                Divider()
            }
            terminalView
        }
    }

    private var terminalView: some View {
        TerminalView(ghostty: ghostty, viewModel: viewModel, delegate: delegate)
    }
}

private struct MainPanelTabsView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.mainPanelTabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Button {
                viewModel.addMainPanelTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tab")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
    }

    @ViewBuilder
    private func tabButton(_ tab: MainPanelTabItem) -> some View {
        let isSelected = viewModel.selectedMainPanelTabID == tab.id
        HStack(spacing: 6) {
            Button {
                viewModel.selectMainPanelTab(id: tab.id)
            } label: {
                Text(tab.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .padding(.trailing, 2)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Button {
                viewModel.closeMainPanelTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Tab")
            .padding(.trailing, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
    }
}

private struct ProjectSidebarView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var viewModel: ViewModel
    private let expandedWidth: CGFloat = 220
    private let collapsedWidth: CGFloat = 32
    private let sidebarAnimation: Animation = .easeInOut(duration: 0.2)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !viewModel.projectSidebarIsCollapsed {
                expandedSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if viewModel.projectSidebarIsCollapsed {
                collapsedSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .clipped()
        .frame(width: viewModel.projectSidebarIsCollapsed ? collapsedWidth : expandedWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .animation(sidebarAnimation, value: viewModel.projectSidebarIsCollapsed)
    }

    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.toggleProjectSidebarCollapsed()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Project Sidebar")
                Button {
                    viewModel.addProjectSidebarItem()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if viewModel.projectSidebarItems.isEmpty {
                VStack {
                    Text("No projects yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.projectSidebarItems) { project in
                            let isSelected = viewModel.selectedProjectSidebarItemID == project.id
                            let runningItems = viewModel.runningProcessesByProjectID[project.id] ?? []
                            VStack(alignment: .leading, spacing: 0) {
                                ProjectSidebarRowView(
                                    viewModel: viewModel,
                                    project: project,
                                    runningCount: viewModel.runningProcessCount(for: project.id)
                                )
                                if !runningItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(runningItems) { item in
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.primaryText)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.leading, 12)
                                    .padding(.bottom, 4)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collapsedSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.toggleProjectSidebarCollapsed()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand Project Sidebar")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectSidebarRowView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var viewModel: ViewModel
    var project: ProjectSidebarItem
    var runningCount: Int
    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                viewModel.selectProjectSidebarItem(id: project.id)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(project.gitBranch ?? project.path.abbreviatedPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, isHovered ? 24 : 8)
                .padding(.vertical, 6)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
            .buttonStyle(.plain)

            if isHovered {
                Button {
                    viewModel.removeProjectSidebarItem(id: project.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(project.name)")
                .padding(.trailing, 8)
                .transition(.opacity)
            } else if runningCount > 0 {
                Text("\(runningCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.2))
                    )
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
