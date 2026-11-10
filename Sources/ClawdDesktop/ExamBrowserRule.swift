import AppKit

/// Which running applications are a proctoring browser the pet stands down for (amendment D-4). Read from the two installed apps:
/// `com.Respondus.LockDownBrowser` (2.1.6) and `com.Respondus.LockDownBrowserOEM` (2.1.3); the name is the hedge for a build with another id.
public enum ExamBrowserRule {
    public static let bundlePrefix = "com.Respondus.LockDownBrowser"
    public static let namePrefix = "LockDown Browser"

    public static func matches(bundleIdentifier: String?, name: String?) -> Bool {
        if let id = bundleIdentifier, id.hasPrefix(bundlePrefix) { return true }
        if let name, name.hasPrefix(namePrefix) { return true }
        return false
    }

    /// Whether any application running now matches (a fresh query of the system's list each time).
    public static func anyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { matches(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName) }
    }
}
