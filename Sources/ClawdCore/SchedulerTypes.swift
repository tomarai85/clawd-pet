import Foundation
import CoreGraphics

/// A condition under which nothing moves, nothing renders and no timer runs (spec 6.1). Order is the order of the reported reason.
public enum QuietReason: String, CaseIterable, Hashable {
    case systemAsleep = "system-asleep"
    case displayAsleep = "display-asleep"
    case screenLocked = "screen-locked"          // includes the screen saver
    case sessionInactive = "session-inactive"    // this login session switched away
    case notOnActiveSpace = "not-on-active-space"
    case aquaNotRunning = "aqua-not-running"
    /// A LockDown Browser application is running, and for 120 s after the last one quit (amendment D-4).
    case examBrowser = "exam-browser"

    /// Clearing one of these is an "appear" (spec 6.6: Aqua start, wake, unlock, the end of an exam stand-down).
    var appearsOnClear: Bool {
        switch self {
        case .systemAsleep, .screenLocked, .aquaNotRunning, .examBrowser: return true
        case .displayAsleep, .sessionInactive, .notOnActiveSpace: return false
        }
    }
}

/// Where Clawd is and how big. Global AppKit coordinates (origin bottom-left, y up).
public struct PetGeometry: Equatable {
    /// The size setting: 0.5, 0.75, 1, 1.5, 2, 3 or 4.
    public var scale: Double
    /// Bottom-left corner of Clawd's 12 x 12 canvas at home.
    public var homeOrigin: CGPoint
    /// The display Clawd is on, and its visible frame (without the menu bar and the Dock).
    public var displayFrame: CGRect
    public var visibleFrame: CGRect

    public init(scale: Double = 1, homeOrigin: CGPoint, displayFrame: CGRect, visibleFrame: CGRect) {
        self.scale = scale; self.homeOrigin = homeOrigin; self.displayFrame = displayFrame; self.visibleFrame = visibleFrame
    }
    /// Where Clawd may be dragged to (`Placement.dragArea`): the visible frame plus the Dock.
    public var dragArea: CGRect { Placement.dragArea(display: displayFrame, visible: visibleFrame) }
    /// What Clawd's window may cover: the drag area, so a Clawd dropped over the Dock is drawn whole (the bubble keeps to the visible frame itself).
    /// A geometry without a display falls back to the visible frame.
    public var windowArea: CGRect { displayFrame.isEmpty ? visibleFrame : dragArea.union(visibleFrame) }
    /// Points per pet unit.
    public var unit: Double { PetCatalog.pointsPerUnit * scale }
    /// One Clawd width: the 12-unit canvas (48 pt at size 1).
    public var width: Double { PetCatalog.canvasUnits * unit }
    /// The keep-out band around the display centre (spec 6.2): Aqua's floating bar sits there.
    public static let keepOutHalfWidth = 120.0
    public var bandMin: Double { Double(displayFrame.midX) - Self.keepOutHalfWidth }
    public var bandMax: Double { Double(displayFrame.midX) + Self.keepOutHalfWidth }

    /// The rectangle a motion with this stage covers when the canvas origin is at `x` (and the home height).
    public func stageRect(_ stage: StageExtent, originX x: Double) -> CGRect {
        let u = unit
        return CGRect(x: x - stage.left * u, y: Double(homeOrigin.y) - stage.down * u,
                      width: width + (stage.left + stage.right) * u, height: PetCatalog.canvasUnits * u + (stage.up + stage.down) * u)
    }
    public func canvasRect(originX x: Double) -> CGRect { stageRect(.none, originX: x) }
}

public enum Facing: Equatable { case right, left }

public enum PetVisibility: Equatable {
    case hidden
    case quiet(QuietReason)
    case visible
}

