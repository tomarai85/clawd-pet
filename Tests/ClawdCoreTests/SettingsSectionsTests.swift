import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The Look, Motion, Bubble and About sections of the Settings window (Stage SA, Sprint SA3). Every row runs the right-click menu's verb for the same
// choice under the same queue key, through the one writer and against the stub CLI; nothing here shows a window, makes one key or touches the real
// state directory.

/// The text of every label and caption under `view`.
@MainActor func allLabels(in view: NSView) -> [String] {
    var found: [String] = []
    if let field = view as? NSTextField { found.append(field.stringValue) }
    for sub in view.subviews { found += allLabels(in: sub) }
    return found
}

@MainActor func allTextFields(in view: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    if let field = view as? NSTextField { found.append(field) }
    for sub in view.subviews { found += allTextFields(in: sub) }
    return found
}

/// The writes the writer finished, as its own log lines say (the failure's `write-output` line is not one).
@MainActor func finishedWrites(_ r: SettingsRig) -> Int { r.lines("MENU write ").count }

/// Presses a choice's control and waits until the writer has finished that write; returns the arguments the stub CLI was started with.
@MainActor func pressChoice(_ r: SettingsRig, _ content: SettingsContent, _ choice: SettingsChoice) async throws -> [String] {
    let button = try #require(content.button(for: choice), "no control for \(choice)")
    let before = finishedWrites(r)
    press(button)
    await r.rig.spin(until: { finishedWrites(r) > before }, limit: 60)
    #expect(finishedWrites(r) == before + 1, "\(choice): \(r.lines("MENU"))")
    return r.stub.started.last ?? []
}

/// What the right-click menu runs for the same choice (MenuSelection.action over the menu's own layout).
func menuAction(for choice: SettingsChoice, looks: [String], shownOn: Bool = true) -> MenuAction? {
    let layout = MenuLayout(looks: looks, drawnStyles: StageRuntime.drawnBubbleStyles)
    let key: String, value: String
    var selection = MenuSelection()
    switch choice {
    case .look(let id): key = "look"; value = id
    case .every(let hours): key = "every"; value = "\(hours)h"
    case .size(let word): key = "size"; value = word
    case .motion(let level): key = "motion"; value = level.rawValue
    case .walk(let on): key = "walk"; value = on ? "on" : "off"
    case .bubble(let on): key = "bubble"; value = on ? "on" : "off"
    case .side(let side): key = "side"; value = side.rawValue
    case .style(let n): key = "style"; value = String(n); if shownOn { selection.excludedStyles = [n] }
    case .chat, .permissions, .fullScreen, .react, .follow: return nil      // the right-click menu has no item for the Claude Code rows, Voice or the restart-only row
    }
    guard let item = layout.items.first(where: { $0.key == key && $0.value == value }) else { return nil }
    return selection.action(for: item)
}

/// The verbs of the Interface Contract the Settings window may run, each with the control.json keys it writes: `hide 60` and `show` write
/// `hiddenUntil`, `size` `scale`, `look` `lookPin` and `helmet`, `look-every` `lookEveryHours`, `motion`, `walk`, `bubble on|off` `bubble`,
/// `bubble side` `bubbleSide`, `bubble include|exclude` `bubbleExcluded`, `chat folder` `chatFolder`, `chat on|off` `chat`, `chat permissions` `chatPermissions`,
/// `chat model` `chatModel`.
func isAllowedSettingsVerb(_ args: [String]) -> Bool {
    guard let verb = args.first else { return false }
    let rest = Array(args.dropFirst())
    switch verb {
    case "hide": return rest == ["60"]
    case "show": return rest.isEmpty
    case "size": return rest.count == 1 && SettingsChoice.sizes.contains(rest[0])
    case "look": return rest.count == 1 && !rest[0].isEmpty
    case "look-every": return rest.count == 1 && SettingsChoice.everyHours.map { "\($0)h" }.contains(rest[0])
    case "motion": return rest.count == 1 && MotionLevel(rawValue: rest[0]) != nil
    case "walk": return rest == ["on"] || rest == ["off"]
    case "bubble":
        if rest.count == 1 { return rest[0] == "on" || rest[0] == "off" }
        if rest.count == 2 && rest[0] == "side" { return BubbleSide(rawValue: rest[1]) != nil }
        if rest.count == 2 && (rest[0] == "include" || rest[0] == "exclude") { return Int(rest[1]).map { SchedulerSettings.bubbleStyles.contains($0) } ?? false }
        return false
    case "full-screen": return rest == ["on"] || rest == ["off"]
    case "aqua": return rest == ["follow"] || rest == ["ignore"] || rest == ["react", "on"] || rest == ["react", "off"]
    case "chat":
        if rest.count == 1 { return rest[0] == "on" || rest[0] == "off" }
        guard rest.count == 2 else { return false }
        switch rest[0] {
        case "folder": return true
        case "permissions": return rest[1] == "deny" || rest[1] == "bypass"
        case "model": return !rest[1].isEmpty
        default: return false
        }
    default: return false
    }
}

