import AppKit
import HoppCore

let appAccentColor = NSColor(srgbRed: 80 / 255, green: 151 / 255,
                            blue: 247 / 255, alpha: 1)

@MainActor
final class SwitcherPanel: NSPanel {
    private let stack = FlippedStackView()
    private let scroll = NSScrollView()
    private let queryLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "")
    private let emptyState = NSStackView()
    private let onActivate: (String) -> Void
    private let onSelect: (String) -> Void
    private let displayScreen: NSScreen
    private weak var selectedRow: SwitcherRow?
    private var hoverOrigin = NSEvent.mouseLocation

    init(screen: NSScreen, onActivate: @escaping (String) -> Void,
         onSelect: @escaping (String) -> Void) {
        self.displayScreen = screen
        self.onActivate = onActivate
        self.onSelect = onSelect
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .aqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let header = NSView()
        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        queryLabel.font = .systemFont(ofSize: 13)
        queryLabel.lineBreakMode = .byTruncatingTail
        queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator
        for view in [searchIcon, queryLabel, countLabel, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)

        let emptyIcon = NSImageView()
        emptyIcon.image = searchIcon.image
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        emptyTitle.font = .systemFont(ofSize: 13)
        emptyTitle.textColor = .secondaryLabelColor
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyHint].forEach { emptyState.addArrangedSubview($0) }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(emptyState)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            searchIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            queryLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            queryLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        contentView = background
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(results: [WindowSearch.Match], selectedIndex: Int, query: String = "",
              groupBySpace: Bool = false,
              totalWindowCount: Int? = nil, language: AppLanguage = .system) {
        update(results: results, selectedIndex: selectedIndex, resetHover: true,
               groupBySpace: groupBySpace, query: query, totalWindowCount: totalWindowCount, language: language)
        orderFrontRegardless()
        layoutDocumentView()
        revealSelectedRow()
    }

    func update(results: [WindowSearch.Match], selectedIndex: Int, resetHover: Bool = false,
                groupBySpace: Bool = false,
                query: String = "", totalWindowCount: Int? = nil, language: AppLanguage = .system) {
        if resetHover {
            hoverOrigin = NSEvent.mouseLocation
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        queryLabel.stringValue = query.isEmpty ? L10n.text("Type an app name or window title", language: language) : query
        queryLabel.textColor = query.isEmpty ? .secondaryLabelColor : .labelColor
        queryLabel.setAccessibilityLabel(L10n.text("Window search", language: language))
        countLabel.stringValue = L10n.format(query.isEmpty ? "%@ windows" : "%@ results",
                                            String(results.count), language: language)
        emptyTitle.stringValue = L10n.text("No matching windows", language: language)
        emptyHint.stringValue = L10n.text("Try an app name or window title", language: language)
        emptyState.isHidden = !results.isEmpty
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var selectedRow: SwitcherRow?
        var sectionCount = 0
        var previousSpaceID: UInt64?
        for (index, match) in results.enumerated() {
            let window = match.window
            if groupBySpace, index == 0 || previousSpaceID != window.space?.id {
                let title: String
                if let space = window.space {
                    title = L10n.format(space.isFullscreen ? "Full screen %@" : "Desktop %@", String(space.index), language: language)
                        + (space.isCurrent ? " · " + L10n.text("Current", language: language) : "")
                } else {
                    title = L10n.text("Current desktop", language: language)
                }
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.setContentHuggingPriority(.required, for: .horizontal)
                let line = NSBox()
                line.boxType = .separator
                let header = NSStackView(views: [label, line])
                header.identifier = NSUserInterfaceItemIdentifier("space-header")
                header.orientation = .horizontal
                header.alignment = .centerY
                header.spacing = 8
                stack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
                header.heightAnchor.constraint(equalToConstant: 26).isActive = true
                sectionCount += 1
            }
            previousSpaceID = window.space?.id
            let row = SwitcherRow(
                match: match, selected: index == selectedIndex,
                onPointerMove: { [weak self] pointer in
                    guard self?.canHover(at: pointer) == true else { return }
                    self?.onSelect(window.id)
                },
                action: { [weak self] in self?.onActivate(window.id) }
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            if index == selectedIndex { selectedRow = row }
        }

        let area = displayScreen.visibleFrame
        let width = max(320, min(600, area.width - 48))
        let height = min(max(CGFloat(totalWindowCount ?? results.count) * 28 + CGFloat(sectionCount) * 26 + 16, 100) + 40,
                         max(140, area.height - 80))
        setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                        width: width, height: height), display: true)
        layoutDocumentView()
        self.selectedRow = selectedRow
        revealSelectedRow()
    }

    func hideSwitcher() {
        orderOut(nil)
    }

    private func canHover(at pointer: NSPoint) -> Bool {
        guard pointer != hoverOrigin else { return false }
        hoverOrigin = pointer
        return true
    }

    private func layoutDocumentView() {
        contentView?.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        stack.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1),
                                  height: max(fitting.height, scroll.contentSize.height)))
        stack.layoutSubtreeIfNeeded()
    }

    private func revealSelectedRow() {
        guard let selectedRow else { return }
        selectedRow.scrollToVisible(selectedRow.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    fileprivate var smokeLayoutIsValid: Bool {
        guard stack.arrangedSubviews.count >= 12,
              stack.arrangedSubviews.allSatisfy({ $0.frame.height <= 28.5 }),
              stack.arrangedSubviews.compactMap({ $0 as? SwitcherRow }).allSatisfy({
                  $0.smokeColumnsAreValid && $0.smokeHitRegionsRouteToRow
                      && $0.smokeSelectionAppearanceIsValid
              }),
              let selectedRow else { return false }
        return frame.width <= 600.5
            && frame.height <= displayScreen.visibleFrame.height - 79
            && stack.frame.height > scroll.contentSize.height
            && scroll.contentView.bounds.intersects(selectedRow.convert(selectedRow.bounds, to: scroll.contentView))
    }

    fileprivate var smokeLayoutDescription: String {
        let selectedRect = selectedRow.map { $0.convert($0.bounds, to: scroll.contentView) } ?? .zero
        let rows = stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }
        return "frame=\(frame) stack=\(stack.frame) clip=\(scroll.contentView.bounds) selected=\(selectedRect) columns=\(rows.filter { !$0.smokeColumnsAreValid }.count) hits=\(rows.filter { !$0.smokeHitRegionsRouteToRow }.count) rows=\(stack.arrangedSubviews.map { $0.frame.height })"
    }

    fileprivate func smokeMove(to index: Int, pointer: NSPoint) {
        let rows = stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }
        guard rows.indices.contains(index) else { return }
        rows[index].smokePointerMove(pointer)
    }

    fileprivate var smokeHighlightedIndices: [Int] {
        stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }.enumerated().compactMap {
            $0.element.smokeHighlighted ? $0.offset : nil
        }
    }

    fileprivate var smokeHoverOrigin: NSPoint { hoverOrigin }

    fileprivate var smokeSearchHeader: (query: String, count: String, empty: Bool, hasSelection: Bool) {
        (queryLabel.stringValue, countLabel.stringValue, !emptyState.isHidden, selectedRow != nil)
    }

    fileprivate var smokeSearchHighlightsAreValid: Bool {
        stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }.allSatisfy { $0.smokeSearchHighlightsAreValid }
    }

    fileprivate var smokeSpaceHeaders: [String] {
        stack.arrangedSubviews.filter { $0.identifier?.rawValue == "space-header" }.compactMap {
            $0.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
        }
    }

    fileprivate var smokeTextLayouts: [[NSRect]] {
        stack.arrangedSubviews.compactMap { ($0 as? SwitcherRow)?.smokeTextLayout }
    }
}