/// What Clawd is playing. `pose` is a v1 pose name from the atlas (listen, think, hop, dangle, sleep, idle).
public struct MotionPlayback: Equatable {
    public enum Source: Equatable {
        case pose(String)
        case motion(String)
        /// The skateboard look glides in the rest pose instead of stepping.
        case glide
        /// The duck-and-pop look change; `progress` in the frame says where it is.
        case transition(from: String, to: String)
    }
    public var source: Source
    /// idle, touch, multi-touch, entrance, drop, sleep-entry, walk, walk-pause, listening, thinking, sent, interrupted, error, drag, transition.
    public var use: String
    public var startedAt: TimeInterval
    public var duration: TimeInterval
    public var loops: Bool
    public var holdsLastFrame: Bool
    public var mirrored: Bool
    /// A glide of the skateboard look: the ride of this stretch of the walk (nil: the rest picture slides, as before the ride existed).
    public var ride: GlideRide?

    public init(source: Source, use: String, startedAt: TimeInterval, duration: TimeInterval, loops: Bool = false,
                holdsLastFrame: Bool = false, mirrored: Bool = false, ride: GlideRide? = nil) {
        self.source = source; self.use = use; self.startedAt = startedAt; self.duration = duration; self.loops = loops
        self.holdsLastFrame = holdsLastFrame; self.mirrored = mirrored; self.ride = ride
    }
    public var motionID: String? { if case .motion(let id) = source { return id } else { return nil } }
    public var endsAt: TimeInterval? { loops || holdsLastFrame ? nil : startedAt + duration }
}

public struct BubbleState: Equatable {
    public var style: Int
    public var scene: Scene
    public init(style: Int, scene: Scene) { self.style = style; self.scene = scene }
}

/// Everything the renderer needs from the scheduler for one frame. Call `refresh()` first so due deadlines are applied.
public struct SchedulerFrame: Equatable {
    public var visibility: PetVisibility
    public var scene: Scene
    public var dragging: Bool
    public var asleep: Bool
    /// nil = the rest pose (v1 idle with its blink).
    public var playback: MotionPlayback?
    /// The look worn (committed).
    public var look: String
    /// The look drawn right now: the old one while Clawd sinks, the new one while it rises.
    public var displayedLook: String
    /// 0...1 over the look transition (sink then rise, swap at 0.5), nil when none runs.
    public var transitionProgress: Double?
    /// Points from home along x. Positive is right.
    public var walkOffset: Double
    public var facing: Facing
    public var bubble: BubbleState?

    public init(visibility: PetVisibility = .visible, scene: Scene = .idle, dragging: Bool = false, asleep: Bool = false,
                playback: MotionPlayback? = nil, look: String = PetCatalog.plainLook, displayedLook: String? = nil,
                transitionProgress: Double? = nil, walkOffset: Double = 0, facing: Facing = .right, bubble: BubbleState? = nil) {
        self.visibility = visibility; self.scene = scene; self.dragging = dragging; self.asleep = asleep; self.playback = playback
        self.look = look; self.displayedLook = displayedLook ?? look; self.transitionProgress = transitionProgress
        self.walkOffset = walkOffset; self.facing = facing; self.bubble = bubble
    }
}

