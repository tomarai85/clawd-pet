import AppKit
import ClawdCore

/// The sections of the sidebar, in R7's order. A section is listed only once it is built.
public enum SettingsSection: String, CaseIterable, Equatable {
    case general, look, motion, bubble, voice, claudeCode = "claude-code", about

    public static let order: [SettingsSection] = [.general, .look, .motion, .bubble, .voice, .claudeCode, .about]
    /// The sections this build has.
    public static let built: Set<SettingsSection> = [.general, .look, .motion, .bubble, .voice, .claudeCode, .about]
    /// Q5: Clawd's size sits in Look. The one place to move it to another section.
    public static let sizeSection: SettingsSection = .look
    public static var listed: [SettingsSection] { order.filter { built.contains($0) } }

    public var title: String {
        switch self {
        case .general: return "General"
        case .look: return "Look"
        case .motion: return "Motion"
        case .bubble: return "Bubble"
        case .voice: return "Voice"
        case .claudeCode: return "Claude Code"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .look: return "paintpalette"
        case .motion: return "figure.walk"
        case .bubble: return "bubble.left"
        case .voice: return "mic"
        case .claudeCode: return "terminal"
        case .about: return "info.circle"
        }
    }
}

/// Claude Code's line under the chat's On and Off, in its five cases (design 4.2): a path set for claude and present or missing, none set and claude
/// found at the default place, found by the search, or found nowhere.
public enum SettingsClaudeLine {
    /// "~/.local/bin, /opt/homebrew/bin or /usr/local/bin", from the search's own list.
    public static var searchedPlaces: String { ChatSettings.searchedPlaces }

    public static func text(for location: ChatSettings.ClaudeLocation) -> String {
        switch location {
        case .given(let path, let resolved): return resolved != nil ? "claude found at \(path)" : "Claude Code not found at \(path)"
        case .defaultPlace: return "claude found at ~/.local/bin/claude"
        case .searched(let path, _): return "claude found at \(path) (found by search, not saved)"
        case .nowhere: return "Claude Code not found in \(searchedPlaces)"
        }
    }
}

/// A row whose control writes: its shown state, its pending state and the line under it.
public enum SettingsRow: Hashable {
    case hide, folder, look, every, size, motion, walk, bubble, side
    /// The Claude Code section's other rows: chat on or off, the model field, and permissions.
    case chat, model, permissions
    /// General's restart-only row: Clawd over full-screen apps.
    case fullScreen
    /// The Voice section's two restart-only rows: React while I dictate, and Only show Clawd while the dictation app runs.
    case react, follow
    /// A bubble style chip; the styles share one line under them.
    case style(Int)

    /// The row whose line this row's message goes to.
    var slot: SettingsRow { if case .style = self { return .style(0) } else { return self } }
}

/// What the window's controls ask of the controller.
protocol SettingsContentDelegate: AnyObject {
    /// The Model field's text, from one of its own handlers (Return, Tab, or a click that moved the focus), trimmed; only when it differs from what the
    /// field showed. Nothing else (the input gate, a close, a lost activation) ever calls this.
    func contentCommittedModel(_ text: String)
    func contentPressedHide()
    func contentPressedQuit()
    func contentPressedChooseFolder()
    func contentChose(_ choice: SettingsChoice)
    func contentSelected(_ section: SettingsSection)
}

/// General's state line, from the first of these that holds: hidden by the user, then the first quiet reason in QuietReason's order, else Shown.
public enum SettingsStateLine {
    /// `hiddenUntil` is the setting's value (-1: until the user shows it; a positive epoch: until then), `wall` the clock's reading. An
    /// `exam-browser` stand-down has no words: Settings is closed and refuses to open for exactly that span.
    public static func text(hiddenUntil: Double, wall: Date, quiet: QuietReason?, timeZone: TimeZone = .current,
                            source: DictationSource = DictationSources.aqua) -> String {
        if hiddenUntil == -1 { return "Hidden until you show it" }
        if hiddenUntil > 0, wall.timeIntervalSince1970 < hiddenUntil {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = timeZone
            format.dateFormat = "HH:mm"
            return "Hidden until " + format.string(from: Date(timeIntervalSince1970: hiddenUntil))
        }
        switch quiet {
        case .systemAsleep?: return "Paused while the Mac sleeps"
        case .displayAsleep?: return "Paused while the display sleeps"
        case .screenLocked?: return "Paused while the screen is locked"
        case .sessionInactive?: return "Paused while another user is active"
        case .notOnActiveSpace?: return "Not shown on this Space"
        case .aquaNotRunning?: return "Waiting for \(source.displayName)"
        case .examBrowser?: return ""
        case nil: return "Shown"
        }
    }
}