/// The queue key each choice's pick must carry, written out here and not read back from `SettingsActions`: one per control.json key, the
/// right-click menu's own, and `style-N` for a style chip.
func expectedQueueKey(_ choice: SettingsChoice) -> String {
    switch choice {
    case .look: return "look"
    case .every: return "every"
    case .size: return "size"
    case .motion: return "motion"
    case .walk: return "walk"
    case .bubble: return "bubble"
    case .side: return "side"
    case .style(let n): return "style-\(n)"
    case .chat: return "chat"
    case .permissions: return "chatPermissions"
    case .fullScreen: return "overFullScreen"
    case .react: return "aquaReact"
    case .follow: return "aqua"
    }
}

/// One queue key per control.json key (L-9): the right-click menu's own keys, `style-N` for a style chip, `hide` for Hide and Show.
func isAllowedQueueKey(_ key: String) -> Bool {
    if let n = Int(key.dropFirst("style-".count)), key.hasPrefix("style-") { return SchedulerSettings.bubbleStyles.contains(n) }
    return ["hide", "chatFolder", "chat", "chatPermissions", "chatModel", "overFullScreen", "aquaReact", "aqua", "look", "every", "size", "motion", "walk", "bubble", "side"].contains(key)
}

@Suite("SettingsSections", .serialized)
@MainActor
struct SettingsSectionsSuite {
    private func catalogLooks(_ r: SettingsRig) -> [String] { r.rig.stage.renderer.art.catalog.looks.map(\.id) }

