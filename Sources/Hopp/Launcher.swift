import AppKit
import HoppCore

/// App icons drawn ahead of time off the main thread. The first draw of an `NSWorkspace` icon
/// reads and decodes its .icns file, which for a screen of launcher rows blocks for about a second.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    nonisolated static let pointSize: CGFloat = 24

    private var images: [String: NSImage] = [:]
    private var pending = Set<String>()

    private static func key(_ path: String, _ appearance: NSAppearance.Name) -> String {
        appearance.rawValue + "|" + path
    }

    /// App icons can differ between light and dark, so images are kept per appearance.
    private static var currentAppearance: NSAppearance.Name {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }

    /// The pre-drawn icon, or a plain workspace icon when it is not ready yet.
    func icon(for path: String) -> NSImage {
        if let image = images[Self.key(path, Self.currentAppearance)] { return image }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: Self.pointSize, height: Self.pointSize)
        return icon
    }

    /// Draws the icons missing for the current appearance in the background.
    func warm(_ paths: [String]) {
        let appearance = Self.currentAppearance
        let missing = Array(Set(paths)).filter {
            let key = Self.key($0, appearance)
            return images[key] == nil && !pending.contains(key)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { pending.insert(Self.key($0, appearance)) }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                AppIconCache.render(missing, appearance: appearance, scale: scale)
            }.value
            guard let self else { return }
            let size = NSSize(width: Self.pointSize, height: Self.pointSize)
            for (path, image) in rendered {
                self.images[Self.key(path, appearance)] = NSImage(cgImage: image, size: size)
            }
            missing.forEach { self.pending.remove(Self.key($0, appearance)) }
        }
    }

    nonisolated private static func render(_ paths: [String], appearance: NSAppearance.Name,
                                           scale: CGFloat) -> [(String, CGImage)] {
        let lock = NSLock()
        var results: [(String, CGImage)] = []
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let image = render(paths[index], appearance: appearance, scale: scale) else { return }
            lock.lock()
            results.append((paths[index], image))
            lock.unlock()
        }
        return results
    }

    nonisolated fileprivate static func render(_ path: String, appearance: NSAppearance.Name, scale: CGFloat) -> CGImage? {
        let pixels = Int((pointSize * scale).rounded())
        guard let drawingAppearance = NSAppearance(named: appearance),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Set the point size before creating the context, which takes its scale from it;
        // otherwise the icon is drawn into a quarter of the pixels.
        rep.size = NSSize(width: pointSize, height: pointSize)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawingAppearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

extension AppIconCache {
    /// A drawn icon must fill its whole bitmap, not only the bottom-left quarter.
    nonisolated static func renderSelfCheck() -> Bool {
        guard let image = render("/System/Library/CoreServices/Finder.app", appearance: .aqua, scale: 2)
        else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.pixelsWide == 48 && (rep.colorAt(x: 36, y: 12)?.alphaComponent ?? 0) > 0.5
    }
}

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
            AppIconCache.shared.warm(apps.map(\.path))
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
    /// Rows built before the sheet appears; about eight fit, the rest follow on the next run loop turn.
    private static let initialRows = 10
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
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
    private var renderGeneration = 0

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

        let (root, background) = makeSheetBackground()

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        searchIcon.contentTintColor = .tertiaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        actionLabel.textColor = .labelColor
        let returnKey = KeyCapView(label: "↩")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        let footerDivider = NSBox()
        footerDivider.boxType = .separator

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        for view in [searchIcon, field, scroll, emptyLabel, footerDivider, countLabel, actionLabel, returnKey] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            searchIcon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: sheetHeaderHeight / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: sheetHeaderHeight),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -sheetFooterHeight),
            countLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -sheetFooterHeight / 2),
            returnKey.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            returnKey.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            actionLabel.trailingAnchor.constraint(equalTo: returnKey.leadingAnchor, constant: -8),
            actionLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            actionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        contentView = root
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the sheet once, invisibly, so the first real open does not pay for creating the window
    /// and its glass background.
    func prepare() {
        guard !isVisible else { return }
        alphaValue = 0
        setFrame(NSRect(x: -10_000, y: -10_000, width: 720, height: 400), display: false)
        filter()
        orderFrontRegardless()
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    func show(apps: [AppEntry], language: AppLanguage) {
        self.apps = apps
        self.language = language
        field.stringValue = ""
        field.placeholderString = L10n.text("Search apps", language: language)
        field.setAccessibilityLabel(L10n.text("Search apps", language: language))
        emptyLabel.stringValue = L10n.text("No matching apps", language: language)
        actionLabel.stringValue = L10n.text("Open App", language: language)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            let width = min(720, area.width - 48)
            let height = min(sheetHeaderHeight + 8 * sheetRowHeight + 12 + sheetFooterHeight, area.height - 80)
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
        renderGeneration += 1
        let generation = renderGeneration
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let shown = Array(results.prefix(Self.maxRows).enumerated())
        shown.prefix(Self.initialRows).forEach { addRow($0.element, at: $0.offset, running: running) }
        updateSelection()
        countLabel.stringValue = L10n.format("%@ apps", String(results.count), language: language)
        emptyLabel.isHidden = !results.isEmpty
        contentView?.layoutSubtreeIfNeeded()
        resizeStack()
        guard shown.count > Self.initialRows else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderGeneration == generation else { return }
            shown.dropFirst(Self.initialRows).forEach { self.addRow($0.element, at: $0.offset, running: running) }
            self.updateSelection()
            self.stack.layoutSubtreeIfNeeded()
            self.resizeStack()
            // The selection may have moved past the first rows before they were all built.
            if self.selectedIndex >= Self.initialRows, let row = self.rows.first(where: \.isCurrent) {
                row.scrollToVisible(row.bounds)
            }
        }
    }

    private func addRow(_ match: AppSearch.Match, at index: Int, running: Set<String>) {
        let detail = running.contains(URL(fileURLWithPath: match.app.path).standardizedFileURL.path)
            ? L10n.text("Running", language: language) : match.app.alternateName
        let row = LauncherRow(
            match: match, detail: detail,
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

    private func resizeStack() {
        stack.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1),
                                  height: max(stack.fittingSize.height, scroll.contentSize.height)))
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isCurrent = index == selectedIndex }
    }

    static func smokeCheck() -> Bool {
        guard AppIconCache.renderSelfCheck() else { return false }
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

    init(match: AppSearch.Match, detail: String?,
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
        layer?.cornerRadius = sheetRowCornerRadius
        layer?.cornerCurve = .continuous
        let iconView = NSImageView(image: AppIconCache.shared.icon(for: match.app.path))
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [iconView, nameLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: sheetRowHeight)
        ])
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(detail.map { "\(match.app.name), \($0)" } ?? match.app.name)
        applyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func applyAppearance() {
        layer?.backgroundColor = isCurrent ? resolvedCGColor(sheetSelectionColor) : NSColor.clear.cgColor
        let text = NSMutableAttributedString(string: nameLabel.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ])
        for range in nameRanges {
            text.addAttributes([.backgroundColor: sheetMatchHighlightColor,
                                .foregroundColor: NSColor.black], range: range)
        }
        nameLabel.attributedStringValue = text
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
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