/// What Voice's Status line reads about the dictation app: whether it is installed and the version found (nil: none could be read).
public struct SettingsVoiceStatus: Equatable {
    public var installed: Bool
    public var version: String?
    public init(installed: Bool, version: String?) { self.installed = installed; self.version = version }
}

/// The Voice section's words. Every string that names the dictation app takes the name from its descriptor.
public enum SettingsVoiceLine {
    public static let intro = "Dictation apps Clawd reacts to."
    public static let reactTitle = "React while I dictate"
    /// Under the group's two restart-only rows (not General's words, which belong to its own row).
    public static let restartWords = "Changing either setting restarts Clawd for 2 s; this window closes and opens again."
    public static func followTitle(_ source: DictationSource) -> String { "Only show Clawd while \(source.displayName) runs" }
    public static func automatic(_ source: DictationSource) -> String { "Automatic: follows \(source.displayName) if it is installed when Clawd starts and React is on." }
    /// The installed version against the one the log keys were checked with, or "Not installed".
    public static func status(_ source: DictationSource, _ status: SettingsVoiceStatus) -> String {
        guard status.installed else { return "Not installed" }
        guard let version = status.version, !version.isEmpty else { return "Installed, version unknown (Clawd was tested with \(source.testedVersion))" }
        return version == source.testedVersion ? "Installed, version \(version)" : "Installed, version \(version) (Clawd was tested with \(source.testedVersion))"
    }
}

