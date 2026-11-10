// This file is generated upstream by the build plugin (BuildInfoGenerator.swift); here it is written once, for the pinned commit.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    /// The Git branch, if the build uses a branch checkout.
    public static let branch: String? = nil

    /// The exact Git tag for the current commit, if one is available.
    public static let tag: String? = "v1.99.1"

    /// The full Git commit identifier, if one is available.
    public static let commit: String? = "2f573f73af5e768d90847dce20c97fa9535d7164"

    /// Whether the repository had uncommitted changes during the build.
    public static let hasUncommittedChanges: Bool? = false

    /// A value suitable for display in logs and diagnostic output.
    public static let version: String = {
        let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}
