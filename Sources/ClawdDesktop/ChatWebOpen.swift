import AppKit
import ClawdCore

/// The one place the web chat opens a link: a Cmd-click on an http(s) link in a reply goes to the default browser. It re-checks the URL itself
/// (`ChatWebLink.openable`: http or https, a host, at most 2 KiB), so no caller can open anything else through it. Lint exempts this file from
/// `workspace-open` and `open-call` and no other.
public enum ChatWebOpen {
    public static let production: (URL) -> Void = { url in
        guard let checked = ChatWebLink.openable(url.absoluteString) else { return }
        NSWorkspace.shared.open(checked)
    }
}
