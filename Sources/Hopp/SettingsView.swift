import AppKit
import HoppCore
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published private(set) var allWindowsShortcut: KeyboardShortcut
    @Published private(set) var currentAppShortcut: KeyboardShortcut
    @Published private(set) var launcherShortcut: KeyboardShortcut
    @Published private(set) var showWindowsFromAllDesktops: Bool
    @Published private(set) var keepSwitcherOpen: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWindowsFromAllDesktops = defaults.object(forKey: "showWindowsFromAllDesktops") as? Bool ?? false
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
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: "language")
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
        guard !initial.keepSwitcherOpen else { return false }
        initial.setKeepSwitcherOpen(true)
        guard AppSettings(defaults: defaults).keepSwitcherOpen else { return false }
        initial.setKeepSwitcherOpen(false)
        guard !AppSettings(defaults: defaults).keepSwitcherOpen else { return false }
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

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowService: WindowService
    @ObservedObject var shortcuts: ShortcutController
    @State private var page: SettingsPage = .general

    private var language: AppLanguage { settings.language }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                navigationItem(.general)
                navigationItem(.shortcuts)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch page {
                    case .general: generalSettings
                    case .shortcuts: shortcutSettings
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(.system(size: 13))
        .tint(Color(nsColor: appAccentColor))
        .frame(width: 840, height: 600)
        .onChange(of: page) { _ in shortcuts.cancelRecording() }
        .onDisappear { shortcuts.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            shortcuts.cancelRecording()
        }
    }

    private func navigationItem(_ destination: SettingsPage) -> some View {
        Label(L10n.text(destination.rawValue, language: language), systemImage: destination.symbol)
            .font(.system(size: 14))
            .padding(.vertical, 5)
            .tag(destination)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(L10n.text(title, language: language) + ":")
                .multilineTextAlignment(.trailing)
                .frame(width: 130, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSettings: some View {
        Group {
            settingsRow("Window switcher") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L10n.text("Show windows from all desktops", language: language), isOn: Binding(
                        get: { settings.showWindowsFromAllDesktops }, set: settings.setShowWindowsFromAllDesktops
                    ))
                    Text(L10n.text("The current desktop comes first in recent order. Other desktops stay grouped in a stable order.", language: language))
                        .foregroundStyle(.secondary)
                    Toggle(L10n.text("Keep switcher open after releasing modifiers", language: language), isOn: Binding(
                        get: { settings.keepSwitcherOpen }, set: settings.setKeepSwitcherOpen
                    ))
                    Text(L10n.text("Type to search without holding the modifier. Press Return to switch; press Esc or click outside to close.", language: language))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }
            settingsRow("Language") {
                Picker(L10n.text("Language", language: language), selection: Binding(
                    get: { settings.language }, set: settings.setLanguage
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option == .system ? L10n.text("System", language: language) : option.name).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            settingsRow("Accessibility") {
                HStack {
                    Text(L10n.text(windowService.hasAccessibility ? "Granted" : "Not granted", language: language))
                    if !windowService.hasAccessibility {
                        Button(L10n.text("Request access", language: language)) { windowService.requestAccessibility() }
                    }
                }
            }
            settingsRow("Global shortcuts") {
                HStack {
                    Text(L10n.text(shortcuts.isRunning ? "Running" : "Not running", language: language))
                    if windowService.hasAccessibility && !shortcuts.isRunning {
                        Button(L10n.text("Retry", language: language)) { _ = shortcuts.start() }
                    }
                }
            }
        }
    }

    private var shortcutSettings: some View {
        Group {
            ForEach(ShortcutTarget.allCases, id: \.self) { target in
                settingsRow(target.title) {
                    shortcutButton(target: target)
                }
            }
            settingsRow("Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Click a shortcut to record. Esc cancels; Shift switches backward.", language: language))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("Restore defaults", language: language)) {
                        shortcuts.cancelRecording()
                        settings.resetShortcuts()
                    }
                    if let error = shortcuts.recordingErrorKey {
                        Text(L10n.text(error, language: language)).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func shortcutButton(target: ShortcutTarget) -> some View {
        let recording = shortcuts.recordingTarget == target
        let display = settings.shortcut(for: target).display
        return Button(recording ? L10n.text("Press shortcut…", language: language) : display) {
            if recording {
                shortcuts.cancelRecording()
            } else {
                shortcuts.beginRecording(target: target) { shortcut in
                    settings.setShortcut(shortcut, target: target)
                }
            }
        }
        .accessibilityLabel(L10n.text(target.title, language: language))
        .accessibilityValue(recording ? L10n.text("Press shortcut…", language: language) : display)
    }
}
