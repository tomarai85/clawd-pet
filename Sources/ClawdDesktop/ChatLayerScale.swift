import AppKit

extension NSView {
    /// The scale a layer this view made itself takes: the window's, else 2 (ChatImagePreview's fallback). A layer AppKit makes for a view follows its
    /// window on its own; a sublayer added by hand (the drop overlay's dash, the chips' picture and dash) keeps the scale it was made with until
    /// `viewDidChangeBackingProperties` hands it the new one (Q20 e). `override` is the test seam.
    func backingScale(override: CGFloat?) -> CGFloat {
        override ?? window?.backingScaleFactor ?? 2
    }
}
