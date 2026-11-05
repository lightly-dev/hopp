import AppKit
import HoppCore

let appAccentColor = NSColor(srgbRed: 80 / 255, green: 151 / 255,
                            blue: 247 / 255, alpha: 1)
// Shared look of the switcher and launcher sheets. Colours are semantic so they follow
// light and dark appearance and Increase Contrast.
let sheetSelectionColor = NSColor.quaternaryLabelColor
let sheetMatchHighlightColor = NSColor.findHighlightColor
let sheetRowHeight: CGFloat = 38
let sheetHeaderHeight: CGFloat = 56
let sheetFooterHeight: CGFloat = 44
let sheetCornerRadius: CGFloat = 20
/// Rows sit 8pt inside the sheet, so their corners stay concentric with it.
let sheetRowCornerRadius = sheetCornerRadius - 8

/// The sheet background: Liquid Glass on macOS 26 and later, the system material before.
/// `root` becomes the window's content view; subviews go into `content`.
@MainActor
func makeSheetBackground() -> (root: NSView, content: NSView) {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = sheetCornerRadius
        let content = NSView()
        glass.contentView = content
        // A key window's glass also tints the window's full rectangle; clip it to the sheet's shape
        // so the corners stay transparent and the shadow follows the rounded outline.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = sheetCornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return (root, content)
    }
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = sheetCornerRadius
    background.layer?.cornerCurve = .continuous
    background.layer?.masksToBounds = true
    return (background, background)
}

/// Where the switcher and the launcher sit: the same width, with their top edge at the same
/// height on the display, so both sheets open in one place. Taller content grows downward.
func sheetFrame(in area: NSRect, contentHeight: CGFloat) -> NSRect {
    let width = max(360, min(720, area.width - 48))
    let top = area.maxY - (area.height * 0.18).rounded()
    let height = min(contentHeight, max(220, top - area.minY - 40))
    return NSRect(x: (area.midX - width / 2).rounded(), y: top - height, width: width, height: height)
}

/// A blinking text cursor for search headers that show a label instead of an editable field.
final class SearchCaretView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color: NSColor
        if #available(macOS 14.0, *) { color = .textInsertionPointColor } else { color = .controlAccentColor }
        layer?.backgroundColor = resolvedCGColor(color)
    }

    /// Shows the caret solid, then blinks like a text field's insertion point.
    func restartBlink() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        blink.fillMode = .backwards
        layer.add(blink, forKey: "blink")
    }
}

extension NSView {
    /// Resolves a dynamic colour for this view's current light or dark appearance, for use on layers.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}

@MainActor
final class SwitcherPanel: NSPanel {
    private let stack = FlippedStackView()
    private let scroll = NSScrollView()
    private let queryLabel = NSTextField(labelWithString: "")
    private let caret = SearchCaretView()
    private var caretOffset: NSLayoutConstraint?
    private let countLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
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

        let (root, background) = makeSheetBackground()

        let header = NSView()
        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        searchIcon.contentTintColor = .tertiaryLabelColor
        queryLabel.font = .systemFont(ofSize: 20)
        queryLabel.lineBreakMode = .byTruncatingTail
        queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [searchIcon, queryLabel, caret] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)

