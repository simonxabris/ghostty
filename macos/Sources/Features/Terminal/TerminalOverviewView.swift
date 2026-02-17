import SwiftUI
import AppKit

struct TerminalOverviewView: View {
    let items: [TerminalOverviewItem]
    let onClose: () -> Void
    let onSelect: (TerminalOverviewItem) -> Void

    @State private var keyMonitor: Any?

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16, alignment: .top),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 16) {
                HStack {
                    Text("Terminal Overview")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Esc to close")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("No terminals available")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    TerminalOverviewCardView(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, maxHeight: 700)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .padding(24)
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        .onExitCommand(perform: onClose)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                onClose()
                return nil
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

private struct TerminalOverviewCardView: View {
    let item: TerminalOverviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(item.tabTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                StatusBadge(status: item.status)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Group {
                if let image = item.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color(NSColor.windowBackgroundColor))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                            if let cwd = item.cwd, !cwd.isEmpty {
                                Text(cwd)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let cwd = item.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let projectName = item.projectName, !projectName.isEmpty {
                    Text(projectName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusBadge: View {
    let status: TerminalOverviewItem.Status

    private var text: String {
        switch status {
        case .running: return "Running"
        case .idle: return "Idle"
        }
    }

    private var color: Color {
        switch status {
        case .running: return .orange
        case .idle: return .gray
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
