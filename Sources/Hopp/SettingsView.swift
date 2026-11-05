import AppKit
import HoppCore
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    /// `nil` follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published private(set) var appearance: AppAppearance
    @Published private(set) var allWindowsShortcut: KeyboardShortcut
    @Published private(set) var currentAppShortcut: KeyboardShortcut
    @Published private(set) var launcherShortcut: KeyboardShortcut
    @Published private(set) var showWindowsFromAllDesktops: Bool
    @Published private(set) var showWindowsFromCurrentDisplayOnly: Bool
    @Published private(set) var keepSwitcherOpen: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWindowsFromAllDesktops = defaults.object(forKey: "showWindowsFromAllDesktops") as? Bool ?? false
        showWindowsFromCurrentDisplayOnly = defaults.object(forKey: "showWindowsFromCurrentDisplayOnly") as? Bool ?? false
        keepSwitcherOpen = defaults.object(forKey: "keepSwitcherOpen") as? Bool ?? false
        func loadShortcut(_ key: String, fallback: KeyboardShortcut) -> KeyboardShortcut {
            guard let data = defaults.data(forKey: key),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
                  shortcut.isValid else { return fallback }
            return shortcut
        }
        let allWindows = loadShortcut("allWindowsShortcut", fallback: .allWindows)
        let currentApp = loadShortcut("currentAppShortcut", fallback: .currentApp)
        let launcher = loadShortcut("launcherShortcut", fallback: .launcher)
        let conflict = KeyboardShortcut.haveConflicts([allWindows, currentApp, launcher])
        allWindowsShortcut = conflict ? .allWindows : allWindows
        currentAppShortcut = conflict ? .currentApp : currentApp
        launcherShortcut = conflict ? .launcher : launcher
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: "appearance")
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: "language")
    }

    func setShowWindowsFromCurrentDisplayOnly(_ enabled: Bool) {
        showWindowsFromCurrentDisplayOnly = enabled
        defaults.set(enabled, forKey: "showWindowsFromCurrentDisplayOnly")
    }

    func setShowWindowsFromAllDesktops(_ enabled: Bool) {
        showWindowsFromAllDesktops = enabled
        defaults.set(enabled, forKey: "showWindowsFromAllDesktops")
    }

    func setKeepSwitcherOpen(_ enabled: Bool) {
        keepSwitcherOpen = enabled
        defaults.set(enabled, forKey: "keepSwitcherOpen")
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcut, target: ShortcutTarget) -> Bool {
        let others = ShortcutTarget.allCases.filter { $0 != target }.map { self.shortcut(for: $0) }
        guard shortcut.isValid, !others.contains(where: { shortcut.conflicts(with: $0) }),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        switch target {
        case .allWindows: allWindowsShortcut = shortcut
        case .currentApp: currentAppShortcut = shortcut
        case .launcher: launcherShortcut = shortcut
        }
        defaults.set(data, forKey: target.rawValue + "Shortcut")
        return true
    }

    func shortcut(for target: ShortcutTarget) -> KeyboardShortcut {
        switch target {
        case .allWindows: allWindowsShortcut
        case .currentApp: currentAppShortcut
        case .launcher: launcherShortcut
        }
    }

    func resetShortcuts() {
        allWindowsShortcut = .allWindows
        currentAppShortcut = .currentApp
        launcherShortcut = .launcher
        ShortcutTarget.allCases.forEach { defaults.removeObject(forKey: $0.rawValue + "Shortcut") }
    }

    static func selfCheck() -> Bool {
        let suite = "Hopp.self-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AppSettings(defaults: defaults)
        guard !initial.showWindowsFromAllDesktops else { return false }
        initial.setShowWindowsFromAllDesktops(true)
        guard AppSettings(defaults: defaults).showWindowsFromAllDesktops else { return false }
        initial.setShowWindowsFromAllDesktops(false)
        guard !AppSettings(defaults: defaults).showWindowsFromAllDesktops else { return false }
        guard !initial.showWindowsFromCurrentDisplayOnly else { return false }
        initial.setShowWindowsFromCurrentDisplayOnly(true)
        guard AppSettings(defaults: defaults).showWindowsFromCurrentDisplayOnly else { return false }
        initial.setShowWindowsFromCurrentDisplayOnly(false)
        guard !AppSettings(defaults: defaults).showWindowsFromCurrentDisplayOnly else { return false }
        guard !initial.keepSwitcherOpen else { return false }
        initial.setKeepSwitcherOpen(true)
        guard AppSettings(defaults: defaults).keepSwitcherOpen else { return false }
        initial.setKeepSwitcherOpen(false)
        guard !AppSettings(defaults: defaults).keepSwitcherOpen else { return false }
        guard initial.appearance == .system else { return false }
        initial.setAppearance(.dark)
        guard AppSettings(defaults: defaults).appearance == .dark else { return false }
        defaults.set("unsupported", forKey: "appearance")
        guard AppSettings(defaults: defaults).appearance == .system else { return false }
        let settings = AppSettings(defaults: defaults)
        settings.setLanguage(.ja)
        guard AppSettings(defaults: defaults).language == .ja,
              defaults.string(forKey: "language") == "ja" else { return false }
        defaults.set("unsupported", forKey: "language")
        guard AppSettings(defaults: defaults).language == .system else { return false }
        let custom = KeyboardShortcut(keyCode: 16, modifiers: [.maskControl, .maskAlternate], keyLabel: "Y")
        guard settings.allWindowsShortcut == .allWindows, settings.currentAppShortcut == .currentApp,
              !settings.setShortcut(.currentApp, target: .allWindows),
              settings.setShortcut(custom, target: .allWindows),
              AppSettings(defaults: defaults).allWindowsShortcut == custom,
              !settings.setShortcut(custom, target: .currentApp),
              settings.setShortcut(KeyboardShortcut(keyCode: 16, modifiers: .maskCommand, keyLabel: "Y"),
                                   target: .currentApp),
              AppSettings(defaults: defaults).currentAppShortcut.keyCode == 16,
              settings.launcherShortcut == .launcher,
              !settings.setShortcut(custom, target: .launcher),
              settings.setShortcut(KeyboardShortcut(keyCode: 0, modifiers: .maskAlternate, keyLabel: "A"), target: .launcher),
              AppSettings(defaults: defaults).launcherShortcut.keyCode == 0 else { return false }
        // Corrupt or conflicting saved values fall back to the original shortcuts.
        defaults.set(try? JSONEncoder().encode(custom), forKey: "currentAppShortcut")
        guard AppSettings(defaults: defaults).allWindowsShortcut == .allWindows,
              AppSettings(defaults: defaults).currentAppShortcut == .currentApp else { return false }
        defaults.set(Data("invalid".utf8), forKey: "allWindowsShortcut")
        guard AppSettings(defaults: defaults).allWindowsShortcut == .allWindows else { return false }
        settings.resetShortcuts()
        return AppSettings(defaults: defaults).allWindowsShortcut == .allWindows
            && AppSettings(defaults: defaults).currentAppShortcut == .currentApp
            && AppSettings(defaults: defaults).launcherShortcut == .launcher
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowService: WindowService
    @ObservedObject var shortcuts: ShortcutController

    private var language: AppLanguage { settings.language }
    private func t(_ key: String) -> String { L10n.text(key, language: language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                card {
                    row(t("Language")) {
                        Picker(t("Language"), selection: Binding(get: { settings.language }, set: settings.setLanguage)) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option == .system ? t("System") : option.name).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider
                    row(t("Theme")) {
                        Picker(t("Theme"), selection: Binding(get: { settings.appearance }, set: settings.setAppearance)) {
                            ForEach(AppAppearance.allCases) { option in
                                Label(t(option.title), systemImage: option.symbol).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider
                    row(t("Accessibility")) {
                        status(windowService.hasAccessibility, on: "Granted", off: "Not granted")
                        if !windowService.hasAccessibility {
                            Button(t("Request access")) { windowService.requestAccessibility() }
                        }
                    }
                    divider
                    row(t("Global shortcuts")) {
                        status(shortcuts.isRunning, on: "Running", off: "Not running")
                        if windowService.hasAccessibility && !shortcuts.isRunning {
                            Button(t("Retry")) { _ = shortcuts.start() }
                        }
                    }
                }

                sectionHeader(t("Window switcher"))
                card {
                    toggleRow("Only show windows on the current display",
                              "With multiple displays, list only windows on the display under the pointer.",
                              get: settings.showWindowsFromCurrentDisplayOnly,
                              set: settings.setShowWindowsFromCurrentDisplayOnly)
                    divider
                    toggleRow("Show windows from all desktops",
                              "The current desktop comes first in recent order. Other desktops stay grouped in a stable order.",
                              get: settings.showWindowsFromAllDesktops,
                              set: settings.setShowWindowsFromAllDesktops)
                    divider
                    toggleRow("Keep switcher open after releasing modifiers",
                              "Type to search without holding the modifier. Press Return to switch; press Esc or click outside to close.",
                              get: settings.keepSwitcherOpen,
                              set: settings.setKeepSwitcherOpen)
                }

                sectionHeader(t("Shortcuts"))
                card {
                    ForEach(Array(ShortcutTarget.allCases.enumerated()), id: \.element) { index, target in
                        if index > 0 { divider }
                        row(t(target.title)) { shortcutButton(target: target) }
                    }
                    divider
                    row(t("Restore defaults"), subtitle: t("Click a shortcut to record. Esc cancels; Shift switches backward.")) {
                        Button {
                            shortcuts.cancelRecording()
                            settings.resetShortcuts()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(t("Restore defaults"))
                        .accessibilityLabel(t("Restore defaults"))
                    }
                }
                if let error = shortcuts.recordingErrorKey {
                    Text(t(error))
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .font(.system(size: 13))
        .tint(Color(nsColor: appAccentColor))
        .frame(width: 560, height: 710)
        .onDisappear { shortcuts.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            shortcuts.cancelRecording()
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func row<Trailing: View>(_ title: String, subtitle: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    private func toggleRow(_ title: String, _ subtitle: String, get: Bool,
                           set: @escaping (Bool) -> Void) -> some View {
        row(t(title), subtitle: t(subtitle)) {
            Toggle(t(title), isOn: Binding(get: { get }, set: set))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func status(_ ok: Bool, on: String, off: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(t(ok ? on : off)).foregroundStyle(.secondary)
        }
    }

    private func shortcutButton(target: ShortcutTarget) -> some View {
        let recording = shortcuts.recordingTarget == target
        let display = settings.shortcut(for: target).display
        let accent = Color(nsColor: appAccentColor)
        return Button {
            if recording {
                shortcuts.cancelRecording()
            } else {
                shortcuts.beginRecording(target: target) { shortcut in
                    settings.setShortcut(shortcut, target: target)
                }
            }
        } label: {
            Text(recording ? t("Press shortcut…") : display)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(recording ? accent : .primary)
                .padding(.horizontal, 12)
                .frame(minWidth: 90, minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(recording ? accent.opacity(0.12) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(recording ? accent : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(target.title))
        .accessibilityValue(recording ? t("Press shortcut…") : display)
    }
}
