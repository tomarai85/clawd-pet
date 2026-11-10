import Foundation
import CoreGraphics
import QuartzCore
import ClawdCore

/// One rendered frame, ready for a layer: the picture, its RGBA pixels (the hit test reads them) and its size in points.
public struct PreparedFrame {
    public let image: CGImage
    public let pixels: Data
    public let size: CGSize
    public let pixelScale: Double
    public init(image: CGImage, pixels: Data, size: CGSize, pixelScale: Double) {
        self.image = image; self.pixels = pixels; self.size = size; self.pixelScale = pixelScale
    }
}

/// The production path from a controller state to a layer's contents. The agent calls it for every render, and the
/// windowless idle-render mode calls the very same two functions, so the CPU it measures includes image generation,
/// the pixel copy and the layer update that the shown agent performs on each blink.
public final class RenderPipeline {
    public let renderer: SceneRenderer
    public init(renderer: SceneRenderer) { self.renderer = renderer }

    public func prepare(_ state: PetViewState, scale: Double, helmet: Bool, pixelScale: Double) throws -> PreparedFrame {
        let frame = renderer.frame(from: state, scale: scale, helmet: helmet, pixelScale: pixelScale)
        let image = try renderer.render(frame)
        let pixels = try SceneRenderer.pixels(image)
        return PreparedFrame(image: image, pixels: pixels,
                             size: CGSize(width: Double(image.width) / pixelScale, height: Double(image.height) / pixelScale),
                             pixelScale: pixelScale)
    }

    public static func apply(_ frame: PreparedFrame, to layer: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contentsScale = frame.pixelScale; layer.contents = frame.image
        CATransaction.commit()
    }

    /// One window's picture of the stage path into its layer (the same transaction as the v1 path).
    public static func apply(_ picture: PanelPicture, to layer: CALayer) {
        apply(PreparedFrame(image: picture.image, pixels: Data(), size: picture.rect.size, pixelScale: picture.pixelScale), to: layer)
    }
}
