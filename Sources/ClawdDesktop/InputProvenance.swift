import AppKit

/// What the agent writes into agent.log about where a mouse event came from. The live check (scripts/live-check.sh) posts synthetic
/// events that carry a tag in `kCGEventSourceUserData` and compares the tags it posted with the tags logged here; an event without
/// its tag is somebody else's, and a person at the pet makes that run NOT RUN.
///
///   tag=<16 hex digits>   the 64-bit `eventSourceUserData` of the event's CGEvent (0000000000000000 for an ordinary hardware event)
///   tag=none              the NSEvent has no CGEvent behind it
///   src=<pid>             `eventSourceUnixProcessID` (0 for hardware), `src=none` without a CGEvent
public enum InputProvenance {
    public static func tag(of cg: CGEvent?) -> String {
        guard let cg else { return "none" }
        return String(format: "%016llx", UInt64(bitPattern: cg.getIntegerValueField(.eventSourceUserData)))
    }
    public static func sourcePid(of cg: CGEvent?) -> String {
        guard let cg else { return "none" }
        return String(cg.getIntegerValueField(.eventSourceUnixProcessID))
    }
    public static func fields(of cg: CGEvent?) -> String { "tag=\(tag(of: cg)) src=\(sourcePid(of: cg))" }

    public static func tag(of event: NSEvent) -> String { tag(of: event.cgEvent) }
    public static func sourcePid(of event: NSEvent) -> String { sourcePid(of: event.cgEvent) }
    public static func fields(of event: NSEvent) -> String { fields(of: event.cgEvent) }
}