@MainActor
private final class SwitcherRow: NSButton {
    private let callback: () -> Void
    private let appLabel: NSTextField
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let selected: Bool
    private let onPointerMove: (NSPoint) -> Void
    private var trackingArea: NSTrackingArea?

    init(match: WindowSearch.Match, selected: Bool, onPointerMove: @escaping (NSPoint) -> Void,
         action: @escaping () -> Void) {
        let window = match.window
        callback = action
        self.onPointerMove = onPointerMove
        appLabel = NSTextField(labelWithString: window.appName)
        iconView = NSImageView(image: applicationIcon(for: window))
        titleLabel = NSTextField(labelWithString: window.displayTitle)
        self.selected = selected
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? appAccentColor.cgColor : NSColor.clear.cgColor
        let textColor = selected ? NSColor.white : NSColor.labelColor
        appLabel.alignment = .right
        appLabel.font = .systemFont(ofSize: 13)
        appLabel.textColor = textColor
        appLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        titleLabel.textColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        for (label, ranges) in [(appLabel, match.appRanges), (titleLabel, match.titleRanges)] where !ranges.isEmpty {
            let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
            for range in ranges {
                text.addAttributes([.backgroundColor: NSColor(srgbRed: 1, green: 229 / 255,
                                                              blue: 138 / 255, alpha: 1),
                                    .foregroundColor: NSColor.black], range: range)
            }
            label.attributedStringValue = text
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.imageScaling = .scaleProportionallyDown
        [appLabel, iconView, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            appLabel.widthAnchor.constraint(equalToConstant: 150),
            iconView.leadingAnchor.constraint(equalTo: appLabel.trailingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        target = self
        self.action = #selector(invoke)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setAccessibilityLabel("\(window.appName), \(window.displayTitle)")
    }

    required init?(coder: NSCoder) { nil }

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

    fileprivate var smokeHighlighted: Bool { layer?.backgroundColor == appAccentColor.cgColor }
    fileprivate func smokePointerMove(_ pointer: NSPoint) { onPointerMove(pointer) }

    private func selectUnderPointer(_ event: NSEvent) {
        guard let window, visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPointerMove(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    fileprivate var smokeColumnsAreValid: Bool {
        appLabel.alignment == .right && appLabel.frame.maxX < iconView.frame.minX
            && iconView.frame.maxX < titleLabel.frame.minX
    }

    fileprivate var smokeHitRegionsRouteToRow: Bool {
        let appPoint = appLabel.convert(NSPoint(x: appLabel.bounds.midX, y: appLabel.bounds.midY), to: superview)
        let iconPoint = iconView.convert(NSPoint(x: iconView.bounds.midX, y: iconView.bounds.midY), to: superview)
        let titlePoint = titleLabel.convert(NSPoint(x: titleLabel.bounds.midX, y: titleLabel.bounds.midY), to: superview)
        return hitTest(appPoint) === self && hitTest(iconPoint) === self && hitTest(titlePoint) === self
    }

    fileprivate var smokeSelectionAppearanceIsValid: Bool {
        selected
            ? layer?.backgroundColor == appAccentColor.cgColor
                && appLabel.textColor == .white && titleLabel.textColor == .white
            : layer?.backgroundColor == NSColor.clear.cgColor
                && appLabel.textColor == .labelColor && titleLabel.textColor == .labelColor
    }

    fileprivate var smokeSearchHighlightsAreValid: Bool {
        var highlighted = false
        var valid = true
        let yellow = NSColor(srgbRed: 1, green: 229 / 255, blue: 138 / 255, alpha: 1)
        for label in [appLabel, titleLabel] {
            let text = label.attributedStringValue
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
                if let background = attributes[.backgroundColor] as? NSColor {
                    highlighted = true
                    valid = valid && background == yellow && attributes[.foregroundColor] as? NSColor == .black
                        && attributes[.underlineStyle] == nil
                } else {
                    valid = valid && attributes[.foregroundColor] as? NSColor == (selected ? .white : .labelColor)
                }
            }
        }
        return highlighted && valid && (selected ? smokeHighlighted : !smokeHighlighted)
    }

    fileprivate var smokeTextLayout: [NSRect] {
        [appLabel, titleLabel].flatMap { label in
            [label.frame, label.attributedStringValue.boundingRect(
                with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin])]
        }
    }

    @objc private func invoke() { callback() }
}

@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private func applicationIcon(for window: WindowInfo) -> NSImage {
    resolvedApplicationIcon(for: window) ?? fallbackApplicationIcon(for: window)
}

@MainActor
private func resolvedApplicationIcon(for window: WindowInfo) -> NSImage? {
    let source = NSRunningApplication(processIdentifier: window.processID)?.icon
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: window.appID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    guard let source else { return nil }
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 24, height: 24)
    return icon
}

@MainActor
private func fallbackApplicationIcon(for window: WindowInfo) -> NSImage {
    let source = NSImage(systemSymbolName: "macwindow", accessibilityDescription: window.displayTitle)
        ?? NSImage(size: NSSize(width: 24, height: 24))
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 24, height: 24)
    return icon
}
@MainActor
enum PanelSmokeCheck {
    static func run() -> Bool {
        _ = NSApplication.shared
        guard WindowService.focusSelfCheck() else { return fail("focused window changes were not published") }
        guard WindowService.closingSelfCheck() else { return fail("window close affected another window") }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let windows = (0..<200).map {
            WindowInfo(id: "smoke-\($0)", appID: "smoke", appName: "Smoke",
                       title: "Window \($0) " + String(repeating: "Long title ", count: 40),
                       processID: ProcessInfo.processInfo.processIdentifier)
        }
        let switcherWindows = windows
        let switcherResults = WindowSearch.filter(switcherWindows, query: "")
        var selectedIDs: [String] = []
        let switcher = SwitcherPanel(screen: screen, onActivate: { _ in },
                                      onSelect: { selectedIDs.append($0) })
        let initialIndex = switcherWindows.count - 1
        switcher.show(results: switcherResults, selectedIndex: initialIndex)
        switcher.contentView?.layoutSubtreeIfNeeded()
        let origin = switcher.smokeHoverOrigin
        let initial = switcher.smokeLayoutIsValid && switcher.smokeHighlightedIndices == [initialIndex]
        switcher.smokeMove(to: 0, pointer: origin)
        let still = selectedIDs.isEmpty && switcher.smokeHighlightedIndices == [initialIndex]
        switcher.smokeMove(to: 0, pointer: NSPoint(x: origin.x + 1, y: origin.y))
        let moved = selectedIDs == [switcherWindows[0].id]
        switcher.update(results: switcherResults, selectedIndex: 0)
        let mouseSelected = switcher.smokeHighlightedIndices == [0]
        switcher.update(results: switcherResults, selectedIndex: 1, resetHover: true)
        let keyboardSelected = switcher.smokeHighlightedIndices == [1]
        switcher.smokeMove(to: 0, pointer: switcher.smokeHoverOrigin)
        let keyboardHeld = selectedIDs.count == 1 && switcher.smokeHighlightedIndices == [1]
        switcher.smokeMove(to: 2, pointer: NSPoint(x: switcher.smokeHoverOrigin.x + 1,
                                                   y: switcher.smokeHoverOrigin.y))
        let movedAgain = selectedIDs == [switcherWindows[0].id, switcherWindows[2].id]
        switcher.update(results: switcherResults, selectedIndex: 2)
        let mouseSelectedAgain = switcher.smokeHighlightedIndices == [2]
        switcher.show(results: switcherResults, selectedIndex: initialIndex)
        switcher.smokeMove(to: 0, pointer: switcher.smokeHoverOrigin)
        let reset = selectedIDs.count == 2 && switcher.smokeHighlightedIndices == [initialIndex]
        let originalFrame = switcher.frame
        let searchQuery = "smoke 199"
        let searchWindows = WindowSearch.filter(switcherWindows, query: searchQuery)
        switcher.update(results: searchWindows, selectedIndex: 0, resetHover: true, query: "  " + searchQuery + "  ",
                        totalWindowCount: switcherWindows.count, language: .zh)
        let searched = searchWindows.count == 1 && switcher.frame == originalFrame
            && switcher.smokeSearchHeader.query == searchQuery && switcher.smokeSearchHeader.count == "1 个结果"
            && !switcher.smokeSearchHeader.empty && switcher.smokeHighlightedIndices == [0]
            && switcher.smokeSearchHighlightsAreValid
        switcher.smokeMove(to: 0, pointer: switcher.smokeHoverOrigin)
        let searchKeptSelection = selectedIDs.count == 2
        switcher.update(results: [], selectedIndex: 0, query: "zzzz",
                        totalWindowCount: switcherWindows.count, language: .zh)
        let noResults = switcher.frame == originalFrame && switcher.smokeSearchHeader.empty
            && switcher.smokeSearchHeader.count == "0 个结果" && switcher.smokeHighlightedIndices.isEmpty
            && !switcher.smokeSearchHeader.hasSelection
        switcher.update(results: switcherResults, selectedIndex: initialIndex, language: .en)
        switcher.update(results: switcherResults, selectedIndex: initialIndex, query: " \t ", language: .en)
        let cleared = switcher.smokeSearchHeader.query == "Type an app name or window title"
            && switcher.smokeSearchHeader.count == "200 windows" && !switcher.smokeSearchHeader.empty
            && switcher.smokeLayoutIsValid && switcher.smokeHighlightedIndices == [initialIndex]
        let valid = initial && still && moved && mouseSelected && keyboardSelected
            && keyboardHeld && movedAgain && mouseSelectedAgain && reset
            && searched && searchKeptSelection && noResults && cleared
        let longTitleWindows = [
            WindowInfo(id: "long-title", appID: "chrome", appName: "Google Chrome",
                       title: String(repeating: "Open window search and a long browser title — ", count: 20),
                       processID: 0),
            WindowInfo(id: "long-app", appID: "long-app",
                       appName: String(repeating: "OpenOffice ", count: 20), title: "Open a document", processID: 0)
        ]
        let longTitleResults = WindowSearch.filter(longTitleWindows, query: "")
        let longTitleSearchResults = WindowSearch.filter(longTitleWindows, query: "open")
        for selected in longTitleWindows.indices {
            switcher.update(results: longTitleResults, selectedIndex: selected)
            let normalTextLayouts = switcher.smokeTextLayouts
            switcher.update(results: longTitleSearchResults, selectedIndex: selected, query: "open")
            guard switcher.smokeTextLayouts == normalTextLayouts else {
                let searchedLayouts = switcher.smokeTextLayouts
                switcher.hideSwitcher()
                switcher.close()
                return fail("search changed long text layout: normal=\(normalTextLayouts) search=\(searchedLayouts)")
            }
        }
        let desktopWindows = [
            WindowInfo(id: "current-space", appID: "Editor", appName: "Editor", title: "Project", processID: 0,
                       space: WindowSpace(id: 2, index: 2, isCurrent: true)),
            WindowInfo(id: "other-space", appID: "Browser", appName: "Browser", title: "Project", processID: 0,
                       space: WindowSpace(id: 1, index: 1, isCurrent: false))
        ]
        let grouped = WindowSwitcher.filter(desktopWindows, query: "", allSpaces: true)
        switcher.show(results: grouped, selectedIndex: 1, groupBySpace: true, language: .zh)
        switcher.contentView?.layoutSubtreeIfNeeded()
        guard switcher.smokeSpaceHeaders == ["桌面 2 · 当前", "桌面 1"],
              switcher.smokeHighlightedIndices == [1] else {
            switcher.close()
            return fail("desktop headers or window selection indices mismatch")
        }
        switcher.smokeMove(to: 0, pointer: NSPoint(x: switcher.smokeHoverOrigin.x + 1, y: switcher.smokeHoverOrigin.y))
        guard selectedIDs.last == "current-space" else {
            switcher.close()
            return fail("desktop header intercepted window hover selection")
        }
        switcher.update(results: WindowSwitcher.filter(desktopWindows, query: "browser", allSpaces: true),
                        selectedIndex: 0, groupBySpace: true, query: "browser", language: .zh)
        guard switcher.smokeSpaceHeaders == ["桌面 1"], switcher.smokeHighlightedIndices == [0] else {
            switcher.close()
            return fail("desktop search retained empty groups")
        }
        switcher.update(results: grouped, selectedIndex: 0, groupBySpace: false)
        guard switcher.smokeSpaceHeaders.isEmpty else {
            switcher.close()
            return fail("desktop labels remained after disabling grouping")
        }
        switcher.hideSwitcher()
        switcher.close()
        guard valid else { return fail("switcher layout mismatch: \(switcher.smokeLayoutDescription)") }
        return LauncherPanel.smokeCheck() ? true : fail("app launcher search, selection or launch mismatch")
    }

    private static func fail(_ message: String) -> Bool {
        FileHandle.standardError.write(Data("PanelSmokeCheck failed: \(message)\n".utf8))
        return false
    }
}