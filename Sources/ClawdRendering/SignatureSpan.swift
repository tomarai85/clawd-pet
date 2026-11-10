/// The frames of a look's signature motion in which the motion itself draws the look's props on Clawd.
///
/// A signature motion draws its prop itself, so the look's layers are off while it plays (`LookArt.layerOnSignature`). These motions are
/// ported whole and start and end on the plain rest pose, so their first and last frames show Clawd without the look: the hat, mug,
/// headphones or wand vanished for 0.4 to 2.2 s and popped back when the next picture put the layers on again (Tom, 2026-11-08). Under its
/// own look, a signature motion shows its own frames only inside its span; at every other index the renderer draws the look's rest picture
/// with its layers on (the spec's rule: a look is all layers or none). Under any other look the motion plays whole.
///
/// The spans were judged frame by frame on the shipped atlas (2026-11-08) and are clip indices; these motions have no bridges, so clip and
/// atlas indices are the same (`SignatureSpan_theSpansFitTheShippedAtlas` checks both).
/// - detective / D12-inspect 17...103: the magnifier comes in at 17 and leaves after 103. The hat alone (9-16, 104-107) is half the look, and
///   at 107-108 the GIF tosses the hat away.
/// - coffee / A19-coffee 6...26: the mug is held from 6 to 26. At 27 only a corner of it is left.
/// - headphones / A18-headphones 10...65: worn from 10 to 65. At 9 and 66 they sit tilted on the way on and off, and 7-8 and 67-68 hold them
///   in the hand.
/// - wand / A25-spark 5...66: the wand flashes in at 5 and is lowered by 66. The sparks fade after 46 while the wand stays up.
public enum SignatureSpan {
    public static let spans: [String: [String: ClosedRange<Int>]] = [
        "detective": ["D12-inspect": 17...103],
        "coffee": ["A19-coffee": 6...26],
        "headphones": ["A18-headphones": 10...65],
        "wand": ["A25-spark": 5...66],
    ]

    /// Signature motions that draw the look's prop in every frame, so they play whole under their look: the skateboard's ride.
    public static let wholeMotion: [String: Set<String>] = ["skateboard": ["D14-ride"]]

    public static func span(look: String, motion: String) -> ClosedRange<Int>? { spans[look]?[motion] }

    /// Whether the motion's own frame `index` is drawn under `look`. False means the renderer draws the look's rest picture with its layers.
    /// A pair with no span, or one listed in `wholeMotion`, draws every index.
    public static func drawsOwnFrame(look: String, motion: String, index: Int) -> Bool {
        guard let span = span(look: look, motion: motion) else { return true }
        return span.contains(index)
    }
}
