import AppKit
import ClawdCore
import ClawdRendering

/// One choice of the Look, Motion and Bubble sections: what a control stands for. Each is one of the right-click menu's own items
/// (MenuModel.swift's walk, motion, look, every, bubble, style, side and size), so a row runs that item's verb under that item's queue key.
public enum SettingsChoice: Hashable {
    /// A look of the catalog by id, or `random` (the look rotates).
    case look(String)
    /// Change the look every this many hours.
    case every(Int)
    /// Clawd's size, as the CLI spells it: 0.5, 0.75, 1, 1.5, 2, 3 or 4.
    case size(String)
    case motion(MotionLevel)
    case walk(Bool)
    case bubble(Bool)
    case side(BubbleSide)
    /// A bubble style chip, 1 to 15: its shown state is on while the style is not excluded.
    case style(Int)
    /// Chat with Claude Code on or off.
    case chat(Bool)
    /// What the chat does when Claude Code needs approval: refuse it, or bypass.
    case permissions(ChatPermissions)
    /// Show Clawd over full-screen apps on or off (`overFullScreen`; read once when the agent starts, so a write restarts the agent).
    case fullScreen(Bool)
    /// React while I dictate on or off (`aquaReact`; read once when the agent starts, so a write restarts the agent).
    case react(Bool)
    /// Only show Clawd while the dictation app runs: on is `follow`, off is `ignore` (`aqua`; restart-only). The window never writes `auto`.
    case follow(Bool)

    public static let random = "random"
    public static let sizes = ["0.5", "0.75", "1", "1.5", "2", "3", "4"]
    public static let everyHours = SchedulerSettings.allowedLookHours

    /// The row whose pending state and line this choice uses.
    public var row: SettingsRow {
        switch self {
        case .look: return .look
        case .every: return .every
        case .size: return .size
        case .motion: return .motion
        case .walk: return .walk
        case .bubble: return .bubble
        case .side: return .side
        case .style(let n): return .style(n)
        case .chat: return .chat
        case .permissions: return .permissions
        case .fullScreen: return .fullScreen
        case .react: return .react
        case .follow: return .follow
        }
    }

    /// The write restarts the agent for about 2 s: the window closes and opens again, and the row says so before it writes.
    public var restartsPet: Bool {
        switch self {
        case .fullScreen, .react, .follow: return true
        default: return false
        }
    }
}

/// What the window's controls show now, for every row: the new state of a control the moment it is pressed, before any write has been applied.
public struct SettingsShown: Equatable {
    public var hidden: Bool
    public var folder: String
    public var selection: MenuSelection
    public var chatOn: Bool
    /// The model as the pet runs with it; empty means Claude Code's own default.
    public var model: String
    public var permissions: ChatPermissions
    public var fullScreen: Bool
    /// Voice: React while I dictate, the mode the switch shows (follow is on) and whether the stored setting is `auto`.
    public var react: Bool
    public var follow: Bool
    public var automatic: Bool

    public init(_ values: SettingsValues) {
        hidden = values.hiddenByUser; folder = values.chatFolder; selection = values.selection
        chatOn = values.chatEnabled; model = values.chatModel; permissions = values.chatPermissions; fullScreen = values.overFullScreen
        react = values.aquaReact; follow = values.aquaFollow; automatic = values.aquaAutomatic
    }

    public func isOn(_ choice: SettingsChoice) -> Bool {
        switch choice {
        case .look(let id): return (selection.lookPin ?? SettingsChoice.random) == id
        case .every(let hours): return selection.lookEveryHours == hours
        case .size(let word): return Double(word) == selection.scale
        case .motion(let level): return selection.motion == level
        case .walk(let on): return selection.walk == on
        case .bubble(let on): return selection.bubble == on
        case .side(let side): return selection.bubbleSide == side
        case .style(let n): return !selection.excludedStyles.contains(n)
        case .chat(let on): return chatOn == on
        case .permissions(let mode): return permissions == mode
        case .fullScreen(let on): return fullScreen == on
        case .react(let on): return react == on
        case .follow(let on): return follow == on
        }
    }

