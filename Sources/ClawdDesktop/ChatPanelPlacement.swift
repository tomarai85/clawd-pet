import CoreGraphics
import ClawdCore

/// Where the chat panel goes (F1.2): beside Clawd's canvas on Clawd's display, wholly inside that display's visible frame, 380 x
/// min(480, visible height - 16) points. The side opposite the bubble when the bubble is on the left or the right, else the side with more
/// room; the bottom edge level with Clawd's feet; clamped. A pure function of the geometry, so re-placing is a `setFrame` and nothing else.
public enum ChatPanelPlacement {
    public static let width: CGFloat = 380
    public static let maxHeight: CGFloat = 480
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 8

    /// The terminal panel's default (spec R9.2 T-2, changed in v3-orca-look r2): ChatPanelGeometry.defaultSize, capped by the visible frame less 16 points.
    public static let terminalWidth: CGFloat = ChatPanelGeometry.defaultSize.width
    public static let terminalMaxHeight: CGFloat = ChatPanelGeometry.defaultSize.height

    public static func size(visible: CGRect, width: CGFloat = ChatPanelPlacement.width, maxHeight: CGFloat = ChatPanelPlacement.maxHeight) -> CGSize {
        CGSize(width: min(width, max(0, visible.width - margin * 2)), height: max(0, min(maxHeight, visible.height - 16)))
    }

    public static func rect(canvas: CGRect, bubbleSide: BubbleSide, visible: CGRect, width: CGFloat = ChatPanelPlacement.width,
                            maxHeight: CGFloat = ChatPanelPlacement.maxHeight) -> CGRect {
        let size = size(visible: visible, width: width, maxHeight: maxHeight)
        let roomRight = visible.maxX - margin - (canvas.maxX + gap)
        let roomLeft = (canvas.minX - gap) - (visible.minX + margin)
        var onRight: Bool
        switch bubbleSide {
        case .left: onRight = true
        case .right: onRight = false
        case .above, .below: onRight = roomRight >= roomLeft
        }
        // The chosen side wins when it fits; a side that cannot hold the panel gives way to the other.
        if onRight, roomRight < size.width, roomLeft >= size.width { onRight = false }
        else if !onRight, roomLeft < size.width, roomRight >= size.width { onRight = true }
        var x = onRight ? canvas.maxX + gap : canvas.minX - gap - size.width
        x = min(x, visible.maxX - margin - size.width)
        x = max(x, visible.minX + margin)
        var y = canvas.minY
        y = min(y, visible.maxY - margin - size.height)
        y = max(y, visible.minY + margin)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}
