import AppKit
import HoppCore

@MainActor
final class AppCatalog {
    private(set) var apps: [AppEntry] = []
    var onChange: (() -> Void)?
    private var isScanning = false

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { AppCatalog.scan() }.value
            guard let self else { return }
            self.isScanning = false
            guard apps != self.apps else { return }
            self.apps = apps
            self.onChange?()
        }
    }

    nonisolated static func scan() -> [AppEntry] {
        let manager = FileManager.default
        let roots = ["/Applications", "/System/Applications", manager.homeDirectoryForCurrentUser.path + "/Applications"]
        var bundles = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        func collect(_ directory: URL, depth: Int) {
            guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    bundles.append(item)
                } else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    collect(item, depth: depth - 1)
                }
            }
        }
        roots.forEach { collect(URL(fileURLWithPath: $0), depth: 2) }

        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        var apps: [AppEntry] = []
        for url in bundles {
            guard seenPaths.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            let bundle = Bundle(url: url)
            if let id = bundle?.bundleIdentifier, !seenIDs.insert(id).inserted { continue }
            let fileName = url.deletingPathExtension().lastPathComponent
            var name = manager.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            apps.append(AppEntry(path: url.path, name: name, alternateName: name == fileName ? nil : fileName,
                                 bundleID: bundle?.bundleIdentifier))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func launch(_ app: AppEntry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration)
    }
}

@MainActor
final class LauncherPanel: NSPanel, NSTextFieldDelegate {
    private static let maxRows = 60
    private static let rowHeight: CGFloat = 40
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let stack = FlippedStackView()
    private let scroll = NSScrollView()
    private let onLaunch: (AppEntry) -> Void
    private let onDismiss: () -> Void
    private var apps: [AppEntry] = []
    private var results: [AppSearch.Match] = []
    private var selectedIndex = 0
    private var language: AppLanguage = .system
    private var hoverOrigin = NSEvent.mouseLocation

    init(onLaunch: @escaping (AppEntry) -> Void, onDismiss: @escaping () -> Void) {
        self.onLaunch = onLaunch
        self.onDismiss = onDismiss
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        // Below pop-up menus so input method candidate windows stay on top.
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .aqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        for view in [searchIcon, field, countLabel, divider, scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            searchIcon.widthAnchor.constraint(equalToConstant: 20),
            searchIcon.heightAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            countLabel.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor, constant: 52),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        contentView = background
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(apps: [AppEntry], language: AppLanguage) {
        self.apps = apps
        self.language = language
        field.stringValue = ""
        field.placeholderString = L10n.text("Search apps", language: language)
        field.setAccessibilityLabel(L10n.text("Search apps", language: language))
        emptyLabel.stringValue = L10n.text("No matching apps", language: language)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            let width = min(640, area.width - 48)
            let height = min(52 + 8 * Self.rowHeight + 16, area.height - 80)
            setFrame(NSRect(x: area.midX - width / 2, y: area.maxY - area.height * 0.22 - height,
                            width: width, height: height), display: false)
        }
        filter()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Applies a refreshed catalog while open, keeping the query and the selected app.
    func update(apps: [AppEntry]) {
        guard isVisible else { return }
        let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].app.id : nil
        self.apps = apps
        filter()
        if let index = results.firstIndex(where: { $0.app.id == selectedID }), index != selectedIndex {
            selectedIndex = index
            render()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        field.stringValue = ""
        onDismiss()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): move(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): launchSelected()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func filter() {
        results = AppSearch.filter(apps, query: field.stringValue)
        selectedIndex = 0
        hoverOrigin = NSEvent.mouseLocation
        render()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func move(by amount: Int) {
        let count = min(results.count, Self.maxRows)
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + amount + count) % count
        hoverOrigin = NSEvent.mouseLocation
        updateSelection()
        if let row = rows.first(where: \.isCurrent) { row.scrollToVisible(row.bounds) }
    }

    private func launchSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let app = results[selectedIndex].app
        dismiss()
        onLaunch(app)
    }

    private var rows: [LauncherRow] { stack.arrangedSubviews.compactMap { $0 as? LauncherRow } }

