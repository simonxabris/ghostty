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
                    terminalView
                }
            } else {
                terminalView
            }
        }
    }

    private var terminalView: some View {
        TerminalView(ghostty: ghostty, viewModel: viewModel, delegate: delegate)
    }
}

private struct ProjectSidebarView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
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
                            Button {
                                viewModel.selectProjectSidebarItem(id: project.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(project.path.abbreviatedPath)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 220, idealWidth: 220, maxWidth: 220, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
    }
}
