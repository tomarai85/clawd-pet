import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

func menuItem(_ layout: MenuLayout, _ key: String, _ value: String) -> MenuItem {
    guard let item = layout.items.first(where: { $0.key == key && $0.value == value }) else { fatalError("no menu item \(key)/\(value)") }
    return item
}
func menuSettings(_ json: String) -> AppliedSettings {
    guard let settings = AppliedSettings.parse(Data(json.utf8)) else { fatalError("settings do not parse: \(json)") }
    return settings
}

/// The right-click menu as numbers and pictures (spec 5.2, ruling 4 of round 1): the mock's layout, what a point hits, what a pick runs,
/// what is selected, where the menu opens, and the picture in the mock's four states.
@Suite("MenuTests", .serialized)
struct MenuTests {
    static let looks = stageRenderer.art.catalog.looks.map(\.id)
    static let layout = MenuLayout(looks: looks, drawnStyles: Set(SchedulerSettings.bubbleStyles))

    // MARK: layout

    @Test func Menu_theCatalogHasFifteenLooksSoTheLookRowWrapsToThreeLines() {
        #expect(Self.looks.count == 15, "\(Self.looks)")
        #expect(Self.looks.first == "plain" && Self.looks.contains("helmet"))
    }

    @Test func Menu_theLayoutIsTheMocksBoxModelInPoints() {
        let layout = Self.layout
        #expect(layout.size == CGSize(width: 236, height: 335), "face padding 3 + rows 20 20 86 20 74 20 20 + separator 7 + hide 20 + settings 20 + quit 20 + 3, inside a 1 pt edge (the bubble row has three lines of chips; the side row has one)")
        let rows = layout.rows.map { ($0.key, $0.rect.minY, $0.rect.height) }
        let expected: [(String, Double, Double)] = [("walk", 4, 20), ("motion", 24, 20), ("look", 44, 86), ("every", 130, 20), ("bubble", 150, 74),
                                                   ("side", 224, 20), ("size", 244, 20), ("hide", 271, 20), ("settings", 291, 20), ("quit", 311, 20)]
        #expect(rows.count == expected.count)
        for (got, want) in zip(rows, expected) { #expect(got.0 == want.0 && got.1 == want.1 && got.2 == want.2, "\(got) vs \(want)") }
        #expect(layout.rows.allSatisfy { $0.rect.minX == 1 && $0.rect.width == 234 }, "a row runs from face edge to face edge")
        #expect(layout.separator == CGRect(x: 6, y: 267, width: 224, height: 1), "3 pt margins, inset 5 pt")
        // Chips: 2 pt padding either side of the text (one font pixel = 2 pt), 16 pt high, 4 pt apart, from x = 6 + 52 + 4.
        #expect(menuItem(layout, "walk", "on").rect == CGRect(x: 62, y: 6, width: 18, height: 16))
        #expect(menuItem(layout, "walk", "off").rect == CGRect(x: 84, y: 6, width: 26, height: 16))
        let motion = ["off": 62.0, "quiet": 92, "normal": 134, "lively": 186], widths = ["off": 26.0, "quiet": 38, "normal": 48, "lively": 38]
        for (value, x) in motion { #expect(menuItem(layout, "motion", value).rect == CGRect(x: x, y: 26, width: widths[value]!, height: 16), "\(value)") }
        #expect(["2h", "3h", "4h"].map { menuItem(layout, "every", $0).rect.minX } == [62, 84, 106])
        let sizeXs = ["0.5", "0.75", "1", "1.5", "2", "3", "4"].map { menuItem(layout, "size", $0).rect.minX }
        #expect(sizeXs == [62, 88, 122, 136, 162, 176, 190], "\(sizeXs)")
        #expect(menuItem(layout, "size", "1.5").rect.width == 22 && menuItem(layout, "size", "1.5").rect.minY == 246)
        #expect(menuItem(layout, "hide", "60").rect == CGRect(x: 1, y: 271, width: 234, height: 20) && menuItem(layout, "hide", "60").label == "Hide for 1 hour")
        // The side row sits directly under the bubble row: four chips, below, above, left and right, on one line.
        #expect(layout.rows.firstIndex { $0.key == "bubble" }.map { layout.rows[$0 + 1].key } == "side")
        #expect(layout.items.filter { $0.key == "side" }.map(\.value) == ["below", "above", "left", "right"])
        #expect(Set(layout.items.filter { $0.key == "side" }.map { $0.rect.minY }).count == 1, "the four chips share one line")
    }

    @Test func MenuLayout_settingsAndQuitRowsFollowTheHideRow() {
        let layout = Self.layout
        #expect(layout.rows.suffix(3).map(\.key) == ["hide", "settings", "quit"], "the two rows come after Hide for 1 hour")
        let settings = menuItem(layout, "settings", "open"), quit = menuItem(layout, "quit", "quit")
        #expect(settings.rect == CGRect(x: 1, y: 291, width: 234, height: 20) && settings.label == "Settings\u{2026}" && settings.kind == .action && settings.clickable)
        #expect(quit.rect == CGRect(x: 1, y: 311, width: 234, height: 20) && quit.label == "Quit Clawd" && quit.kind == .action && quit.clickable)
        #expect(layout.size == CGSize(width: 236, height: 335), "about 335 pt with the two rows")
        #expect(layout.items.last == quit)
        // Every row above keeps its rectangle: the same layout built before the rows is the prefix of this one.
        #expect(Array(layout.rows.prefix(8)).map { [$0.key, "\($0.rect.minY)", "\($0.rect.height)"] }
                    == [["walk", "4.0", "20.0"], ["motion", "24.0", "20.0"], ["look", "44.0", "86.0"], ["every", "130.0", "20.0"], ["bubble", "150.0", "74.0"],
                        ["side", "224.0", "20.0"], ["size", "244.0", "20.0"], ["hide", "271.0", "20.0"]])
        // They are whole-row actions the controller routes before `action(for:)`, which answers nil, and they are never shown as selected.
        let selection = MenuSelection()
        #expect(selection.action(for: settings) == nil && selection.action(for: quit) == nil && !selection.isSelected(settings) && !selection.isSelected(quit))
        #expect(PixelFont.supports("\u{2026}"), "the pixel font draws the ellipsis")
        #expect(layout.hit(at: CGPoint(x: settings.rect.midX, y: settings.rect.midY)) == .item(settings))
    }

    @Test func Menu_theLookTilesAre26PointSquaresTwoApartSixToALine() {
        let layout = Self.layout
        let tiles = layout.items.filter { $0.key == "look" }
        #expect(tiles.map(\.value) == ["random"] + Self.looks, "the random tile first, then every look in catalog order")
        #expect(tiles.allSatisfy { $0.rect.width == 26 && $0.rect.height == 26 && $0.kind == .tile })
        #expect(tiles[0].rect == CGRect(x: 62, y: 46, width: 26, height: 26) && tiles[0].label == "\u{273B}")
        #expect(tiles[5].rect == CGRect(x: 62 + 5 * 28, y: 46, width: 26, height: 26), "the sixth tile ends the first line")
        #expect(tiles[6].rect == CGRect(x: 62, y: 74, width: 26, height: 26), "and the seventh starts the second")
        #expect(tiles[15].rect == CGRect(x: 62 + 3 * 28, y: 102, width: 26, height: 26))
    }

    @Test func Menu_theStyleChipsAreEighteenWideInSixColumnsTwoApart() {
        let layout = Self.layout
        let styles = layout.items.filter { $0.key == "style" }
        #expect(styles.map(\.value) == (1...15).map(String.init))
        #expect(styles.allSatisfy { $0.rect.width == 18 && $0.rect.height == 16 && $0.kind == .styleChip })
        #expect(styles[0].rect == CGRect(x: 62, y: 170, width: 18, height: 16), "below the on/off chips, 2 pt margin")
        #expect(styles[5].rect.minX == 62 + 5 * 20 && styles[5].rect.minY == 170)
        #expect(styles[6].rect == CGRect(x: 62, y: 188, width: 18, height: 16), "the seventh wraps to a second line")
        #expect(styles[12].rect == CGRect(x: 62, y: 206, width: 18, height: 16) && styles[14].rect == CGRect(x: 102, y: 206, width: 18, height: 16), "the thirteenth starts a third line of 13, 14 and 15")
        #expect(menuItem(layout, "bubble", "on").rect.minY == 152 && menuItem(layout, "bubble", "off").rect.minX == 84)
    }

    @Test func Menu_aShortCatalogMakesTheMocksOwnPanel() {
        // The mock lists plain, helmet, sunglasses and headphones: one line of five tiles: a 201 pt panel with twelve styles, 219 pt with fifteen (a third line of chips).
        let mock = MenuLayout(looks: ["plain", "helmet", "sunglasses", "headphones"], drawnStyles: [1, 6, 10])
        #expect(mock.size.height == 279, "239 pt before the Settings… and Quit Clawd rows, 40 pt more with them")
        #expect(mock.rows.first { $0.key == "look" }?.rect.height == 30)
        #expect(MenuLayout(looks: [], drawnStyles: []).items.filter { $0.key == "look" }.map(\.value) == ["random"])
    }

    @Test func Menu_lookTilesWrapAtAnyCountAndNothingOverlapsOrLeavesThePanel() {
        for count in [0, 1, 5, 6, 7, 11, 12, 13, 17, 40] {
            let layout = MenuLayout(looks: (0..<count).map { "look\($0)" }, drawnStyles: Set(SchedulerSettings.bubbleStyles))
            let lines = (count + 1 + 5) / 6
            let wanted = max(20, Double(lines) * 26 + Double(lines - 1) * 2 + 4)
            #expect(layout.rows.first { $0.key == "look" }.map { Double($0.rect.height) } == wanted, "\(count) looks")
            let panel = CGRect(origin: .zero, size: layout.size)
            for (i, a) in layout.items.enumerated() {
                #expect(panel.contains(a.rect), "\(count) looks: \(a.key)/\(a.value) is inside the panel")
                #expect(layout.rows[a.row].rect.contains(a.rect), "\(a.key)/\(a.value) is inside its row")
                for b in layout.items[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.key)/\(a.value) overlaps \(b.key)/\(b.value)") }
            }
            #expect(layout.items.last?.rect.maxY ?? 0 <= layout.size.height - 4, "the quit row is the last thing before the face's padding")
        }
    }

    // MARK: hit testing

    @Test func Menu_aPointHitsTheItemUnderItAndOnlyThatOne() {
        let layout = Self.layout
        for item in layout.items {
            let centre = CGPoint(x: item.rect.midX, y: item.rect.midY)
            #expect(layout.hit(at: centre) == .item(item), "\(item.key)/\(item.value)")
            #expect(layout.hit(at: CGPoint(x: item.rect.minX, y: item.rect.minY)) == .item(item), "its top-left pixel")
            #expect(layout.hit(at: CGPoint(x: item.rect.maxX - 0.5, y: item.rect.maxY - 0.5)) == .item(item), "its bottom-right pixel")
        }
        #expect(layout.item(at: CGPoint(x: menuItem(layout, "walk", "on").rect.midX, y: 12)) == menuItem(layout, "walk", "on"))
    }

    @Test func Menu_thingsThatAreNotItemsAreGapsOrTheSeparator() {
        let layout = Self.layout
        let on = menuItem(layout, "walk", "on"), off = menuItem(layout, "walk", "off")
        #expect(layout.hit(at: CGPoint(x: on.rect.maxX + 2, y: on.rect.midY)) == .gap, "the 4 pt between two chips")
        #expect(layout.hit(at: CGPoint(x: 20, y: on.rect.midY)) == .gap, "a row's label")
        #expect(layout.hit(at: CGPoint(x: off.rect.maxX + 10, y: off.rect.midY)) == .gap, "the empty end of a row")
        #expect(layout.hit(at: CGPoint(x: 100, y: 2)) == .gap, "the edge and the face's top padding")
        #expect(layout.hit(at: CGPoint(x: 100, y: layout.size.height - 2)) == .gap)
        #expect(layout.hit(at: CGPoint(x: 0, y: 0)) == .gap, "a notched corner")
        #expect(layout.hit(at: CGPoint(x: -5, y: 40)) == .gap && layout.hit(at: CGPoint(x: 400, y: 40)) == .gap, "outside the panel")
        #expect(layout.hit(at: CGPoint(x: 100, y: layout.separator.midY)) == .separator)
        #expect(layout.hit(at: CGPoint(x: 100, y: layout.separator.minY - 2)) == .separator, "its margin")
        #expect(layout.hit(at: CGPoint(x: 3, y: layout.separator.midY)) == .gap, "left of the inset line")
        #expect(layout.hit(at: CGPoint(x: 100, y: 130 + 10)) != .separator)
        // The whole hide row picks, not only its text.
        #expect(layout.hit(at: CGPoint(x: 220, y: 278)) == .item(menuItem(layout, "hide", "60")))
    }

    /// Amendment R-BUBBLES D-10: the Bubble row grows by one line of chips, 13, 14 and 15, in the same 18 pt chips; whether a chip takes a click follows the
    /// drawn set (an undrawn id is muted, like the ids that were not drawn before).
    @Test func MenuLayout_theBubbleRowHasFifteenStyleChipsInThreeLines() {
        let layout = Self.layout
        let chips = layout.items.filter { $0.key == "style" }
        #expect(chips.count == SchedulerSettings.bubbleStyles.count && chips.count == 15 && chips.map(\.value) == (1...15).map(String.init))
        #expect(Set(chips.map(\.rect.minY)).count == 3, "three lines of chips")
        #expect(chips.filter { $0.rect.minY == chips[0].rect.minY }.count == 6 && chips.filter { $0.rect.minY == chips[12].rect.minY }.map(\.value) == ["13", "14", "15"])
        let row = layout.rows.first { $0.key == "bubble" }!
        #expect(row.rect.height == 74 && layout.rows.first { $0.key == "bubble" }!.rect.height - 56 == 18, "one chip line (16 pt and the 2 pt gap) taller")
        // clickability follows the drawn set
        let upToTwelve = MenuLayout(looks: ["plain"], drawnStyles: Set(1...12))
        for n in 13...15 { #expect(!menuItem(upToTwelve, "style", String(n)).clickable, "style \(n) is muted until it is drawn") }
        for n in 1...12 { #expect(menuItem(upToTwelve, "style", String(n)).clickable) }
        for n in 13...15 { #expect(menuItem(layout, "style", String(n)).clickable, "style \(n) takes a click once it is drawn") }
        // the panel holds every chip and the chips overlap nothing
        let panel = CGRect(origin: .zero, size: layout.size)
        for chip in chips { #expect(panel.contains(chip.rect) && row.rect.contains(chip.rect), "chip \(chip.value)") }
    }

    /// The menu writes through the installed CLI with the same arguments a terminal would use, so every bubbleExcluded write takes control.lock.
    @Test func MenuModel_styleChipsThirteenToFifteenWriteThroughTheCLI() throws {
        let layout = Self.layout
        var selection = MenuSelection()
        for n in 13...15 {
            let item = menuItem(layout, "style", String(n))
            let action = try #require(selection.action(for: item))
            #expect(action.arguments == ["bubble", "exclude", String(n)] && action.key == "style" && action.queueKey == "style-\(n)", "an enabled style \(n) is excluded")
        }
        selection.excludedStyles = [13, 14, 15]
        for n in 13...15 {
            let action = try #require(selection.action(for: menuItem(layout, "style", String(n))))
            #expect(action.arguments == ["bubble", "include", String(n)], "an excluded style \(n) is included")
            #expect(!selection.isSelected(menuItem(layout, "style", String(n))), "and is not shown as enabled")
        }
        // an undrawn style takes no click and writes nothing
        let muted = MenuLayout(looks: ["plain"], drawnStyles: Set(1...12))
        #expect(selection.action(for: menuItem(muted, "style", "14")) == nil)
    }

    @Test func Menu_aStyleThatIsNotDrawnIsMutedAndTakesNoClick() {
        let layout = MenuLayout(looks: ["plain"], drawnStyles: [1, 6, 10])
        for n in 1...15 {
            let item = menuItem(layout, "style", String(n))
            let drawn = [1, 6, 10].contains(n)
            #expect(item.clickable == drawn, "style \(n)")
            #expect(layout.hit(at: CGPoint(x: item.rect.midX, y: item.rect.midY)) == (drawn ? .item(item) : .muted(item)))
            #expect(layout.item(at: CGPoint(x: item.rect.midX, y: item.rect.midY)) == (drawn ? item : nil))
            #expect(MenuSelection().action(for: item) == nil || drawn, "a muted style runs nothing")
        }
    }

    // MARK: what a pick runs

    @Test func Menu_everyItemRunsTheExactArgumentsOfTheVerbTheUserTypes() {
        let layout = Self.layout, selection = MenuSelection()
        func args(_ key: String, _ value: String) -> [String]? { selection.action(for: menuItem(layout, key, value))?.arguments }
        #expect(args("walk", "on") == ["walk", "on"] && args("walk", "off") == ["walk", "off"])
        for level in ["off", "quiet", "normal", "lively"] { #expect(args("motion", level) == ["motion", level]) }
        for hours in ["2h", "3h", "4h"] { #expect(args("every", hours) == ["look-every", hours]) }
        #expect(args("look", "random") == ["look", "random"])
        for id in Self.looks { #expect(args("look", id) == ["look", id]) }
        #expect(args("bubble", "on") == ["bubble", "on"] && args("bubble", "off") == ["bubble", "off"])
        for size in ["0.5", "0.75", "1", "1.5", "2", "3", "4"] { #expect(args("size", size) == ["size", size]) }
        #expect(args("hide", "60") == ["hide", "60"])
        // A style chip toggles: an enabled style is excluded, an excluded one is included.
        #expect(args("style", "7") == ["bubble", "exclude", "7"])
        for side in ["below", "above", "left", "right"] { #expect(args("side", side) == ["bubble", "side", side]) }
        #expect(MenuSelection().action(for: menuItem(layout, "side", "left"))?.queueKey == "side" && MenuSelection().action(for: menuItem(layout, "side", "right"))?.queueKey == "side",
                "the newest side pick wins, like the other keys")
        var onLeft = MenuSelection(); onLeft.bubbleSide = .left
        #expect(onLeft.isSelected(menuItem(layout, "side", "left")) && !onLeft.isSelected(menuItem(layout, "side", "below")))
        var excluded = MenuSelection(); excluded.excludedStyles = [7]
        #expect(excluded.action(for: menuItem(layout, "style", "7"))?.arguments == ["bubble", "include", "7"])
        #expect(excluded.action(for: menuItem(layout, "style", "8"))?.arguments == ["bubble", "exclude", "8"])
    }

    @Test func Menu_aPickLogsItsKeyAndValueAndTwoStylesAreTwoQueueKeys() throws {
        let layout = Self.layout, selection = MenuSelection()
        let look = try #require(selection.action(for: menuItem(layout, "look", "sunglasses")))
        #expect(look.key == "look" && look.value == "sunglasses" && look.queueKey == "look")
        let every = try #require(selection.action(for: menuItem(layout, "every", "3h")))
        #expect(every.key == "every" && every.value == "3h" && every.arguments == ["look-every", "3h"])
        let a = try #require(selection.action(for: menuItem(layout, "style", "3"))), b = try #require(selection.action(for: menuItem(layout, "style", "5")))
        #expect(a.key == "style" && a.value == "3" && b.key == "style")
        #expect(a.queueKey != b.queueKey, "toggling two styles must not drop either")
        #expect(Set(layout.items.compactMap { selection.action(for: $0)?.queueKey }).count == 8 + 15, "eight rows, and a key of its own for each of the fifteen styles")
    }

    // MARK: what is selected

    @Test func Menu_theSelectedValuesComeFromTheSettingsTheAgentRunsWith() {
        let layout = Self.layout
        func selected(_ json: String) -> Set<String> {
            let selection = MenuSelection(settings: menuSettings(json))
            return Set(layout.items.filter { selection.isSelected($0) }.map { $0.key + "/" + $0.value })
        }
        let defaults = selected("{}")
        #expect(defaults.isSuperset(of: ["walk/on", "motion/quiet", "look/random", "every/4h", "bubble/on", "side/below", "size/1"]), "\(defaults)")
        #expect(defaults.filter { $0.hasPrefix("style/") }.count == 15, "every style is enabled by default")
        #expect(defaults.count == 7 + 15 && !defaults.contains("hide/60"), "exactly one value per row, and the action is never selected")
        let custom = selected(#"{"scale":1.5,"walk":false,"motion":"lively","lookEveryHours":2,"bubble":false,"bubbleExcluded":[3,7],"lookPin":"sunglasses"}"#)
        let enabled = (1...15).filter { $0 != 3 && $0 != 7 }.map { "style/\($0)" }
        #expect(custom == Set(["walk/off", "motion/lively", "look/sunglasses", "every/2h", "bubble/off", "side/below", "size/1.5"] + enabled))
        #expect(selected(#"{"scale":4}"#).contains("size/4") && selected(#"{"scale":2}"#).contains("size/2") && selected(#"{"scale":3}"#).contains("size/3"))
        #expect(selected(#"{"motion":"off"}"#).contains("motion/off") && selected(#"{"motion":"normal"}"#).contains("motion/normal"))
        #expect(selected(#"{"lookEveryHours":3}"#).contains("every/3h"))
    }

    @Test func Menu_theHelmetKeyShowsTheHelmetTileUnlessAPinWins() {
        let layout = Self.layout
        func tile(_ json: String) -> String? {
            let selection = MenuSelection(settings: menuSettings(json))
            return layout.items.first { $0.key == "look" && selection.isSelected($0) }?.value
        }
        #expect(tile(#"{"helmet":true}"#) == "helmet", "`helmet on` pins the helmet")
        #expect(tile(#"{"helmet":true,"lookPin":"coffee"}"#) == "coffee", "an explicit pin wins over the helmet key, as it does in the agent")
        #expect(tile(#"{"lookPin":"random"}"#) == "random" && tile("{}") == "random")
        #expect(tile(#"{"lookPin":"wizard"}"#) == "wizard")
    }

    @Test func Menu_aWrongTypedOrOutOfRangeValueShowsItsDefaultLikeTheAgentReadsIt() {
        let layout = Self.layout
        let selection = MenuSelection(settings: menuSettings(#"{"walk":"yes","motion":"fast","scale":7,"lookEveryHours":9,"bubbleExcluded":"x"}"#))
        let on = Set(layout.items.filter { selection.isSelected($0) }.map { $0.key + "/" + $0.value })
        #expect(on.isSuperset(of: ["walk/on", "motion/quiet", "size/1", "every/4h"]), "\(on)")
    }

    @Test func Menu_aMutedStyleIsNeverShownAsSelected() {
        let layout = MenuLayout(looks: ["plain"], drawnStyles: [1, 6, 10])
        let selection = MenuSelection()
        #expect(layout.items.filter { $0.key == "style" && selection.isSelected($0) }.map(\.value) == ["1", "6", "10"])
    }

    // MARK: where it opens

    @Test func Menu_opensToTheRightOfClawdWithAnEightPointGapCentredOnHim() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let canvas = CGRect(x: 576, y: 300, width: 48, height: 48)
        let rect = MenuPlacement.rect(size: Self.layout.size, canvas: canvas, visible: visible)
        #expect(rect.minX == canvas.maxX + 8 && rect.width == 236 && rect.height == 335)
        #expect(abs(rect.midY - canvas.midY) <= 0.5, "vertically centred on the body")
    }

    @Test func Menu_opensOnTheLeftWhenTheRightDoesNotFitAndKeepsEightPointsFromEveryEdge() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        let atRight = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: 1380, y: 300, width: 48, height: 48), visible: visible)
        #expect(atRight.maxX == 1380 - 8 && atRight.minX == 1380 - 8 - 236, "to the left of Clawd, 8 pt away")
        let low = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: 576, y: 90, width: 48, height: 48), visible: visible)
        #expect(low.minY == CGFloat(80 + 8), "pushed up to the bottom margin")
        let high = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: 576, y: 840, width: 48, height: 48), visible: visible)
        #expect(high.maxY == CGFloat(870 - 8), "pushed down to the top margin")
        for x in stride(from: -50.0, through: 1500, by: 37) {
            for y in stride(from: 60.0, through: 900, by: 41) {
                let rect = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: x, y: y, width: 48, height: 48), visible: visible)
                #expect(visible.insetBy(dx: 8, dy: 8).contains(rect), "canvas at (\(x), \(y)) gives \(rect)")
            }
        }
        // A frame too short for the menu keeps the top margin.
        let short = CGRect(x: 0, y: 0, width: 1440, height: 200)
        let tight = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: 576, y: 20, width: 48, height: 48), visible: short)
        #expect(tight.maxY == CGFloat(200 - 8))
    }