    /// The control pressed takes its new state: a choice becomes the selected one, a style chip turns over.
    public mutating func apply(_ choice: SettingsChoice) {
        switch choice {
        case .look(let id): selection.lookPin = id == SettingsChoice.random ? nil : id
        case .every(let hours): selection.lookEveryHours = hours
        case .size(let word): if let scale = Double(word) { selection.scale = scale }
        case .motion(let level): selection.motion = level
        case .walk(let on): selection.walk = on
        case .bubble(let on): selection.bubble = on
        case .side(let side): selection.bubbleSide = side
        case .style(let n):
            if selection.excludedStyles.contains(n) { selection.excludedStyles.remove(n) } else { selection.excludedStyles.insert(n) }
        case .chat(let on): chatOn = on
        case .permissions(let mode): permissions = mode
        case .fullScreen(let on): fullScreen = on
        case .react(let on): react = on
        case .follow(let on): follow = on; automatic = false
        }
    }

    /// A row whose write is still queued keeps the state it was given, whatever the apply of another row says.
    public mutating func carry(_ row: SettingsRow, from other: SettingsShown) {
        switch row {
        case .hide: hidden = other.hidden
        case .folder: folder = other.folder
        case .chat: chatOn = other.chatOn
        case .model: model = other.model
        case .permissions: permissions = other.permissions
        case .fullScreen: fullScreen = other.fullScreen
        case .react: react = other.react
        case .follow: follow = other.follow; automatic = other.automatic
        case .look: selection.lookPin = other.selection.lookPin
        case .every: selection.lookEveryHours = other.selection.lookEveryHours
        case .size: selection.scale = other.selection.scale
        case .motion: selection.motion = other.selection.motion
        case .walk: selection.walk = other.selection.walk
        case .bubble: selection.bubble = other.selection.bubble
        case .side: selection.bubbleSide = other.selection.bubbleSide
        case .style(let n):
            if other.selection.excludedStyles.contains(n) { selection.excludedStyles.insert(n) } else { selection.excludedStyles.remove(n) }
        }
    }

    /// A write that failed: the row's control goes back to what the pet runs with, and only that row's.
    public mutating func revert(_ row: SettingsRow, to applied: SettingsValues) {
        switch row {
        case .hide: hidden = applied.hiddenByUser
        case .folder: folder = applied.chatFolder
        case .chat: chatOn = applied.chatEnabled
        case .model: model = applied.chatModel
        case .permissions: permissions = applied.chatPermissions
        case .fullScreen: fullScreen = applied.overFullScreen
        case .react: react = applied.aquaReact
        case .follow: follow = applied.aquaFollow; automatic = applied.aquaAutomatic
        case .look: selection.lookPin = applied.selection.lookPin
        case .every: selection.lookEveryHours = applied.selection.lookEveryHours
        case .size: selection.scale = applied.selection.scale
        case .motion: selection.motion = applied.selection.motion
        case .walk: selection.walk = applied.selection.walk
        case .bubble: selection.bubble = applied.selection.bubble
        case .side: selection.bubbleSide = applied.selection.bubbleSide
        case .style(let n):
            if applied.selection.excludedStyles.contains(n) { selection.excludedStyles.insert(n) } else { selection.excludedStyles.remove(n) }
        }
    }
}

/// One look of the catalog as a tile shows it: its id and the menu's own picture of it (Clawd's rest pose in that look; nil when its art cannot be read).
public struct SettingsLookTile: Equatable {
    public let id: String
    public let picture: Raster?
    public init(id: String, picture: Raster?) { self.id = id; self.picture = picture }
}