    private func opened() throws -> (SettingsRig, SettingsContent) {
        let r = try SettingsRig(requestSeams: SettingsRestartSuite.rigSeams)
        try r.openFromMenuBar()
        return (r, try #require(r.settings.content))
    }

    // MARK: every row writes only what it shows

    @Test func SettingsSections_everyRowWritesOnlyItsShownKeys() async throws {
        let (r, content) = try opened()
        let looks = catalogLooks(r)
        // Opening Settings and visiting every section writes nothing.
        for section in SettingsSection.listed { content.show(section) }
        await r.rig.spin(0.3)
        #expect(r.cliRuns.isEmpty && r.lines("MENU").isEmpty, "no row writes by being shown: \(r.stub.calls)")
        // Every control of the three sections, pressed once: the verb is on the allowed list and the queue key follows L-9's rule.
        let choices: [SettingsChoice] = [.look(SettingsChoice.random)] + looks.map { .look($0) } + SettingsChoice.everyHours.map { .every($0) }
            + SettingsChoice.sizes.map { .size($0) } + MotionLevel.allCases.map { .motion($0) } + [.walk(true), .walk(false), .bubble(true), .bubble(false)]
            + BubbleSide.allCases.map { .side($0) } + SchedulerSettings.bubbleStyles.map { .style($0) }
            + [.chat(true), .chat(false), .permissions(.deny), .permissions(.bypass), .fullScreen(true), .fullScreen(false)]
            + [.react(true), .react(false), .follow(true), .follow(false)]
        #expect(choices.count == 1 + looks.count + 3 + 7 + 4 + 4 + 4 + 15 + 4 + 2 + 4 && Set(choices).count == choices.count)
        for choice in choices {
            let args = try await pressChoice(r, content, choice)
            #expect(isAllowedSettingsVerb(args), "\(choice) runs \(args), which is not a verb the window may run")
            let action = SettingsActions.action(for: choice, shownOn: content.button(for: choice)?.state == .on)
            #expect(args == action.arguments && isAllowedQueueKey(action.queueKey) && action.queueKey == expectedQueueKey(choice), "\(choice): \(args) vs \(action)")
            let write = try #require(r.lines("MENU write ").last, "\(choice)")
            #expect(write.contains(" key=\(action.key) "), "\(choice) logs its own key: \(write)")
        }
        // General's rows: Hide and Show share the queue key `hide`, the folder's is `chatFolder`.
        let writes = finishedWrites(r)
        press(content.hideButton)
        await r.rig.spin(until: { finishedWrites(r) > writes }, limit: 60)
        #expect(r.stub.started.last == ["hide", "60"], "\(r.stub.started.last ?? [])")
        #expect(isAllowedQueueKey(SettingsActions.hide.queueKey) && isAllowedQueueKey(SettingsActions.show.queueKey) && isAllowedQueueKey(SettingsActions.folder("/x").queueKey))
        #expect(SettingsActions.model("opus").queueKey == "chatModel" && SettingsActions.model("").arguments == ["chat", "model", "default"] && isAllowedQueueKey("chatModel"))
        for verb in [SettingsActions.hide.arguments, SettingsActions.show.arguments, SettingsActions.folder("/x").arguments, SettingsActions.model("opus").arguments,
                     SettingsActions.model("").arguments] {
            #expect(isAllowedSettingsVerb(verb), "\(verb)")
        }
        // No Settings file names a key the window never writes.
        for file in try settingsFiles() where (file.path as NSString).lastPathComponent != "SettingsRun.swift" {
            for key in ["chatView", "chatQueueFollowUps", "chatOutsideClick", "chatPath", "chatClaude", "releaseHintsEnabled", "selectedInputKeyPath", "idleBudgetMode"] {
                #expect(!file.text.contains(key), "\((file.path as NSString).lastPathComponent) names \(key), a key the window never writes")
            }
        }
        // The key each row really submitted (not one rebuilt from the choice): with the writer held, one choice of every queue key queues behind the
        // one that runs and nothing is dropped; the same choice pressed again replaces its waiting pick, and only that.
        let gate = r.stub.root.appendingPathComponent("release")
        try r.stub.set("stub-release", gate.path)
        let perKey: [SettingsChoice] = [.look(looks[0]), .every(2), .size("2"), .motion(.quiet), .walk(true), .bubble(true), .side(.left), .chat(true), .permissions(.bypass), .fullScreen(true), .react(false), .follow(true)]
            + SchedulerSettings.bubbleStyles.map { .style($0) }
        #expect(Set(perKey.map(expectedQueueKey)).count == perKey.count, "one choice per queue key")
        let dropsBefore = r.lines("MENU drop").count, held = finishedWrites(r)
        let refusesBefore = r.lines("MENU refuse").count
        var expected: [[String]] = []
        for choice in perKey {
            let button = try #require(content.button(for: choice), "\(choice)")
            press(button)
            expected.append(SettingsActions.action(for: choice, shownOn: button.state == .on).arguments)
        }
        #expect(r.lines("MENU drop").count == dropsBefore, "every row has a queue key of its own, so no pick replaced another: \(r.lines("MENU drop"))")
        press(try #require(content.button(for: .size("3"))))
        #expect(r.lines("MENU drop").count == dropsBefore + 1, "the same key twice drops exactly one: \(r.lines("MENU drop"))")
        // The newer size pick replaces the older one, which never runs. (SA5-1b design r6, B3) Rules 2 and 3: while .fullScreen(true) waits,
        // .react(false) and .follow(true) are refused at their submit with a log line and run nothing, and every live pick, the size re-press among
        // them, goes in before the waiting restart pick, which runs last.
        let at = { (choice: SettingsChoice) in perKey.firstIndex(of: choice)! }
        let restartArgs = expected[at(.fullScreen(true))]
        let refusedArgs = [expected[at(.react(false))], expected[at(.follow(true))]]
        let gone = [at(.size("2")), at(.fullScreen(true)), at(.react(false)), at(.follow(true))]
        expected = expected.enumerated().filter { !gone.contains($0.offset) }.map(\.element) + [["size", "3"], restartArgs]
        let refuses = Array(r.lines("MENU refuse").dropFirst(refusesBefore))
        #expect(refuses.count == 2 && refuses.allSatisfy { $0.contains(" why=restart-queued by=") }, "react and follow are refused at their submit: \(refuses)")
        let byIDs = Set(refuses.compactMap { $0.components(separatedBy: " by=").last?.components(separatedBy: " ").first })
        try r.stub.set("release", "")
        await r.rig.spin(until: { finishedWrites(r) >= held + perKey.count - 2 }, limit: 60)
        #expect(finishedWrites(r) == held + perKey.count - 2, "every held pick ran but the two refused ones: \(r.lines("MENU"))")
        #expect(Array(r.stub.started.suffix(perKey.count - 2)) == expected, "\(r.stub.started)")
        #expect(!r.stub.started.suffix(perKey.count - 2).contains { refusedArgs.contains($0) }, "a refused pick ran: \(r.stub.started)")
        #expect(byIDs.count == 1 && r.lines("MENU write ").contains { line in byIDs.contains { line.contains("id=\($0) ") } && line.contains("full-screen") },
                "both refusals name the waiting full-screen pick: \(refuses) \(r.lines("MENU write "))")
        // The allowed list itself refuses what it must.
        for bad in [["chat", "view", "on"], ["chat", "queue", "on"], ["bubble", "exclude", "16"], ["size", "5"], ["hide", "0"], ["idle", "off"], []] {
            #expect(!isAllowedSettingsVerb(bad), "\(bad)")
        }
    }

    // MARK: Look

    @Test func SettingsSections_lookTilesRunTheRightClickVerbs() async throws {
        let (r, content) = try opened()
        let looks = catalogLooks(r)
        let art = r.rig.stage.renderer.art
        content.show(.look)
        #expect(looks.count > 3 && looks.contains("helmet"), "\(looks)")
        // Random plus one tile per look of the catalog, with the menu's own picture of it, and no tooltip.
        let ids = [SettingsChoice.random] + looks
        for id in ids {
            let tile = try #require(content.button(for: .look(id)), "no tile for \(id)")
            #expect(tile.toolTip == nil, "\(id): a tile has no tooltip")
            if id == SettingsChoice.random {
                #expect(tile.picture == nil && tile.attributedTitle.string == "Random", "the random tile is titled Random")
            } else {
                let expected = try MenuThumbnails.thumbnail(look: id, art: art)
                #expect(tile.picture == expected && tile.image != nil, "\(id): the tile carries the menu's picture of the look")
            }
        }
        // The tile of what the pet runs with is the selected one, and a settings change made elsewhere moves it.
        #expect(content.button(for: .look(SettingsChoice.random))?.state == .on && content.button(for: .look(looks[1]))?.state == .off)
        try writeControlLikeTheCLI(r.rig.store.root, ["lookPin": looks[1]])
        await r.rig.spin(until: { content.button(for: .look(looks[1]))?.state == .on }, limit: 20)
        #expect(content.button(for: .look(looks[1]))?.state == .on && content.button(for: .look(SettingsChoice.random))?.state == .off)
        // Each tile runs the right-click menu's verb for the same look, helmet included, under the menu's queue key.
        for id in ids {
            let choice = SettingsChoice.look(id)
            let args = try await pressChoice(r, content, choice)
            let menu = try #require(menuAction(for: choice, looks: looks), "the menu has no item for \(id)")
            #expect(args == ["look", id] && args == menu.arguments, "\(id): \(args) vs the menu's \(menu.arguments)")
            #expect(SettingsActions.action(for: choice, shownOn: true) == menu, "\(id)")
        }
        // Change look every 2h, 3h or 4h, and Size 0.5, 0.75, 1, 1.5, 2, 3, 4 (Q5: Size sits in Look).
        #expect(SettingsSection.sizeSection == .look)
        #expect(SettingsChoice.everyHours.map { content.button(for: .every($0))?.attributedTitle.string } == ["2h", "3h", "4h"], "the chips read 2h, 3h, 4h")
        let words = allLabels(in: content.root).joined(separator: " | ")
        #expect(!words.contains("lets Clawd change look"), "no caption under the tiles: \(words)")
        for hours in SettingsChoice.everyHours {
            let choice = SettingsChoice.every(hours)
            let args = try await pressChoice(r, content, choice)
            #expect(args == ["look-every", "\(hours)h"] && SettingsActions.action(for: choice, shownOn: true) == menuAction(for: choice, looks: looks), "\(hours): \(args)")
        }
        for word in SettingsChoice.sizes {
            let choice = SettingsChoice.size(word)
            let args = try await pressChoice(r, content, choice)
            #expect(args == ["size", word] && SettingsActions.action(for: choice, shownOn: true) == menuAction(for: choice, looks: looks), "\(word): \(args)")
        }
        // A control shows its new state at once, before the write has been applied.
        let before = finishedWrites(r)
        press(try #require(content.button(for: .size("3"))))
        #expect(content.button(for: .size("3"))?.state == .on && content.button(for: .size("4"))?.state == .off)
        await r.rig.spin(until: { finishedWrites(r) > before }, limit: 20)
    }

    // MARK: Motion, Walk and Bubble

    @Test func SettingsSections_motionWalkAndBubbleRunTheRightClickVerbs() async throws {
        let (r, content) = try opened()
        let looks = catalogLooks(r)
        content.show(.bubble)
        // Motion: each level with its interval, read from the level itself.
        content.show(.motion)
        let words = allLabels(in: content.root)
        for (level, text) in [(MotionLevel.off, "no idle motions"), (.quiet, "an idle motion every 2 to 5 minutes"), (.normal, "an idle motion every 45 to 100 seconds"),
                              (.lively, "an idle motion every 6 to 15 seconds")] {
            #expect(words.contains(text), "\(level): \(words)")
        }
        let choices: [SettingsChoice] = MotionLevel.allCases.map { .motion($0) } + [.walk(true), .walk(false), .bubble(true), .bubble(false)]
            + BubbleSide.allCases.map { .side($0) }
        for choice in choices {
            let args = try await pressChoice(r, content, choice)
            let menu = try #require(menuAction(for: choice, looks: looks), "\(choice)")
            #expect(args == menu.arguments && SettingsActions.action(for: choice, shownOn: true) == menu, "\(choice): \(args) vs \(menu.arguments)")
        }
        // The styles: a chip turned off runs `exclude N`, turned on `include N`, under the key `style-N`.
        for n in SchedulerSettings.bubbleStyles {
            let choice = SettingsChoice.style(n)
            let off = try await pressChoice(r, content, choice)
            #expect(off == ["bubble", "exclude", String(n)] && content.button(for: choice)?.state == .off, "style \(n): \(off)")
            #expect(SettingsActions.action(for: choice, shownOn: false) == menuAction(for: choice, looks: looks, shownOn: false), "style \(n)")
            let on = try await pressChoice(r, content, choice)
            #expect(on == ["bubble", "include", String(n)] && content.button(for: choice)?.state == .on, "style \(n): \(on)")
            #expect(SettingsActions.action(for: choice, shownOn: true) == menuAction(for: choice, looks: looks, shownOn: true), "style \(n)")
            #expect(SettingsActions.action(for: choice, shownOn: true).queueKey == "style-\(n)")
        }
        // The controls follow the applied settings: a change made in the terminal moves them.
        try writeControlLikeTheCLI(r.rig.store.root, ["motion": "lively", "walk": false, "bubbleSide": "left", "bubbleExcluded": [3]])
        await r.rig.spin(until: { r.runtime.menuSelection().bubbleSide == .left }, limit: 20)
        #expect(r.runtime.menuSelection().bubbleSide == .left, "\(r.runtime.menuSelection())")
        #expect(content.button(for: .motion(.lively))?.state == .on && content.button(for: .motion(.quiet))?.state == .off)
        #expect(content.button(for: .walk(false))?.state == .on && content.button(for: .walk(true))?.state == .off)
        #expect(content.button(for: .side(.left))?.state == .on && content.button(for: .side(.below))?.state == .off, "the side follows the applied settings")
        #expect(content.button(for: .style(3))?.state == .off && content.button(for: .style(4))?.state == .on, "the excluded style follows the applied settings")
        // A style the art does not draw yet is muted and takes no click, as in the menu.
        let partial = SettingsContent(values: SettingsValues(), icon: nil, sections: SettingsSection.listed, looks: [], drawnStyles: Set(1...12), stateFolder: "/x")
        partial.show(.bubble)
        for n in SchedulerSettings.bubbleStyles { #expect(partial.button(for: .style(n))?.isEnabled == (n <= 12), "style \(n)") }
        let muted = try #require(content.button(for: .style(15)))
        muted.isEnabled = false
        let writes = finishedWrites(r), runs = r.stub.started.count
        press(muted)
        await r.rig.spin(0.3)
        #expect(finishedWrites(r) == writes && r.stub.started.count == runs && muted.state == .on, "a muted chip writes nothing")
    }

    @Test func SettingsSections_aRefusedExclusionKeepsTheChipOn() async throws {
        let (r, content) = try opened()
        content.show(.bubble)
        let seven = try #require(content.button(for: .style(7))), three = try #require(content.button(for: .style(3)))
        #expect(seven.state == .on && three.state == .on)
        // A chip the CLI took stays off.
        _ = try await pressChoice(r, content, .style(3))
        #expect(three.state == .off)
        // The CLI refuses the last of styles 1-12: the chip shows the new state at once, then goes back on with the CLI's one line under it.
        try r.stub.set("stub-exit", "1")
        let before = finishedWrites(r)
        press(seven)
        #expect(seven.state == .off && content.isPending(.style(7)), "the chip is off at once")
        await r.rig.spin(until: { finishedWrites(r) > before && !content.isPending(.style(7)) }, limit: 30)
        #expect(seven.state == .on, "the refused exclusion puts the chip back on")
        #expect(content.message(for: .style(7)) == "the stub fails with 1", "\(content.message(for: .style(7)))")
        #expect(three.state == .off, "another chip keeps the state it was given")
        // The next accepted write clears the line.
        try r.stub.set("stub-exit", "0")
        _ = try await pressChoice(r, content, .style(5))
        #expect(content.message(for: .style(7)) == "", "\(content.message(for: .style(7)))")
    }

    @Test func SettingsSections_twoClicksOnAChipBeforeTheFirstAppliesEndOnTheLastClick() async throws {
        let (r, content) = try opened()
        content.show(.bubble)
        let chip = try #require(content.button(for: .style(7)))
        #expect(chip.state == .on)
        try r.stub.set("stub-delay", "0.4")
        // Style 7 is on; two clicks land before the first write has been applied.
        press(chip)
        press(chip)
        #expect(chip.state == .on, "off, then on again: the control ends on the last click")
        await r.rig.spin(until: { finishedWrites(r) >= 2 }, limit: 60)
        #expect(r.stub.started == [["bubble", "exclude", "7"], ["bubble", "include", "7"]], "the verbs come from the control's own states: \(r.stub.started)")
        #expect(chip.state == .on && !content.isPending(.style(7)), "style 7 ends on")
        // An unrelated apply leaves it on. Motion is shown, so its own chip can only turn on by the apply.
        content.show(.motion)
        #expect(content.button(for: .motion(.lively))?.state == .off, "lively is not the applied motion yet")
        try writeControlLikeTheCLI(r.rig.store.root, ["motion": "lively"])
        await r.rig.spin(until: { r.runtime.menuSelection().motion == .lively }, limit: 20)
        #expect(r.runtime.menuSelection().motion == .lively, "the apply landed: \(r.runtime.menuSelection())")
        #expect(content.button(for: .motion(.lively))?.state == .on, "the apply reached the controls")
        #expect(chip.state == .on)
    }

    @Test func SettingsSections_anApplyOfAnotherRowKeepsAQueuedPicksShownState() async throws {
        let (r, content) = try opened()
        content.show(.bubble)
        let five = try #require(content.button(for: .style(5))), seven = try #require(content.button(for: .style(7)))
        try r.stub.set("stub-delay", "0.4")
        // Chip 5 runs; chip 7 waits behind it. The CLI of 5 writes control.json as the real one does, and the pet applies it while 7 still waits.
        press(five)
        press(seven)
        #expect(seven.state == .off && content.isPending(.style(7)))
        try writeControlLikeTheCLI(r.rig.store.root, ["bubbleExcluded": [5]])
        await r.rig.spin(until: { r.runtime.menuSelection().excludedStyles.contains(5) }, limit: 20)
        #expect(r.runtime.menuSelection().excludedStyles == [5], "the apply of 5 landed: \(r.runtime.menuSelection())")
        #expect(seven.state == .off && content.isPending(.style(7)), "another row's apply leaves the queued pick's chip as it was shown")
        // Two quick clicks on 7 end on the last click: the second one reads the chip's own state, so it is an include.
        press(seven)
        #expect(seven.state == .on)
        await r.rig.spin(until: { finishedWrites(r) >= 2 }, limit: 60)
        #expect(r.stub.started.last == ["bubble", "include", "7"], "\(r.stub.started)")
        #expect(seven.state == .on && !content.isPending(.style(7)))
    }

    /// SA3 fix recheck M-1a: a row's own apply lands while its pick is held, and another writer then writes the same key. The control must show what
    /// the pet runs with once the pick's verb has exited 0, not the pick.
    @Test func SettingsSections_aRowsControlShowsTheAppliedStateAfterItsVerbExitsZero() async throws {
        let (r, content) = try opened()
        content.show(.bubble)
        let left = try #require(content.button(for: .side(.left))), above = try #require(content.button(for: .side(.above)))
        let gate = r.stub.root.appendingPathComponent("release")
        try r.stub.set("stub-release", gate.path)
        press(left)
        #expect(left.state == .on && content.isPending(.side), "the pick shows at once and is pending")
        // The pick's own apply lands while its CLI is still held, then another writer writes the same key and the pet applies that too.
        try writeControlLikeTheCLI(r.rig.store.root, ["bubbleSide": "left"])
        await r.rig.spin(until: { r.runtime.menuSelection().bubbleSide == .left }, limit: 20)
        try writeControlLikeTheCLI(r.rig.store.root, ["bubbleSide": "above"])
        await r.rig.spin(until: { r.runtime.menuSelection().bubbleSide == .above }, limit: 20)
        #expect(r.runtime.menuSelection().bubbleSide == .above, "the other writer's apply landed: \(r.runtime.menuSelection())")
        #expect(left.state == .on && content.isPending(.side), "while the pick is held, its control keeps showing it")
        // The verb exits 0: the control shows the applied state, once.
        try r.stub.set("release", "")
        await r.rig.spin(until: { finishedWrites(r) >= 1 && !content.isPending(.side) }, limit: 60)
        #expect(finishedWrites(r) == 1 && !content.isPending(.side), "\(r.lines("MENU"))")
        #expect(above.state == .on && left.state == .off, "after exit 0 the control shows what the pet runs with (above), not the pick (left)")
        // A pick no apply came for (the stub CLI writes nothing) keeps the state it was shown: there is nothing to re-sync from.
        _ = try await pressChoice(r, content, .side(.below))
        #expect(content.button(for: .side(.below))?.state == .on && above.state == .off)
    }

    // MARK: About

    @Test func SettingsSections_aboutShowsTheStateFolderAndDevelopmentInstall() throws {
        let (r, content) = try opened()
        for section in [SettingsSection.look, .motion, .bubble, .about] { content.show(section) }
        #expect(content.section == .about)
        #expect(content.aboutNameLabel.stringValue == "Clawd")
        #expect(content.aboutVersionLabel.stringValue == "development install" && SettingsContent.versionLine == "development install")
        #expect(content.aboutFolderLabel.stringValue == r.rig.store.root.path, "\(content.aboutFolderLabel.stringValue)")
        // The folder's path is a plain label that cannot be selected (or edited), and so is every other text of every section.
        #expect(!content.aboutFolderLabel.isSelectable && !content.aboutFolderLabel.isEditable)
        for section in SettingsSection.listed {
            content.show(section)
            // The Model field is the one text a section lets the user edit (Claude Code, SA4).
            for field in allTextFields(in: content.root) where field !== content.modelField {
                #expect(!field.isSelectable && !field.isEditable, "\(section): \"\(field.stringValue)\" can be selected or edited")
            }
        }
        content.show(.about)
        // The folder label's text is a path of the machine the test runs on (a clean copy's folder carries `clawd-update-<sha>`); every other label is scanned.
        let folderPath = content.aboutFolderLabel.stringValue
        let text = allLabels(in: content.root).filter { $0 != folderPath }.joined(separator: " | ").lowercased()
        for word in ["publish", "release", "update", "version 1", "signed"] { #expect(!text.contains(word), "About says nothing about \(word): \(text)") }
        // Clawd's idle frame is the plain look's: the picture the sidebar's header shows.
        #expect(r.runtime.settingsIcon() != nil && content.icon != nil)
        #expect(r.lines("SETTINGS").allSatisfy { !$0.contains(r.rig.store.root.path) }, "no log line carries the folder's path")
    }

    // MARK: the sidebar

    @Test func SettingsSections_sidebarOrderIsR7sOrder() throws {
        let (r, content) = try opened()
        // R7: General, Look, Motion, Bubble, Voice, Claude Code, About; every section is built from SA6 on.
        #expect(SettingsSection.order == [.general, .look, .motion, .bubble, .voice, .claudeCode, .about])
        #expect(SettingsSection.listed == [.general, .look, .motion, .bubble, .voice, .claudeCode, .about])
        #expect(content.sidebar.numberOfRows == 7)
        var titles: [String] = []
        for row in 0..<content.sidebar.numberOfRows {
            let cell = content.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            titles.append(cell?.textField?.stringValue ?? "?")
        }
        #expect(titles == ["General", "Look", "Motion", "Bubble", "Voice", "Claude Code", "About"], "\(titles)")
        // Each row shows its own section.
        for (row, section) in SettingsSection.listed.enumerated() {
            content.sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            #expect(r.settings.section == section, "row \(row)")
            #expect(content.titleLabelText == section.title, "\(section): the section's own title is \"\(content.titleLabelText)\"")
        }
        // Each open starts at General.
        r.settings.close(.button)
        try r.openFromMenuBar()
        #expect(r.settings.section == .general)
    }

    // MARK: no timer

    @Test func SettingsSections_openAndUntouchedArmsNoTimer() async throws {
        let r = try SettingsRig()
        let armed = r.rig.stage.wake.armedTimers
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        let timers = r.focus.timers.live.count
        for section in SettingsSection.listed { content.show(section); content.root.layoutSubtreeIfNeeded() }
        content.show(.general)
        await r.rig.spin(0.5)
        #expect(r.focus.timers.live.count == timers && r.focus.liveObservers == 1, "no section arms a timer or an observer: \(r.focus.timers.live)")
        #expect(r.rig.stage.wake.armedTimers <= max(armed, 1) && r.cliRuns.isEmpty && r.lines("MENU").isEmpty)
        // No Settings file creates a timer, an animation, a dispatch source, a delayed call, an observer or a tracking area. The runtime half above
        // sees only the seams (the fake focus deadlines and the stage's wake timers); a timer a section makes for itself is seen by this word scan.
        let words = [#"\bTimer\b"#, "scheduledTimer", "NSTimer", "CADisplayLink", "DispatchSource", "asyncAfter", "NSAnimationContext", #"\.animator\(\)"#, "addObserver",
                     "NSEvent.add", "NSTrackingArea", "CABasicAnimation", "CAKeyframeAnimation", "CAAnimationGroup",
                     #"afterDelay:"#, #"Task\.sleep"#, "NSAnimation", "NSViewAnimation", "CVDisplayLink", "startAnimation"]
        // SettingsRun.swift is the headless settings mode, not the window.
        let files = try settingsFiles().filter { ($0.path as NSString).lastPathComponent != "SettingsRun.swift" }
        #expect(files.contains { ($0.path as NSString).lastPathComponent == "SettingsChoices.swift" } && files.contains { ($0.path as NSString).lastPathComponent == "SettingsSections.swift" })
        for file in files {
            let code = file.text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if let comment = line.range(of: "//") { return String(line[line.startIndex..<comment.lowerBound]) }
                return String(line)
            }.joined(separator: "\n")
            for word in words {
                #expect(code.range(of: word, options: .regularExpression) == nil, "\((file.path as NSString).lastPathComponent) names \(word)")
            }
        }
        // The scan sees a planted timer.
        for planted in ["let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }", "perform(#selector(go), with: nil, afterDelay: 1)",
                        "try await Task.sleep(nanoseconds: 1)", "let a = NSViewAnimation()", "var link: CVDisplayLink?", "spinner.startAnimation(nil)"] {
            #expect(words.contains { planted.range(of: $0, options: .regularExpression) != nil }, "the scan misses: \(planted)")
        }
    }
}