/// Look state that survives restarts (state.json: `look`, `lookSince`, `recentLooks`, `lastBubbleStyle`).
public struct SchedulerPersisted: Equatable {
    public var look: String
    /// Epoch seconds of the last change.
    public var lookSince: Double
    /// Looks worn before the current one, newest first.
    public var recentLooks: [String]
    public var lastBubbleStyle: Int?
    /// The looks worn or picked in the current cycle of the rotation (the shuffle bag, `lookUsed` in state.json). Automatic picks never
    /// choose one of them; the cycle starts again, with the worn look alone, when every look in rotation is in it.
    public var lookUsed: [String]
    /// The factor drawn for the current interval (0.75 to 1.25, amendment D-3) and the absolute due time of the next rotation change, in
    /// epoch seconds. nil `lookDueAt` means `lookSince` plus the setting times the factor, worked out when read.
    public var lookDueFactor: Double
    public var lookDueAt: Double?
    /// The variety factor of the worn look (1/3 to 1, amendment variety D-4): the due interval is the setting x the jitter factor x this.
    public var lookVarietyFactor: Double
    /// The idle family bag (variety D-2): the look it belongs to, the families played in the current cycle, and the family of the last
    /// automatic idle motion.
    public var idleBagLook: String?
    public var idleFamiliesUsed: [String]
    public var idleLastFamily: String?
    /// The last automatic idle member of each family, retained across cycles and restarts (variety D-2 (f)).
    public var idleLastMembers: [String: String]
    /// A LockDown Browser application is running, or quit less than 120 s ago (amendment D-4), and the wall time that wait ends.
    public var examActive: Bool
    public var examGraceUntil: Double?
    public init(look: String = PetCatalog.plainLook, lookSince: Double, recentLooks: [String] = [], lastBubbleStyle: Int? = nil,
                lookUsed: [String] = [], lookDueFactor: Double = 1.0, lookDueAt: Double? = nil, examActive: Bool = false,
                examGraceUntil: Double? = nil, lookVarietyFactor: Double = 1.0, idleBagLook: String? = nil, idleFamiliesUsed: [String] = [],
                idleLastFamily: String? = nil, idleLastMembers: [String: String] = [:]) {
        self.look = look; self.lookSince = lookSince; self.recentLooks = recentLooks; self.lastBubbleStyle = lastBubbleStyle
        self.lookUsed = lookUsed; self.lookDueFactor = lookDueFactor; self.lookDueAt = lookDueAt
        self.lookVarietyFactor = lookVarietyFactor; self.idleBagLook = idleBagLook; self.idleFamiliesUsed = idleFamiliesUsed
        self.idleLastFamily = idleLastFamily
        self.idleLastMembers = idleLastMembers
        self.examActive = examActive; self.examGraceUntil = examGraceUntil
    }
}

/// The lines the instruments read (Interface Contract agent.log). `at` is the scheduler clock when it happened.
public enum SchedulerEvent: Equatable {
    case motionStart(id: String, use: String)
    case motionEnd(id: String)
    case walkStart(dx: Double)
    case walkEnd(walkedSeconds: Double)
    case walkEnabled, walkDisabled
    case lookTransition(from: String, to: String)
    case lookChange(from: String, to: String)
    case lookTransitionEnd
    case quietOn(reason: String), quietOff
    case hidden, shown
    case sleepStart, wake
    case touch, multiTouch
    /// A click dropped because the multi-touch reaction is playing (`CLICK-IGNORED why=<reason>` in agent.log).
    case clickIgnored(reason: String)
    /// The exam stand-down (amendment D-4): the absence of every LockDown Browser application was first seen (the 120 s begin), the 120 s ended,
    /// and a quit that no notification reported was found by the 10 s recheck.
    case examClear, examSettleEnd, examRecheckHealed
    case bubbleStyle(Int)
}

public struct SchedulerCounters: Equatable {
    public var idleMotions = 0, walks = 0, lookChanges = 0, entrances = 0, touches = 0
}