/// A button of one choice: a chip with a word, a look tile with a picture, or a number. It is drawn by its own layer, so no pop-up or menu is involved.
public final class SettingsChoiceButton: NSButton {
    public let choice: SettingsChoice
    /// The tile's picture (the menu's, unscaled); nil for a chip and for the random tile.
    public let picture: Raster?
    /// A look tile (the random one too) is a 52 pt square; anything else is a chip.
    let isTile: Bool
    private let words: String
    private let fixedWidth: CGFloat?
    private var shownOn = false

    init(choice: SettingsChoice, title: String, accessibility: String, tile: Bool = false, picture: Raster? = nil, width: CGFloat? = nil,
         target: AnyObject, action: Selector) {
        self.choice = choice; self.picture = picture; isTile = tile || picture != nil; words = title; fixedWidth = width
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = picture == nil ? .noImage : .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(accessibility)
        if let picture, let image = Self.image(of: picture) { self.image = image }
        setShown(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    public override var intrinsicContentSize: NSSize {
        if isTile { return NSSize(width: 52, height: 52) }
        let size = (words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        return NSSize(width: fixedWidth ?? ceil(size.width) + 22, height: 26)
    }

    /// The picture at 2 pt to the cell, every cell a sharp square (no smoothing).
    private static func image(of raster: Raster) -> NSImage? {
        guard let cg = try? raster.cgImage() else { return nil }
        return NSImage(size: NSSize(width: 44, height: 44), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .none
            context.draw(cg, in: rect)
            return true
        }
    }

    /// The control shows `on` as selected: the accent fill and a white word, or a quiet chip.
    func setShown(_ on: Bool) {
        shownOn = on
        state = on ? .on : .off
        let accent = SettingsStyle.accent
        if !isTile {
            layer?.backgroundColor = (on ? accent : SettingsStyle.chipFill).cgColor
            layer?.borderColor = (on ? accent : SettingsStyle.cardEdge).cgColor
        } else {
            layer?.backgroundColor = (on ? accent.withAlphaComponent(0.18) : NSColor.clear).cgColor
            layer?.borderColor = (on ? accent : SettingsStyle.cardEdge).cgColor
            layer?.borderWidth = on ? 2 : 1
        }
        paint()
        setAccessibilityValue(on ? "selected" : "not selected")
    }

    public override var isEnabled: Bool { didSet { paint() } }

    private func paint() {
        guard !isTile || picture == nil else { alphaValue = isEnabled ? 1 : 0.4; return }
        let ink: NSColor = !isEnabled ? SettingsStyle.mutedInk : (shownOn && !isTile ? .white : .labelColor)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: isTile ? (words.count > 1 ? 11 : 22) : 12, weight: shownOn ? .semibold : .regular),
                                                                         .foregroundColor: ink, .paragraphStyle: style])
    }
}

// MARK: the sections built from choices

extension SettingsContent {
    static let tileColumns = 6
    static let chipColumns = 8