    @Test func Menu_doesNotScaleWithClawdsSize() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        for side in [48.0, 72, 96, 144, 192] {
            let rect = MenuPlacement.rect(size: Self.layout.size, canvas: CGRect(x: 300, y: 300, width: side, height: side), visible: visible)
            #expect(rect.size == CGSize(width: 236, height: 335), "size \(side / 48)")
            #expect(rect.minX == CGFloat(300 + side + 8))
        }
    }

    // MARK: the picture

    @Test func Menu_theLookTilesShowTheRestPoseOfEachLook() throws {
        let art = stageRenderer.art
        let pictures = MenuThumbnails.all(looks: Self.looks, art: art)
        #expect(pictures.count == Self.looks.count, "every look of the catalog has a picture")
        let plain = try #require(pictures["plain"])
        #expect(plain.width == 24 && plain.height == 24)
        var body = 0
        for y in 0..<24 { for x in 0..<24 where plain[x, y] == Pixel(215, 119, 87) { body += 1 } }
        #expect(body > 100, "Clawd's body is in the picture: \(body) cells")
        for id in Self.looks {
            let p = try #require(pictures[id])
            #expect(p.opaqueBounds != nil, "\(id) draws something")
        }
        // Which looks have a rest picture is read from the art, not named here: a look shows at rest when one of its layers has an opaque cell inside
        // the 24 x 24 canvas on the idle pose's first frame (placed as the compositor places it: from the head, the canvas or the feet), or when it
        // recolours the body or lifts Clawd. Today only the wand has none: none of its layer's cells falls inside the canvas at rest.
        let rest = try #require(try art.pose("idle").frames.first), head = try #require(rest.head)
        let canvas = 0..<StageGeometry.canvasCells
        var bare: Set<String> = []
        for id in Self.looks where id != "plain" {
            let look = try art.look(id)
            let drawn = look.layers.contains { layer in
                let origin: CellPoint
                switch layer.anchor {
                case .head: origin = CellPoint(head.x + layer.offset.x, head.y - look.raise + layer.offset.y)
                case .canvas: origin = layer.offset
                case .feet: origin = CellPoint(layer.offset.x, StageGeometry.canvasCells + layer.offset.y)
                }
                for y in 0..<layer.raster.height {
                    for x in 0..<layer.raster.width where layer.raster.isOpaque(x, y) && canvas.contains(origin.x + x) && canvas.contains(origin.y + y) { return true }
                }
                return false
            }
            if !drawn && look.bodyMap.isEmpty && look.raise == 0 { bare.insert(id) }
        }
        #expect(bare == ["wand"], "looks the art gives no rest picture: \(bare.sorted()); a look that loses its rest pose, or the wand gaining one, must be decided here")
        for id in Self.looks where id != "plain" {
            let p = try #require(pictures[id])
            if bare.contains(id) { #expect(p == plain, "\(id) has nothing of it in the canvas at rest, so its tile is plain") }
            else { #expect(p != plain, "\(id) does not look like plain") }
        }
        #expect(try MenuThumbnails.thumbnail(look: "plain", art: art) == plain, "drawing is deterministic")
    }

    @Test func Menu_thePanelHasANotchedPixelEdgeAndTheMocksColours() throws {
        let layout = Self.layout, selection = MenuSelection()
        let picture = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: selection), thumbnails: [:])
        let w = Int(layout.size.width), h = Int(layout.size.height)
        #expect(picture.width == w && picture.height == h)
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] { #expect(picture[x, y].isClear, "corner (\(x),\(y)) is cut") }
        #expect(picture[1, 0] == MenuColors.edge && picture[0, 1] == MenuColors.edge && picture[10, 0] == MenuColors.edge && picture[0, 10] == MenuColors.edge)
        #expect(picture[1, 1] == MenuColors.edge, "the face's own notch shows the edge beneath it")
        #expect(picture[2, 1] == MenuColors.face && picture[1, 2] == MenuColors.face && picture[5, 5] == MenuColors.face)
        #expect(picture[w - 1, 10] == MenuColors.edge && picture[10, h - 1] == MenuColors.edge)
        #expect(MenuColors.edge == Pixel(0x8f, 0x8f, 0x88) && MenuColors.face == Pixel(0xfb, 0xfa, 0xf6) && MenuColors.ink == Pixel(0x2b, 0x2a, 0x27))
        #expect(MenuColors.on == Pixel(0xd7, 0x77, 0x57) && MenuColors.flash == Pixel(0xb9, 0x57, 0x3a) && MenuColors.muted == Pixel(0x9b, 0x97, 0x8e))
        #expect(MenuColors.rowHover == Pixel(0xf1, 0xeb, 0xe2) && MenuColors.chipHover == Pixel(0xe5, 0xdc, 0xcf) && MenuColors.separator == Pixel(0xe2, 0xdd, 0xd3))
        let sep = layout.separator
        #expect(picture[Int(sep.minX), Int(sep.minY)] == MenuColors.separator && picture[Int(sep.maxX) - 1, Int(sep.minY)] == MenuColors.separator)
        #expect(picture[Int(sep.minX) - 1, Int(sep.minY)] == MenuColors.face && picture[Int(sep.minX), Int(sep.minY) - 1] == MenuColors.face)
    }

    @Test func Menu_selectedHoveredAndFlashedChipsAreDrawnInTheMocksColours() throws {
        let layout = Self.layout
        var selection = MenuSelection(); selection.motion = .quiet
        func picture(_ visual: MenuVisual) -> Raster { MenuRenderer.renderPoints(layout: layout, visual: visual, thumbnails: [:]) }
        let quiet = menuItem(layout, "motion", "quiet"), normal = menuItem(layout, "motion", "normal")
        let normalIndex = try #require(layout.items.firstIndex(of: normal)), motionRow = normal.row
        let rest = picture(MenuVisual(selection: selection))
        func corner(_ p: Raster, _ item: MenuItem) -> Pixel { p[Int(item.rect.minX), Int(item.rect.minY)] }
        #expect(corner(rest, quiet) == MenuColors.on, "the selected chip is filled")
        #expect(corner(rest, normal) == MenuColors.face, "an unselected chip has no fill")
        // text: the selected chip's ink is white, an unselected chip's is the ink colour
        func ink(_ p: Raster, _ item: MenuItem) -> Set<Pixel> {
            var seen: Set<Pixel> = []
            for y in Int(item.rect.minY + 2)..<Int(item.rect.minY + 14) { for x in Int(item.rect.minX + 2)..<Int(item.rect.maxX - 2) { seen.insert(p[x, y]) } }
            return seen
        }
        #expect(ink(rest, quiet) == [MenuColors.on, MenuColors.onInk] && ink(rest, normal) == [MenuColors.face, MenuColors.ink])
        let hover = picture(MenuVisual(selection: selection, hoverRow: motionRow, hoverItem: normalIndex))
        #expect(corner(hover, normal) == MenuColors.chipHover, "the chip under the pointer")
        #expect(corner(hover, quiet) == MenuColors.on, "a selected chip stays selected under the pointer, as in the mock")
        let rowRect = layout.rows[motionRow].rect
        #expect(hover[Int(rowRect.maxX) - 3, Int(rowRect.minY) + 1] == MenuColors.rowHover, "the row's background")
        #expect(hover[Int(rowRect.maxX) - 3, Int(rowRect.maxY) + 1] == MenuColors.face, "and only that row's")
        let flash = picture(MenuVisual(selection: selection, hoverRow: motionRow, hoverItem: normalIndex, flashItem: normalIndex))
        #expect(corner(flash, normal) == MenuColors.flash && ink(flash, normal) == [MenuColors.flash, MenuColors.onInk])
        // The labels are the pet's own pixel font: "Walk" starts with a W, one font pixel = 2 pt, in the ink colour.
        let origin = layout.rows[0].labelOrigin
        #expect(origin == CGPoint(x: 6, y: 8))
        #expect(rest[6, 8] == MenuColors.ink && rest[7, 9] == MenuColors.ink && rest[8, 8] == MenuColors.face, "W is X...X on its top row: lit, gap, gap")
    }

    @Test func Menu_theRandomTileAndTheSelectedTileAreDrawnLikeTheMock() throws {
        let layout = Self.layout
        let thumbs = MenuThumbnails.all(looks: Self.looks, art: stageRenderer.art)
        var selection = MenuSelection(); selection.lookPin = nil
        let random = menuItem(layout, "look", "random"), plain = menuItem(layout, "look", "plain")
        let picture = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: selection), thumbnails: thumbs)
        #expect(picture[Int(random.rect.minX), Int(random.rect.minY) + 5] == MenuColors.on && picture[Int(random.rect.maxX) - 1, Int(random.rect.minY) + 5] == MenuColors.on,
                "the selected tile has a 1 pt border")
        #expect(picture[Int(random.rect.minX) + 1, Int(random.rect.minY) + 1] == MenuColors.face, "and nothing else inside the corner")
        #expect(picture[Int(random.rect.minX) + 8, Int(random.rect.minY) + 7] == MenuColors.on, "the star's first row (X.X.X) is in the pet's orange, centred")
        #expect(picture[Int(plain.rect.minX), Int(plain.rect.minY) + 5] == MenuColors.face, "an unselected tile has no border")
        let thumb = try #require(thumbs["plain"])
        for (x, y) in [(5, 10), (12, 12), (8, 20)] {
            #expect(picture[Int(plain.rect.minX) + 1 + x, Int(plain.rect.minY) + 1 + y] == (thumb[x, y].isClear ? MenuColors.face : thumb[x, y]), "thumbnail cell (\(x),\(y))")
        }
        selection.lookPin = "plain"
        let pinned = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: selection), thumbnails: thumbs)
        #expect(pinned[Int(plain.rect.minX), Int(plain.rect.minY) + 5] == MenuColors.on && pinned[Int(random.rect.minX), Int(random.rect.minY) + 5] == MenuColors.face)
        let hovered = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: selection, hoverRow: plain.row, hoverItem: layout.items.firstIndex(of: random)), thumbnails: thumbs)
        #expect(hovered[Int(random.rect.minX) + 1, Int(random.rect.minY) + 1] == MenuColors.chipHover, "a hovered tile has the chip hover background")
    }

    @Test func Menu_aMutedStyleChipIsDrawnInTheMutedInk() throws {
        let layout = MenuLayout(looks: ["plain"], drawnStyles: [1, 6, 10])
        let two = menuItem(layout, "style", "2"), one = menuItem(layout, "style", "1")
        let picture = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: MenuSelection()), thumbnails: [:])
        // "2" is XX./..X/.X./X../XXX: its first row lights the first column; it is 3 font pixels wide, centred in 18 pt.
        #expect(picture[Int(two.rect.minX) + 6, Int(two.rect.minY) + 2] == MenuColors.muted)
        #expect(picture[Int(one.rect.minX), Int(one.rect.minY)] == MenuColors.on, "a drawn, enabled style is filled")
        #expect(picture[Int(two.rect.minX), Int(two.rect.minY)] == MenuColors.face, "a muted one never is, and has no hover")
        let hovered = MenuRenderer.renderPoints(layout: layout, visual: MenuVisual(selection: MenuSelection(), hoverItem: layout.items.firstIndex(of: two)), thumbnails: [:])
        #expect(hovered[Int(two.rect.minX), Int(two.rect.minY)] == MenuColors.face)
    }

    @Test func Menu_theDevicePictureIsThePointPictureEnlargedByWholePixels() {
        let layout = Self.layout, visual = MenuVisual(selection: MenuSelection())
        let points = MenuRenderer.renderPoints(layout: layout, visual: visual, thumbnails: [:])
        for scale in [1.0, 2.0] {
            let device = MenuRenderer.render(layout: layout, visual: visual, thumbnails: [:], pixelScale: scale)
            let k = Int(scale)
            #expect(device.width == points.width * k && device.height == points.height * k)
            #expect(device == points.upscaled(by: k))
        }
    }

    @Test func Menu_rendersTheMocksFourStatesOffscreen() throws {
        // Never a window: the menu is drawn into bitmaps, composed on the mock's light desk beside Clawd at his real size, at 2x.
        let evidence = try evidenceStore("v2/menu")
        let art = stageRenderer.art
        func desk(height: Double, menu: (MenuLayout, MenuVisual, [String: Raster])?, name: String) throws -> Raster {
            let backing = 2.0, width = 330.0
            var picture = Raster(width: Int(width * backing), height: Int(height * backing))
            picture.fill(x: 0, y: 0, width: picture.width, height: picture.height, Pixel(rgb: 0xf0efea))
            // Clawd at the mock's place: 16 pt from the left, 14 pt above the bottom, size 1 (48 pt).
            let request = StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry(homeX: 300, homeY: 300), pixelScale: backing)
            let frame = try #require(try stageRenderer.compose(request))
            let x = (16 + frame.panelFrame.minX - frame.canvas.minX) * backing
            let y = (height - 14 - (frame.panelFrame.maxY - frame.canvas.minY)) * backing
            picture.blit(frame.pixels, x: Int(x.rounded()), y: Int(y.rounded()))
            if let (layout, visual, thumbs) = menu {
                picture.blit(MenuRenderer.render(layout: layout, visual: visual, thumbnails: thumbs, pixelScale: backing), x: Int(76 * backing), y: Int(6 * backing))
            }
            try evidence.write(SceneRenderer.png(try picture.cgImage()), to: name)
            return picture
        }
        // The mock's own content: plain, helmet, sunglasses and headphones, and only styles 1, 6 and 10 drawn.
        let mockLooks = ["plain", "helmet", "sunglasses", "headphones"]
        let mock = MenuLayout(looks: mockLooks, drawnStyles: [1, 6, 10])
        let mockThumbs = MenuThumbnails.all(looks: mockLooks, art: art)
        var state = MenuSelection(); state.excludedStyles = Set(SchedulerSettings.bubbleStyles).subtracting([1, 6, 10])
        let motionRow = mock.rows.firstIndex { $0.key == "motion" }!
        let normal = mock.items.firstIndex { $0.key == "motion" && $0.value == "normal" }!
        let closed = try desk(height: 80, menu: nil, name: "closed.png")
        let open = try desk(height: 210, menu: (mock, MenuVisual(selection: state), mockThumbs), name: "open.png")
        let hover = try desk(height: 210, menu: (mock, MenuVisual(selection: state, hoverRow: motionRow, hoverItem: normal), mockThumbs), name: "hover.png")
        let pick = try desk(height: 210, menu: (mock, MenuVisual(selection: state, hoverRow: motionRow, hoverItem: normal, flashItem: normal), mockThumbs), name: "pick.png")
        // The same four with the catalog as it is today (15 looks, every style drawn).
        let live = Self.layout, liveThumbs = MenuThumbnails.all(looks: Self.looks, art: art)
        let liveMotion = live.rows.firstIndex { $0.key == "motion" }!, liveNormal = live.items.firstIndex { $0.key == "motion" && $0.value == "normal" }!
        let liveOpen = try desk(height: 288, menu: (live, MenuVisual(selection: MenuSelection()), liveThumbs), name: "live-open.png")
        _ = try desk(height: 288, menu: (live, MenuVisual(selection: MenuSelection(), hoverRow: liveMotion, hoverItem: liveNormal), liveThumbs), name: "live-hover.png")
        _ = try desk(height: 288, menu: (live, MenuVisual(selection: MenuSelection(), hoverRow: liveMotion, hoverItem: liveNormal, flashItem: liveNormal), liveThumbs), name: "live-pick.png")
        #expect(closed.width == 660 && closed.height == 160 && open.width == 660 && open.height == 420)
        #expect(open != hover && hover != pick && open != closed.padded(left: 0, top: 0, right: 0, bottom: 260), "the four states differ")
        #expect(liveOpen.height == 576)
        // The menu is drawn where the mock puts it, and the pieces that must show are on the desk.
        let at = { (p: Raster, item: MenuItem) -> Pixel in p[Int((76 + item.rect.minX) * 2), Int((6 + item.rect.minY) * 2)] }
        let quiet = mock.items.first { $0.key == "motion" && $0.value == "quiet" }!, normalItem = mock.items[normal]
        #expect(at(open, quiet) == MenuColors.on && at(hover, normalItem) == MenuColors.chipHover && at(pick, normalItem) == MenuColors.flash)
        #expect(open[76 * 2 + 2, 6 * 2].isOpaque, "the edge")
        #expect(open[(16 + 24) * 2, (210 - 14 - 20) * 2].isOpaque, "Clawd stands beside it, 20 pt above his feet, in the middle")
        #expect(FileManager.default.fileExists(atPath: evidence.root.appendingPathComponent("pick.png").path))
    }
}
