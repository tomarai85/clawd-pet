import CoreGraphics

/// Where the Settings window goes and how big it is (design 4.1): a pure function of the visible frame of the display it opens on and the
/// title bar's height, so the table test needs no window.
public enum SettingsGeometry {
    /// The sidebar keeps this width at every size.
    public static let sidebarWidth = 178.0
    /// The content size when the display is large enough, the least it is ever given, and the margin kept around it.
    public static let preferred = CGSize(width: 960, height: 600)
    public static let minimum = CGSize(width: 640, height: 400)
    public static let margin = 32.0

    /// `frame` is the window's frame in global points, `content` the content size inside it. `wholeFrame`: even the minimum content does not
    /// fit, so the window takes the whole visible frame and its content scrolls.
    public struct Placement: Equatable {
        public let frame: CGRect
        public let content: CGSize
        public let wholeFrame: Bool
    }

    /// The content is min(960, W - 32) by min(600, H - T - 32), never under 640 x 400; when the window around even that does not fit, it
    /// takes the whole visible frame. Centred in the visible frame, on whole points.
    public static func frame(visible: CGRect, titleBar: Double) -> Placement {
        let width = max(minimum.width, min(preferred.width, visible.width - margin))
        let height = max(minimum.height, min(preferred.height, visible.height - titleBar - margin))
        guard width <= visible.width, height + titleBar <= visible.height else {
            return Placement(frame: visible, content: CGSize(width: visible.width, height: max(0, visible.height - titleBar)), wholeFrame: true)
        }
        let size = CGSize(width: width, height: height + titleBar)
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        return Placement(frame: CGRect(origin: origin, size: size), content: CGSize(width: width, height: height), wholeFrame: false)
    }
}