    /// A control for one choice, remembered by its choice.
    func makeChoice(_ choice: SettingsChoice, title: String, accessibility: String, tile: Bool = false, picture: Raster? = nil,
                    width: CGFloat? = nil) -> SettingsChoiceButton {
        let button = SettingsChoiceButton(choice: choice, title: title, accessibility: accessibility, tile: tile, picture: picture, width: width,
                                          target: self, action: #selector(choicePressed(_:)))
        choiceButtons[choice] = button
        return button
    }

    private func line(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// `views` in lines of at most `columns`.
    private func lines(_ views: [NSView], columns: Int) -> [NSView] {
        stride(from: 0, to: views.count, by: columns).map { line(Array(views[$0..<min($0 + columns, views.count)])) }
    }

    func lookGroups() -> [NSView] {
        var tiles: [NSView] = [makeChoice(.look(SettingsChoice.random), title: "Random", accessibility: "Random look", tile: true)]
        for tile in looks { tiles.append(makeChoice(.look(tile.id), title: "", accessibility: "Look \(tile.id)", picture: tile.picture)) }
        var lookRows = lines(tiles, columns: Self.tileColumns)
        lookRows.append(messageField(for: .look))
        let look = SettingsStyle.group("Look", rows: lookRows)
        var hours: [NSView] = []
        for hour in SettingsChoice.everyHours { hours.append(makeChoice(.every(hour), title: "\(hour)h", accessibility: "Change look every \(hour) hours")) }
        let every = SettingsStyle.group("Change look every", rows: [line(hours), messageField(for: .every)])
        return [look, every]
    }

    /// Clawd's size: placed by `SettingsSection.sizeSection` (Q5).
    func sizeGroup() -> NSView {
        var sizes: [NSView] = []
        for word in SettingsChoice.sizes { sizes.append(makeChoice(.size(word), title: word, accessibility: "Size \(word)", width: 48)) }
        return SettingsStyle.group("Size", rows: [line(sizes), messageField(for: .size)])
    }

    /// "an idle motion every 2 to 5 minutes", from the level's own interval.
    static func intervalWords(_ level: MotionLevel) -> String {
        guard let range = level.interval else { return "no idle motions" }
        let wholeMinutes = range.lowerBound.truncatingRemainder(dividingBy: 60) == 0 && range.upperBound.truncatingRemainder(dividingBy: 60) == 0
        let unit = wholeMinutes ? 60.0 : 1.0
        return "an idle motion every \(Int(range.lowerBound / unit)) to \(Int(range.upperBound / unit)) \(wholeMinutes ? "minutes" : "seconds")"
    }

    private static func capitalized(_ word: String) -> String { String(word.prefix(1)).uppercased() + String(word.dropFirst()) }

    func motionGroups() -> [NSView] {
        var rows: [NSView] = []
        for level in MotionLevel.allCases {
            let button = makeChoice(.motion(level), title: Self.capitalized(level.rawValue), accessibility: "Motion \(level.rawValue)", width: 76)
            rows.append(line([button, SettingsStyle.label(Self.intervalWords(level), size: 12, color: SettingsStyle.muted)]))
        }
        rows.append(messageField(for: .motion))
        let motion = SettingsStyle.group("Motion", rows: rows)
        let walk = SettingsStyle.group("Walk", rows: [
            line([makeChoice(.walk(true), title: "On", accessibility: "Walk on", width: 60), makeChoice(.walk(false), title: "Off", accessibility: "Walk off", width: 60)]),
            messageField(for: .walk)])
        return [motion, walk]
    }

    func bubbleGroups() -> [NSView] {
        let bubble = SettingsStyle.group("Bubble", rows: [
            line([makeChoice(.bubble(true), title: "On", accessibility: "Bubble on", width: 60), makeChoice(.bubble(false), title: "Off", accessibility: "Bubble off", width: 60)]),
            messageField(for: .bubble)])
        var sides: [NSView] = []
        for side in BubbleSide.allCases {
            sides.append(makeChoice(.side(side), title: Self.capitalized(side.rawValue), accessibility: "Bubble side \(side.rawValue)", width: 72))
        }
        let side = SettingsStyle.group("Side", rows: [line(sides), messageField(for: .side)])
        var chips: [NSView] = []
        for n in SchedulerSettings.bubbleStyles {
            let chip = makeChoice(.style(n), title: String(n), accessibility: "Bubble style \(n)", width: 36)
            chip.isEnabled = drawnStyles.contains(n)
            chips.append(chip)
        }
        var styleRows = lines(chips, columns: Self.chipColumns)
        styleRows.append(SettingsStyle.caption("A style that is off never shows. A faded number is not drawn yet."))
        styleRows.append(messageField(for: .style(0)))
        let styles = SettingsStyle.group("Styles", rows: styleRows)
        return [bubble, side, styles]
    }

    /// The Claude Code section (R7: four rows): Chat on or off with its line, Model, Working folder, Permissions.
    func claudeCodeGroups() -> [NSView] {
        let chat = SettingsStyle.group("Chat with Claude Code", rows: [
            line([makeChoice(.chat(true), title: "On", accessibility: "Chat with Claude Code on", width: 60),
                  makeChoice(.chat(false), title: "Off", accessibility: "Chat with Claude Code off", width: 60)]),
            claudeLine, messageField(for: .chat)])
        let model = SettingsStyle.group("Model", rows: [
            modelField, SettingsStyle.caption("Leave it empty for Claude Code's own default."), messageField(for: .model)])
        let folder = SettingsStyle.group("Working folder", rows: [folderLabel, chooseButton, folderMessage])
        let permissions = SettingsStyle.group("Permissions", rows: [
            line([makeChoice(.permissions(.deny), title: "Refuse what needs approval", accessibility: "Refuse what needs approval", width: 190),
                  makeChoice(.permissions(.bypass), title: "Bypass", accessibility: "Bypass permission prompts", width: 90)]),
            SettingsStyle.caption(SettingsContent.permissionsCaption),
            messageField(for: .permissions),
            SettingsStyle.caption("Model, working folder and permissions apply to the next Claude Code session; a running one keeps its flags.")])
        return [chat, model, folder, permissions]
    }

    /// General's "Show Clawd over full-screen apps": On and Off, and the words that say a write restarts the pet, shown before any write.
    func fullScreenGroup() -> NSView {
        SettingsStyle.group("Show Clawd over full-screen apps", rows: [
            line([makeChoice(.fullScreen(true), title: "On", accessibility: "Show Clawd over full-screen apps on", width: 60),
                  makeChoice(.fullScreen(false), title: "Off", accessibility: "Show Clawd over full-screen apps off", width: 60)]),
            SettingsStyle.caption(SettingsContent.restartCaption), messageField(for: .fullScreen)])
    }

    /// The Voice section: a caption, then one group per dictation app (today one), titled with the app's name from its descriptor.
    func voiceGroups() -> [NSView] {
        let react = line([makeChoice(.react(true), title: "On", accessibility: "React while I dictate on", width: 60),
                          makeChoice(.react(false), title: "Off", accessibility: "React while I dictate off", width: 60)])
        let follow = line([makeChoice(.follow(true), title: "On", accessibility: "Only show Clawd while \(source.displayName) runs on", width: 60),
                           makeChoice(.follow(false), title: "Off", accessibility: "Only show Clawd while \(source.displayName) runs off", width: 60)])
        voiceStatusLabel.setAccessibilityLabel("\(source.displayName) status")
        let group = SettingsStyle.group(source.displayName, rows: [
            SettingsStyle.label("Status", size: 12, weight: .medium, color: SettingsStyle.muted), voiceStatusLabel,
            SettingsStyle.label(SettingsVoiceLine.reactTitle, size: 12, weight: .medium, color: SettingsStyle.muted), react, messageField(for: .react),
            SettingsStyle.label(SettingsVoiceLine.followTitle(source), size: 12, weight: .medium, color: SettingsStyle.muted), follow, voiceAutomaticCaption,
            messageField(for: .follow), SettingsStyle.caption(SettingsVoiceLine.restartWords)])
        updateVoice()
        return [SettingsStyle.caption(SettingsVoiceLine.intro), group]
    }

    func aboutGroups() -> [NSView] {
        let image = NSImageView(image: icon ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.setAccessibilityElement(false)
        SettingsStyle.pin([image.widthAnchor.constraint(equalToConstant: 64), image.heightAnchor.constraint(equalToConstant: 64)])
        let words = NSStackView(views: [aboutNameLabel, aboutVersionLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let heading = NSStackView(views: [image, words])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 14
        heading.translatesAutoresizingMaskIntoConstraints = false
        aboutFolderLabel.stringValue = stateFolder
        aboutFolderLabel.lineBreakMode = .byTruncatingMiddle
        aboutFolderLabel.setAccessibilityLabel("Settings folder")
        let folder = SettingsStyle.group("Clawd keeps its settings in", rows: [aboutFolderLabel])
        return [heading, folder]
    }
}