enum SettingsStyle {
    static let accent = NSColor(srgbRed: 0xd7 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    static let sidebarWidth = CGFloat(SettingsGeometry.sidebarWidth)
    static let sidebarFill = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1)
    static let cardFill = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.96, alpha: 1)
    static let cardEdge = NSColor(srgbRed: 0.88, green: 0.87, blue: 0.84, alpha: 1)
    static let contentFill = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let muted = NSColor(srgbRed: 0.45, green: 0.44, blue: 0.41, alpha: 1)
    static let chipFill = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1)
    /// A chip's word when the chip takes no click.
    static let mutedInk = NSColor(srgbRed: 0.68, green: 0.67, blue: 0.64, alpha: 1)

    /// Turns constraints on one by one (the batch call is spelled with the word the lint keeps to the chat's activation file).
    static func pin(_ constraints: [NSLayoutConstraint]) { for constraint in constraints { constraint.isActive = true } }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        field.isEditable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A wrapping caption or message: a label that cannot be edited or selected.
    static func caption(_ text: String, size: CGFloat = 11, color: NSColor = muted) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: size)
        field.textColor = color
        field.isSelectable = false
        field.isEditable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A small caption over a rounded card holding `rows`, one under the other.
    static func group(_ caption: String, rows: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = cardFill.cgColor
        card.layer?.borderColor = cardEdge.cgColor
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        SettingsStyle.pin([
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        let outer = NSStackView(views: [Self.label(caption, size: 11, weight: .medium, color: muted), card])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        return outer
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The sidebar's selected row: a 6 pt rounded highlight in Clawd's accent.
private final class SettingsSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        SettingsStyle.accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// What the Settings window shows: the sidebar, the section on the right, and the controls of each section. It is built when the window opens and
/// dropped when it closes, and it holds no timer or observer.
public final class SettingsContent: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public let root = NSView()
    public let sidebar = NSTableView()
    public private(set) var section: SettingsSection
    let sections: [SettingsSection]
    weak var delegate: SettingsContentDelegate?

    // General
    public let stateLabel = SettingsStyle.label("", size: 13)
    public private(set) var hideButton = NSButton()
    public let hideMessage = SettingsStyle.caption("", color: .systemRed)
    public private(set) var quitButton = NSButton()
    public let quitCaption = SettingsStyle.caption("Clawd comes back at your next login, or when you run clawd-pet start.")
    // Claude Code
    public let folderLabel = SettingsStyle.label("", size: 13)
    public private(set) var chooseButton = NSButton()
    public let folderMessage = SettingsStyle.caption("", color: .systemRed)
    /// "claude found at ..." and its four other cases, under the chat's On and Off.
    public let claudeLine = SettingsStyle.caption("")
    /// Under a restart-only row, before any write.
    public static let restartCaption = "Clawd restarts for 2 s; this window closes and opens again"
    /// Bypass's own words (README's line on it).
    public static let permissionsCaption = "Bypass lets Claude Code act without asking (at your own risk). Otherwise tools that need your approval are refused."
    /// The model: empty means Claude Code's own default. It commits only from its own handlers (see `commitModel`).
    public let modelField = NSTextField()
    /// The text the field was last given (the applied or the committed model): a field whose text still equals it holds no edit of the user's.
    private var modelShown = ""
    // Look, Motion, Bubble: one button per choice, built when its section is first shown.
    var choiceButtons: [SettingsChoice: SettingsChoiceButton] = [:]
    let looks: [SettingsLookTile]
    let drawnStyles: Set<Int>
    private var messageFields: [SettingsRow: NSTextField] = [:]
    private var shown: SettingsShown
    // Voice
    let source: DictationSource
    public let voiceStatusLabel = SettingsStyle.label("", size: 13)
    /// The caption under "Only show Clawd while ... runs" while the stored setting is `auto`.
    public let voiceAutomaticCaption: NSTextField
    private var voiceStatus = SettingsVoiceStatus(installed: true, version: nil)
    /// Whether the running pet reads the dictation app's log (the value it started with): the follow switch is off the table while it does not.
    private var runningReact = true
    // About
    public static let versionLine = "development install"
    let stateFolder: String
    public let aboutNameLabel = SettingsStyle.label("Clawd", size: 20, weight: .semibold)
    public let aboutVersionLabel = SettingsStyle.label(SettingsContent.versionLine, size: 13, color: SettingsStyle.muted)
    public let aboutFolderLabel = SettingsStyle.label("", size: 13)

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let titleLabel = SettingsStyle.label("", size: 18, weight: .semibold)
    /// The shown section's own title (its heading, not the sidebar's cells).
    public var titleLabelText: String { titleLabel.stringValue }
    private var sectionViews: [SettingsSection: NSView] = [:]
    private var pendingRows: Set<SettingsRow> = []
    public let icon: NSImage?

    /// The control that holds the keyboard when the window opens: the sidebar.
    public var initialFirstResponder: NSView { sidebar }

    public init(values: SettingsValues, icon: NSImage?, sections: [SettingsSection], looks: [SettingsLookTile], drawnStyles: Set<Int>, stateFolder: String,
                source: DictationSource = DictationSources.aqua) {
        self.source = source
        voiceAutomaticCaption = SettingsStyle.caption(SettingsVoiceLine.automatic(source))
        self.sections = sections.isEmpty ? [.general] : sections
        section = self.sections[0]
        self.icon = icon
        self.looks = looks
        self.drawnStyles = drawnStyles
        self.stateFolder = stateFolder
        shown = SettingsShown(values)
        super.init()
        hideButton = SettingsStyle.button("Hide for 1 hour", target: self, action: #selector(hidePressed))
        quitButton = SettingsStyle.button("Quit Clawd", target: self, action: #selector(quitPressed))
        chooseButton = SettingsStyle.button("Choose…", target: self, action: #selector(choosePressed))
        hideButton.setAccessibilityLabel("Hide Clawd for one hour or show it")
        quitButton.setAccessibilityLabel("Quit Clawd")
        chooseButton.setAccessibilityLabel("Choose the working folder")
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityLabel("Working folder")
        configureModelField()
        for message in [hideMessage, folderMessage] { message.isHidden = true }
        build()
        refresh(values, shown: shown)
        show(section)
    }

    // MARK: building

    private func build() {
        let sideColumn = NSView()
        sideColumn.wantsLayer = true
        sideColumn.layer?.backgroundColor = SettingsStyle.sidebarFill.cgColor
        sideColumn.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        let name = SettingsStyle.label("Clawd", size: 13, weight: .semibold)
        let header = NSStackView(views: [iconView, name])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = SettingsStyle.sidebarWidth - 16
        column.minWidth = 60
        column.maxWidth = 1000
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .plain
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.rowHeight = 28
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.backgroundColor = .clear
        sidebar.selectionHighlightStyle = .regular
        sidebar.allowsEmptySelection = false
        sidebar.allowsMultipleSelection = false
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Settings sections")
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = false
        sideScroll.borderType = .noBorder
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        sideColumn.addSubview(header)
        sideColumn.addSubview(sideScroll)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = SettingsStyle.cardEdge.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // The section on the right scrolls vertically, with 24 pt by 20 pt padding.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = SettingsStyle.contentFill
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sideColumn)
        root.addSubview(divider)
        root.addSubview(scroll)
        let clip = scroll.contentView
        SettingsStyle.pin([
            sideColumn.topAnchor.constraint(equalTo: root.topAnchor), sideColumn.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideColumn.leadingAnchor.constraint(equalTo: root.leadingAnchor), sideColumn.widthAnchor.constraint(equalToConstant: SettingsStyle.sidebarWidth),
            divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sideColumn.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24), iconView.heightAnchor.constraint(equalToConstant: 24),
            header.topAnchor.constraint(equalTo: sideColumn.topAnchor, constant: 16), header.leadingAnchor.constraint(equalTo: sideColumn.leadingAnchor, constant: 16),
            sideScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), sideScroll.bottomAnchor.constraint(equalTo: sideColumn.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: sideColumn.leadingAnchor, constant: 8),
            sideScroll.trailingAnchor.constraint(equalTo: sideColumn.trailingAnchor, constant: -8),
            document.topAnchor.constraint(equalTo: clip.topAnchor), document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        sidebar.reloadData()
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func makeSectionView(_ section: SettingsSection) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        var groups: [NSView] = []
        switch section {
        case .general:
            let status = SettingsStyle.group("Status", rows: [stateLabel])
            let visibility = SettingsStyle.group("Visibility", rows: [hideButton, hideMessage])
            let quit = SettingsStyle.group("Quit", rows: [quitButton, quitCaption])
            for group in [status, visibility, fullScreenGroup(), quit] {
                content.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        case .claudeCode: groups = claudeCodeGroups()
        case .look: groups = lookGroups()
        case .motion: groups = motionGroups()
        case .bubble: groups = bubbleGroups()
        case .about: groups = aboutGroups()
        case .voice: groups = voiceGroups()
        }
        if section == SettingsSection.sizeSection { groups.append(sizeGroup()) }
        for group in groups {
            content.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        for (choice, button) in choiceButtons { button.setShown(shown.isOn(choice)) }
        return content
    }

    // MARK: showing

    /// Shows one section: its title and its groups.
    public func show(_ wanted: SettingsSection) {
        let target = sections.contains(wanted) ? wanted : sections[0]
        section = target
        titleLabel.stringValue = target.title
        let view = sectionViews[target] ?? makeSectionView(target)
        let firstShown = sectionViews[target] == nil
        sectionViews[target] = view
        for arranged in stack.arrangedSubviews { stack.removeArrangedSubview(arranged); arranged.removeFromSuperview() }
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(view)
        // The width constraint needs both views in the hierarchy, and one is enough for every later show of the same section.
        if firstShown { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true }
        if let index = sections.firstIndex(of: target), sidebar.selectedRow != index { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }

    /// Every control shows `shown` and the state line as the scheduler reads now.
    func refresh(_ values: SettingsValues, shown: SettingsShown) {
        self.shown = shown
        runningReact = values.aquaReact
        updateVoice()
        setStateLine(values.stateLine)
        let title = shown.hidden ? "Show" : "Hide for 1 hour"
        if hideButton.title != title { hideButton.title = title }
        if folderLabel.stringValue != shown.folder { folderLabel.stringValue = shown.folder }
        // The text being typed is never replaced under the user's hands: the field follows the applied model only while it is not being edited.
        if modelText == modelShown, modelShown != shown.model { modelField.stringValue = shown.model; modelShown = shown.model }
        for (choice, button) in choiceButtons { button.setShown(shown.isOn(choice)) }
    }

    /// The line under the chat's On and Off, redrawn only when its text changed.
    func setClaudeLine(_ text: String) {
        if claudeLine.stringValue != text { claudeLine.stringValue = text }
    }

    /// The dictation app's status as the runtime reads it now (at an open and at an apply, never at a scheduler batch).
    public func setVoiceStatus(_ status: SettingsVoiceStatus) {
        voiceStatus = status
        updateVoice()
    }

    /// Voice's lines and the follow switch's enabled state: it is off the table while the running pet runs with React off, and while it shows off
    /// and the app is not installed (it could only hide Clawd for good).
    func updateVoice() {
        let text = SettingsVoiceLine.status(source, voiceStatus)
        if voiceStatusLabel.stringValue != text { voiceStatusLabel.stringValue = text }
        voiceAutomaticCaption.isHidden = !shown.automatic
        let canFollow = runningReact && (shown.follow || voiceStatus.installed)
        for on in [true, false] where choiceButtons[.follow(on)]?.isEnabled != canFollow { choiceButtons[.follow(on)]?.isEnabled = canFollow }
    }

    /// Redrawn only when the text changed.
    func setStateLine(_ text: String) {
        if stateLabel.stringValue != text { stateLabel.stringValue = text }
    }

    func setPending(_ row: SettingsRow, _ pending: Bool, message: String?) {
        if pending { pendingRows.insert(row) } else { pendingRows.remove(row) }
        let field = messageField(for: row)
        if let message { field.stringValue = message; field.isHidden = false } else if !pending { field.stringValue = ""; field.isHidden = true }
    }

    /// A write that no answer is coming for is over: its row leaves the pending state, except the rows whose write is still held.
    func endPending(except held: Set<SettingsRow> = []) { pendingRows.formIntersection(held) }

    public func isPending(_ row: SettingsRow) -> Bool { pendingRows.contains(row) }
    /// The line under a row (empty when none is shown).
    public func message(for row: SettingsRow) -> String { messageField(for: row).stringValue }

    /// The line under a row (the bubble styles share one), made when first asked for.
    func messageField(for row: SettingsRow) -> NSTextField {
        switch row.slot {
        case .hide: return hideMessage
        case .folder: return folderMessage
        case let slot:
            if let field = messageFields[slot] { return field }
            let field = SettingsStyle.caption("", color: .systemRed)
            field.isHidden = true
            messageFields[slot] = field
            return field
        }
    }

    /// The control of a choice (nil until its section has been shown).
    public func button(for choice: SettingsChoice) -> SettingsChoiceButton? { choiceButtons[choice] }

    // MARK: actions

    @objc private func hidePressed() { delegate?.contentPressedHide() }
    @objc private func quitPressed() { delegate?.contentPressedQuit() }
    @objc private func choosePressed() { delegate?.contentPressedChooseFolder() }
    @objc func choicePressed(_ sender: SettingsChoiceButton) { delegate?.contentChose(sender.choice) }

    // MARK: the Model field

    private func configureModelField() {
        modelField.isEditable = true
        modelField.isSelectable = true
        modelField.isBezeled = true
        modelField.bezelStyle = .roundedBezel
        modelField.font = NSFont.systemFont(ofSize: 13)
        modelField.placeholderString = "Claude Code's default"
        modelField.usesSingleLineMode = true
        modelField.lineBreakMode = .byTruncatingTail
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.delegate = self
        modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        // The field sends nothing by itself: its text is committed only by `commitModel`, from Return, Tab and a click that moves the focus.
        (modelField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        modelField.setAccessibilityLabel("Model")
    }

    /// The text the field holds now: the field editor's while editing, else the field's own.
    public var modelText: String { modelField.currentEditor()?.string ?? modelField.stringValue }

    /// The controller took `text` as the model: the field is not holding an edit any more.
    func modelCommitted(_ text: String) { modelShown = text }

    /// The one commit of the Model field: its trimmed text goes to the delegate, which runs `chat model` only when it differs from what the field
    /// showed. Called from Return, Tab and a click that moved the focus, and from nowhere else.
    func commitModel() {
        let raw = modelText, trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != raw {
            if let editor = modelField.currentEditor() { editor.string = trimmed } else { modelField.stringValue = trimmed }
        }
        delegate?.contentCommittedModel(trimmed)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === modelField else { return false }
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitModel()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            commitModel()
            return false
        default:
            return false
        }
    }

    // MARK: the sidebar table

    public func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SettingsSidebarRowView() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sections[row]
        let selected = tableView.selectedRow == row
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = selected ? .white : SettingsStyle.muted
        image.translatesAutoresizingMaskIntoConstraints = false
        image.setAccessibilityElement(false)
        let text = SettingsStyle.label(item.title, size: 12, color: selected ? .white : .labelColor)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        SettingsStyle.pin([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(item.title)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard sections.indices.contains(row) else { return }
        sidebar.reloadData(forRowIndexes: IndexSet(integersIn: 0..<sections.count), columnIndexes: IndexSet(integer: 0))
        if sections[row] != section { delegate?.contentSelected(sections[row]) }
    }
}