/// Each member names one rule of spec section 6. Production runs with `.all`; the negative-control tests switch one rule off
/// to show that the named S-test turns red without it (the same convention as v1's GuardSet).
public struct SchedulerGuards: OptionSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    // S-1
    public static let quietFreeze = SchedulerGuards(rawValue: 1 << 0)
    // S-2
    public static let sceneCutsActivity = SchedulerGuards(rawValue: 1 << 1)
    public static let sceneAfterTransition = SchedulerGuards(rawValue: 1 << 2)
    // S-3
    public static let noRepeatMotion = SchedulerGuards(rawValue: 1 << 3)
    public static let noRepeatLook = SchedulerGuards(rawValue: 1 << 4)
    public static let bubbleNoRepeat = SchedulerGuards(rawValue: 1 << 5)
    // S-4
    public static let lookGap30 = SchedulerGuards(rawValue: 1 << 6)
    public static let lookNeedsRest = SchedulerGuards(rawValue: 1 << 7)
    public static let lookNeedsAwake = SchedulerGuards(rawValue: 1 << 8)
    public static let lookNeedsVisible = SchedulerGuards(rawValue: 1 << 9)
    // S-5
    public static let idleCountedFromEnd = SchedulerGuards(rawValue: 1 << 10)
    public static let idleLowerBound = SchedulerGuards(rawValue: 1 << 11)
    // S-6
    public static let lookEveryN = SchedulerGuards(rawValue: 1 << 12)
    public static let lookOwnDeadline = SchedulerGuards(rawValue: 1 << 13)
    // S-7
    public static let walkKeepOut = SchedulerGuards(rawValue: 1 << 14)
    public static let walkInsideFrame = SchedulerGuards(rawValue: 1 << 15)
    public static let walkReturnsHome = SchedulerGuards(rawValue: 1 << 16)
    public static let walkPointerStop = SchedulerGuards(rawValue: 1 << 17)
    public static let walkSceneCancel = SchedulerGuards(rawValue: 1 << 18)
    public static let walkSpeedRange = SchedulerGuards(rawValue: 1 << 19)
    // S-8
    public static let compatibility = SchedulerGuards(rawValue: 1 << 20)
    public static let exclusion = SchedulerGuards(rawValue: 1 << 21)
    // S-9
    public static let bubbleStyleKept = SchedulerGuards(rawValue: 1 << 22)
    public static let bubbleWeights = SchedulerGuards(rawValue: 1 << 23)
    // S-10
    public static let poolOverheadClear = SchedulerGuards(rawValue: 1 << 24)
    public static let sentMaxDuration = SchedulerGuards(rawValue: 1 << 25)
    // S-11
    public static let reduceMotion = SchedulerGuards(rawValue: 1 << 26)
    // S-12
    public static let settingWalk = SchedulerGuards(rawValue: 1 << 27)
    public static let settingMotion = SchedulerGuards(rawValue: 1 << 28)
    public static let settingExclude = SchedulerGuards(rawValue: 1 << 29)
    public static let settingHide = SchedulerGuards(rawValue: 1 << 30)
    public static let settingLookPin = SchedulerGuards(rawValue: 1 << 31)
    // S-12 and S-13
    public static let bubbleOff = SchedulerGuards(rawValue: 1 << 32)
    // S-13
    public static let bubbleTimingCap = SchedulerGuards(rawValue: 1 << 33)
    public static let bubbleQuietHidden = SchedulerGuards(rawValue: 1 << 34)
    // outside the S list
    public static let stageFits = SchedulerGuards(rawValue: 1 << 35)
    public static let pointerOutside = SchedulerGuards(rawValue: 1 << 36)
    public static let clickRules = SchedulerGuards(rawValue: 1 << 37)
    public static let sleepByInputIdle = SchedulerGuards(rawValue: 1 << 38)
    // Sprint 11 (spec 9b item 16)
    public static let pointerOnWalkTicks = SchedulerGuards(rawValue: 1 << 39)
    public static let pointerBeforeIdle = SchedulerGuards(rawValue: 1 << 40)
    public static let pointerAfterQuiet = SchedulerGuards(rawValue: 1 << 41)
    public static let walkPatienceRechecks = SchedulerGuards(rawValue: 1 << 42)
    public static let quietCancelsDrag = SchedulerGuards(rawValue: 1 << 43)
    public static let reduceMotionEndsSceneMotion = SchedulerGuards(rawValue: 1 << 44)
    // Sprint 11 round 2 (spec 9b item 16, Codex's findings B and C)
    public static let walkHomewardRechecks = SchedulerGuards(rawValue: 1 << 45)
    public static let quietReasonFirst = SchedulerGuards(rawValue: 1 << 46)
    // Sprint M (R-HOLD): the open menu holds Clawd still
    public static let menuHold = SchedulerGuards(rawValue: 1 << 47)

    // Scheduler feel (amendment D-2, D-3): the shuffle bag of the rotation, and the drawn interval between look changes
    public static let lookBag = SchedulerGuards(rawValue: 1 << 48)
    public static let lookJitter = SchedulerGuards(rawValue: 1 << 49)

    // Variety (amendment variety D-2): the idle family bag; off = the picker of the scheduler feel line (the measured "before" of the six-hour test)
    public static let idleBag = SchedulerGuards(rawValue: 1 << 50)

    // Clawd v3 chat: while the chat panel is open no walk starts, and a running one stands where it is and goes home after the close
    public static let chatHold = SchedulerGuards(rawValue: 1 << 51)

    public static let all: SchedulerGuards = SchedulerGuards(rawValue: (1 << 52) - 1)
}