    private func render() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, match) in results.prefix(Self.maxRows).enumerated() {
            let detail = running.contains(URL(fileURLWithPath: match.app.path).standardizedFileURL.path)
                ? L10n.text("Running", language: language) : match.app.alternateName
            let row = LauncherRow(
                match: match, detail: detail, height: Self.rowHeight,
                onPointerMove: { [weak self] pointer in
                    guard let self, pointer != self.hoverOrigin else { return }
                    self.hoverOrigin = pointer
                    self.selectedIndex = index
                    self.updateSelection()
                },
                action: { [weak self] in
                    self?.selectedIndex = index
                    self?.launchSelected()
                }
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        updateSelection()
        countLabel.stringValue = L10n.format("%@ apps", String(results.count), language: language)
        emptyLabel.isHidden = !results.isEmpty
        contentView?.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1),
                                  height: max(stack.fittingSize.height, scroll.contentSize.height)))
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isCurrent = index == selectedIndex }
    }

    static func smokeCheck() -> Bool {
        let apps = [
            AppEntry(path: "/Applications/Safari.app", name: "Safari"),
            AppEntry(path: "/System/Applications/Calculator.app", name: "计算器", alternateName: "Calculator"),
            AppEntry(path: "/Applications/WeChat.app", name: "微信", alternateName: "WeChat")
        ]
        var launched: [String] = []
        var dismissed = 0
        let panel = LauncherPanel(onLaunch: { launched.append($0.name) }, onDismiss: { dismissed += 1 })
        defer { panel.close() }
        panel.show(apps: apps, language: .zh)
        guard panel.rows.count == 3, panel.countLabel.stringValue == "3 个应用", panel.emptyLabel.isHidden,
              panel.rows.map(\.isCurrent) == [true, false, false] else { return false }
        panel.move(by: -1)
        guard panel.rows.map(\.isCurrent) == [false, false, true] else { return false }
        panel.field.stringValue = "jisuan"
        panel.filter()
        guard panel.rows.count == 1, panel.selectedIndex == 0 else { return false }
        panel.field.stringValue = "zzz"
        panel.filter()
        panel.launchSelected()
        guard panel.rows.isEmpty, !panel.emptyLabel.isHidden, launched.isEmpty else { return false }
        panel.field.stringValue = "weixin"
        panel.filter()
        panel.launchSelected()
        guard launched == ["微信"], dismissed == 1, !panel.isVisible, panel.field.stringValue.isEmpty else { return false }
        panel.dismiss()
        return dismissed == 1
    }
}

@MainActor
private final class LauncherRow: NSButton {
    private let callback: () -> Void
    private let onPointerMove: (NSPoint) -> Void
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let nameRanges: [NSRange]
    private var trackingArea: NSTrackingArea?

    var isCurrent = false {
        didSet { applyAppearance() }
    }

    init(match: AppSearch.Match, detail: String?, height: CGFloat,
         onPointerMove: @escaping (NSPoint) -> Void, action: @escaping () -> Void) {
        callback = action
        self.onPointerMove = onPointerMove
        nameLabel = NSTextField(labelWithString: match.app.name)
        detailLabel = NSTextField(labelWithString: detail ?? "")
        nameRanges = match.nameRanges
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSWorkspace.shared.icon(forFile: match.app.path)
        icon.size = NSSize(width: 28, height: 28)
        let iconView = NSImageView(image: icon)
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        [iconView, nameLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height)
        ])
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(detail.map { "\(match.app.name), \($0)" } ?? match.app.name)
        applyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func applyAppearance() {
        layer?.backgroundColor = isCurrent ? appAccentColor.cgColor : NSColor.clear.cgColor
        let text = NSMutableAttributedString(string: nameLabel.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: isCurrent ? .medium : .regular),
            .foregroundColor: isCurrent ? NSColor.white : NSColor.labelColor
        ])
        for range in nameRanges {
            text.addAttributes([.backgroundColor: NSColor(srgbRed: 1, green: 229 / 255, blue: 138 / 255, alpha: 1),
                                .foregroundColor: NSColor.black], range: range)
        }
        nameLabel.attributedStringValue = text
        detailLabel.textColor = isCurrent ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                          owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) { selectUnderPointer(event) }
    override func mouseMoved(with event: NSEvent) { selectUnderPointer(event) }

    private func selectUnderPointer(_ event: NSEvent) {
        guard let window, visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPointerMove(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    @objc private func invoke() { callback() }
}
