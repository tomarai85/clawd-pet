import AppKit
import QuartzCore
import ClawdCore
import ClawdRendering

/// The windows that show the stage (spec 4.4). Click-through is a property of which window exists where, never of a flag that is
/// flipped while the pointer moves:
///   - `body` is as small as Clawd's body and costume pixels and takes mouse events. It never becomes key or main.
///   - `stage` carries the rest of the picture (props, effects, the bubble, the transparent stage) and ignores mouse events for its
///     whole life (`StagePanel`), so a click on any of it is a click on the app behind, however fast the pointer got there.
///   - the open menu (Sprint M) gets a window of its own, which takes mouse events. Each opening gets a NEW window and the close drops it,
///     so a click that is still on its way to a closed menu can only reach that window, which knows its own opening's number.
/// Every window keeps v1's focus guarantees (`PanelContract`): non-activating, never key or main, in every Space, and all sit at one level
/// above every floating window (`PanelContract.level`).
public final class PanelSet {
    public let stage: StagePanel
    public let body: PetPanel
    /// The body window's content view: it receives the clicks and the drag.
    public let view: PetView
    public private(set) var menu: MenuPanel?
    /// The number of the opening whose window the next picture with a menu rectangle creates (the menu controller sets it before the render).
    public var pendingMenuGen = 0
    /// Builds the view of a new menu window (the runtime supplies the real one; without it the window gets an empty menu).
    public var menuFactory: ((Int) -> MenuView)?
    private let stageView = NSView()
    private let overFullScreen: Bool
    /// The mouse-downs each of these windows (and the chat panel) receives, for the chat's activation token.
    public let presses = WindowPressLog()

    public init(overFullScreen: Bool) {
        self.overFullScreen = overFullScreen
        stage = StagePanel(overFullScreen: overFullScreen)
        body = PetPanel(overFullScreen: overFullScreen)
        stage.presses = presses; body.presses = presses
        view = PetView(frame: body.contentView?.bounds ?? .zero)
        Self.prepare(stageView); Self.prepare(view)
        stage.contentView = stageView
        body.contentView = view
    }

    private static func prepare(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.magnificationFilter = .nearest
        view.layer?.minificationFilter = .nearest
        view.layer?.contentsGravity = .bottomLeft
    }

    /// Every window that exists now.
    public var all: [PetPanel] {
        var windows: [PetPanel] = [stage, body]
        if let menu { windows.append(menu) }
        return windows
    }

    private func place(_ panel: NSPanel, _ view: NSView, _ picture: PanelPicture) {
        panel.setFrame(picture.rect, display: false)
        view.frame = CGRect(origin: .zero, size: picture.rect.size)
        if let layer = view.layer { RenderPipeline.apply(picture, to: layer) }
    }

    /// Puts a finished picture on screen. The stage window is ordered before the body window; their pictures share no pixel, so the
    /// order shows nothing. `holdBody` keeps the body window where it is when this picture has no body pixels: a press that began on it
    /// must not lose its window, which would lose the button-up (the drag would never end).
    public func show(_ pictures: PanelPictures, holdBody: Bool = false, environment: RuntimeEnvironment) {
        place(stage, stageView, pictures.stage)
        if !stage.isVisible { environment.present(stage) }
        if let picture = pictures.body {
            place(body, view, picture)
            if !body.isVisible { environment.present(body) }
        } else if !holdBody {
            environment.dismiss(body)
        }
        if let rect = pictures.menuRect {
            let window = menu ?? makeMenu()
            menu = window
            window.menuView.pixelScale = pictures.stage.pixelScale
            window.setFrame(rect, display: false)
            window.menuView.frame = CGRect(origin: .zero, size: rect.size)
            if !window.isVisible { environment.present(window) }
        } else if let menu {
            environment.dismiss(menu)
            self.menu = nil
        }
    }

    private func makeMenu() -> MenuPanel {
        let gen = pendingMenuGen
        let view = menuFactory?(gen) ?? MenuView(layout: MenuLayout(looks: [], drawnStyles: []), gen: gen)
        let panel = MenuPanel(overFullScreen: overFullScreen, gen: gen, view: view)
        panel.presses = presses
        return panel
    }

    /// What is wrong with the windows' mouse handling and focus contract; empty when right. The stage window must ignore mouse events
    /// (as told to the window server, and as it answers), every window that exists besides it must take them, and every window keeps
    /// v1's focus guarantees.
    public func violations() -> [String] {
        var found: [String] = []
        if !stage.windowServerIgnoresMouseEvents { found.append("the stage window takes mouse events (the window server was told so)") }
        if !stage.ignoresMouseEvents { found.append("the stage window answers that it takes mouse events") }
        for window in all where window !== stage && window.ignoresMouseEvents { found.append("a window that must take clicks ignores them") }
        for window in all {
            found += FocusAudit.violations(of: window, overFullScreenAllowed: overFullScreen).map { "focus contract: \($0)" }
        }
        return found
    }

    /// Nothing is shown (hidden, a quiet condition, no display).
    public func hide(environment: RuntimeEnvironment) {
        for window in all { environment.dismiss(window) }
        menu = nil
    }
}
