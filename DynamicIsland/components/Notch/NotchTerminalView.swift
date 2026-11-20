/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import SwiftTerm
import Defaults

// MARK: - NSViewRepresentable wrapper for SwiftTerm

/// Bridges SwiftTerm's `LocalProcessTerminalView` (NSView) into SwiftUI.
///
/// Returns `TerminalManager.containerView` (a stable NSView) so that
/// SwiftUI's view lifecycle never tears down the actual terminal.  The
/// real `LocalProcessTerminalView` lives as a subview of that container
/// and survives notch close/open and tab-switch cycles.
struct TerminalNSViewRepresentable: NSViewRepresentable {
    @ObservedObject var terminalManager = TerminalManager.shared

    func makeNSView(context: Context) -> NSView {
        context.coordinator.terminalManager = terminalManager
        terminalManager.ensureTerminalView(delegate: context.coordinator)
        return terminalManager.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-mount terminal if the previous view was removed on restart.
        terminalManager.ensureTerminalView(delegate: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var terminalManager: TerminalManager?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // Terminal resized — no action needed; SwiftTerm handles reflow.
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in
                terminalManager?.updateTitle(title)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Could be used for breadcrumbs in the future.
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

// MARK: - Notch Tab View

/// Guake-style dropdown terminal tab for the notch.
/// Dynamically sizes up to half the screen height; content scrolls when the
/// terminal buffer exceeds the visible area (handled internally by SwiftTerm).
struct NotchTerminalView: View {
    @ObservedObject var terminalManager = TerminalManager.shared
    @EnvironmentObject var vm: DynamicIslandViewModel
    @Default(.enableTerminalFeature) var enableTerminalFeature
    @Default(.cornerRadiusScaling) var cornerRadiusScaling
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.terminalForegroundColor) var terminalForegroundColor
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    /// Top corners stay mild; bottom follows shell − padding (see `notchTerminalBottomCornerRadii`).
    private static let terminalClipTopCornerRadius: CGFloat = 6

    private var currentScreenName: String {
        vm.screen ?? DynamicIslandViewCoordinator.shared.selectedScreen
    }

    private var isDynamicIslandMode: Bool {
        shouldUseDynamicIslandMode(for: currentScreenName)
    }

    private var terminalClipShape: UnevenRoundedRectangle {
        let innerBottom = notchTerminalBottomCornerRadii(
            isDynamicIslandMode: isDynamicIslandMode,
            notchState: vm.notchState,
            cornerRadiusScaling: cornerRadiusScaling,
            enableMinimalisticUI: enableMinimalisticUI,
            closedNotchHeight: vm.closedNotchSize.height
        ).innerBottom
        return UnevenRoundedRectangle(
            topLeadingRadius: Self.terminalClipTopCornerRadius,
            bottomLeadingRadius: innerBottom,
            bottomTrailingRadius: innerBottom,
            topTrailingRadius: Self.terminalClipTopCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if enableTerminalFeature {
                // Terminal header bar
                HStack {
                    Image(systemName: "apple.terminal")
                        .foregroundStyle(terminalForegroundColor)
                        .font(.system(size: 11))

                    Text(terminalManager.terminalTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(terminalForegroundColor)
                        .lineLimit(1)

                    Spacer()

                    // Restart button
                    Button {
                        terminalManager.restartShell()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(terminalForegroundColor)
                    }
                    .buttonStyle(.plain)
                    .help("Restart shell")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, notchTerminalContentEdgePadding.horizontal)

                HStack(spacing: 8) {
                    TerminalNSViewRepresentable(terminalManager: terminalManager)
                        .clipShape(terminalClipShape)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 1)
                        .accessibilityHidden(true)

                    TerminalShortcutsPanel(terminalManager: terminalManager)
                        .frame(width: 132)
                }
                .padding(.top, notchTerminalContentEdgePadding.top)
                .padding(.bottom, notchTerminalContentEdgePadding.bottom)
                .padding(.horizontal, notchTerminalContentEdgePadding.horizontal)
                .onHover { hovering in
                    updateSuppression(for: hovering)
                }
            } else {
                // Feature disabled placeholder
                VStack(spacing: 8) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    Text("Terminal is disabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Enable it in Settings → Terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            updateSuppression(for: false)
        }
        .onAppear {
            terminalManager.refreshTerminalAppearanceIfNeeded()
            terminalManager.focusTerminalIfPossible()
        }
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

private struct TerminalShortcutsPanel: View {
    let terminalManager: TerminalManager
    @Default(.terminalShortcuts) private var shortcuts
    @State private var isReady = false

    private var status: String {
        isReady ? String(localized: "Terminal ready") : String(localized: "Terminal busy or unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Terminal shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Circle()
                    .fill(isReady ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text(status))
                    .help(status)
            }

            if shortcuts.isEmpty {
                Text("Add shortcuts in Terminal settings.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(shortcuts) { shortcut in
                            Button {
                                terminalManager.runShortcut(shortcut)
                                isReady = terminalManager.canRunShortcut
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortcut.name)
                                        .font(.caption.weight(.medium))
                                    Text(shortcut.command)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.72))
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(TerminalShortcutButtonStyle())
                            .disabled(!isReady || !shortcut.isValid)
                            .help(shortcut.command)
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                isReady = terminalManager.canRunShortcut
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

private struct TerminalShortcutButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let opacity = isEnabled ? (configuration.isPressed ? 0.25 : 0.14) : 0.08
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.58)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.white.opacity(opacity), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(isEnabled ? 0.22 : 0.12))
            }
            .contentShape(shape)
    }
}