        // Footer: window count on the left, the Return action on the right.
        let footer = NSView()
        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        actionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        actionLabel.textColor = .labelColor
        let returnKey = KeyCapView(label: "↩")
        for view in [footerDivider, countLabel, actionLabel, returnKey] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        footer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(footer)

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
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: sheetHeaderHeight),
            searchIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            searchIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            queryLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
            queryLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -22),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 24),
            caret.centerYAnchor.constraint(equalTo: queryLabel.centerYAnchor),
            caret.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: sheetFooterHeight),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            countLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            returnKey.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            returnKey.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            actionLabel.trailingAnchor.constraint(equalTo: returnKey.leadingAnchor, constant: -8),
            actionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            actionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        contentView = root
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
        queryLabel.textColor = query.isEmpty ? .tertiaryLabelColor : .labelColor
        placeCaret(after: query)
        actionLabel.stringValue = L10n.text("Switch to Window", language: language)
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
                label.font = .systemFont(ofSize: 12, weight: .medium)
                label.textColor = .secondaryLabelColor
                let header = NSStackView(views: [label])
                header.identifier = NSUserInterfaceItemIdentifier("space-header")
                header.orientation = .horizontal
                header.alignment = .bottom
                header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 4, right: 12)
                stack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
                header.heightAnchor.constraint(equalToConstant: 28).isActive = true
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

        let listHeight = CGFloat(totalWindowCount ?? results.count) * sheetRowHeight + CGFloat(sectionCount) * 28 + 12
        setFrame(sheetFrame(in: displayScreen.visibleFrame,
                            contentHeight: max(listHeight, 120) + sheetHeaderHeight + sheetFooterHeight),
                 display: true)
        layoutDocumentView()
        self.selectedRow = selectedRow
        revealSelectedRow()
    }

    /// Before the placeholder like an empty text field, otherwise right after the typed text.
    private func placeCaret(after query: String) {
        let textWidth = query.isEmpty ? 0
            : ceil((query as NSString).size(withAttributes: [.font: queryLabel.font as Any]).width) + 1
        caretOffset?.isActive = false
        let offset = caret.leadingAnchor.constraint(equalTo: queryLabel.leadingAnchor, constant: textWidth + 1)
        offset.priority = .defaultHigh
        offset.isActive = true
        caretOffset = offset
        caret.restartBlink()
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
              stack.arrangedSubviews.allSatisfy({ $0.frame.height <= sheetRowHeight + 0.5 }),
              stack.arrangedSubviews.compactMap({ $0 as? SwitcherRow }).allSatisfy({
                  $0.smokeColumnsAreValid && $0.smokeHitRegionsRouteToRow
                      && $0.smokeSelectionAppearanceIsValid
              }),
              let selectedRow else { return false }
        return frame.width <= 720.5
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
        layer?.cornerRadius = sheetRowCornerRadius
        layer?.cornerCurve = .continuous
        applyFill()
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        appLabel.font = .systemFont(ofSize: 14)
        appLabel.textColor = .secondaryLabelColor
        appLabel.lineBreakMode = .byTruncatingTail
        for (label, ranges) in [(appLabel, match.appRanges), (titleLabel, match.titleRanges)] where !ranges.isEmpty {
            let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
            for range in ranges {
                text.addAttributes([.backgroundColor: sheetMatchHighlightColor,
                                    .foregroundColor: NSColor.black], range: range)
            }
            label.attributedStringValue = text
        }
        // The title gives way first so the app name stays readable next to it.
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appLabel.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        iconView.imageScaling = .scaleProportionallyDown
        [appLabel, iconView, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            appLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            appLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            appLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        target = self
        self.action = #selector(invoke)
        heightAnchor.constraint(equalToConstant: sheetRowHeight).isActive = true
        setAccessibilityLabel("\(window.displayTitle), \(window.appName)")
    }

    required init?(coder: NSCoder) { nil }

    private func applyFill() {
        layer?.backgroundColor = selected ? resolvedCGColor(sheetSelectionColor) : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
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

    fileprivate var smokeHighlighted: Bool { layer?.backgroundColor == resolvedCGColor(sheetSelectionColor) }
    fileprivate func smokePointerMove(_ pointer: NSPoint) { onPointerMove(pointer) }

    private func selectUnderPointer(_ event: NSEvent) {
        guard let window, visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPointerMove(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    fileprivate var smokeColumnsAreValid: Bool {
        iconView.frame.maxX < titleLabel.frame.minX && titleLabel.frame.maxX < appLabel.frame.minX
            && appLabel.frame.maxX <= bounds.maxX
    }

    fileprivate var smokeHitRegionsRouteToRow: Bool {
        let appPoint = appLabel.convert(NSPoint(x: appLabel.bounds.midX, y: appLabel.bounds.midY), to: superview)
        let iconPoint = iconView.convert(NSPoint(x: iconView.bounds.midX, y: iconView.bounds.midY), to: superview)
        let titlePoint = titleLabel.convert(NSPoint(x: titleLabel.bounds.midX, y: titleLabel.bounds.midY), to: superview)
        return hitTest(appPoint) === self && hitTest(iconPoint) === self && hitTest(titlePoint) === self
    }

    fileprivate var smokeSelectionAppearanceIsValid: Bool {
        layer?.backgroundColor == (selected ? resolvedCGColor(sheetSelectionColor) : NSColor.clear.cgColor)
            && titleLabel.textColor == .labelColor && appLabel.textColor == .secondaryLabelColor
    }

    fileprivate var smokeSearchHighlightsAreValid: Bool {
        var highlighted = false
        var valid = true
        for label in [appLabel, titleLabel] {
            let text = label.attributedStringValue
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
                if let background = attributes[.backgroundColor] as? NSColor {
                    highlighted = true
                    valid = valid && background == sheetMatchHighlightColor && attributes[.foregroundColor] as? NSColor == .black
                        && attributes[.underlineStyle] == nil
                } else {
                    valid = valid && attributes[.foregroundColor] as? NSColor
                        == (label === titleLabel ? .labelColor : .secondaryLabelColor)
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

/// A small rounded key cap such as ↩, shown next to an action name.
@MainActor
final class KeyCapView: NSView {
    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = resolvedCGColor(.separatorColor)
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 22),
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = resolvedCGColor(.separatorColor)
    }
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