import Foundation

/// The chat's turn state as the panel and the scenes see it (spec F2.2; `blocked` and `needs-answer` come later).
public enum ChatTurnState: Equatable { case none, running, stopping }

/// How a turn ended (Interface Contract: chatTurnEnded).
public enum ChatTurnOutcome: Equatable { case success(seconds: Double), error, interrupted }

/// Why a chat child is stopped (spec F2.2: graceful for idle / new chat; hard for exam, chat off, agent quit).
public enum ChatStopReason: String, Equatable { case idle, panelClosedLong, exam, chatOff, agentQuit, userStop, resume }

/// How a child was lost without a stop being asked for (Q12: each pauses the queue).
public enum ChatChildLoss: String, Equatable { case exited, writeFailed = "write-failed", overflow, idle }

/// What the panel and the runtime drive. All calls and all callbacks happen on the main queue.
public protocol ChatSessionDriving: AnyObject {
    var transcript: ChatTranscript { get }
    var turn: ChatTurnState { get }
    /// Called on the main queue, at most once per 50 ms while streaming, whenever transcript or turn changed.
    var onChange: (() -> Void)? { get set }
    var onTurnStarted: (() -> Void)? { get set }
    var onTurnEnded: ((ChatTurnOutcome) -> Void)? { get set }
    /// Called on the main queue, once, with the full text of a send whose line was not completely written to claude's stdin (a write error, the
    /// child gone, or a stop that abandoned the queue). Never called for a send whose line was written; the text is never sent again by itself.
    var onSendFailed: ((String) -> Void)? { get set }
    /// Called on the main queue with every `/` catalog frame the child reports (init's names, `commands_changed`'s descriptors; Q9).
    var onCatalog: ((ChatCatalogFrame) -> Void)? { get set }
    /// Called on the main queue with what the ledger decided about a written send: delivered, not delivered, in doubt or provably unwritten (Q13).
    var onSendSettled: ((ChatSendVerdict) -> Void)? { get set }
    /// Called on the main queue when the child was lost without anyone asking for its stop: it exited, a write to it failed, or its output overflowed.
    var onChildLost: ((ChatChildLoss) -> Void)? { get set }
    /// Called on the main queue when the CLI reported `conversation_reset` with trigger `clear` (Q25): the queue pauses with `cleared`.
    var onConversationCleared: (() -> Void)? { get set }
    /// A send whose fate is open: its line has not been reported written, or it is written and neither delivered, undelivered nor in doubt (Q13).
    /// `/clear` and `/compact` wait for it (Q25), and so does the queue's drain. Sends in doubt are not in it: they are held cards.
    var hasUnsettledSend: Bool { get }
    /// The Claude Code conversation id (the one `claude --resume` takes); nil until an init has named it (Q19).
    var sessionID: String? { get }
    /// Sends one user message; spawns the child on the first send. Ignored (returns false) while a turn is stopping, for blank text, and while a turn
    /// runs unless the request is a steer, which is written into the running turn (Q13).
    @discardableResult func send(_ request: ChatSendRequest) -> Bool
    /// The stop control while a turn runs (spec F2.2: interrupt control request, hard stop after 5 s without a result).
    func interrupt()
    /// Stops the child (graceful or hard per the reason, one 3 s deadline, spec F2.2 r6).
    func stop(_ reason: ChatStopReason)
    /// Makes the next send continue the conversation `id` (a Claude Code session id; `title` is for the transcript's divider): the live child is
    /// stopped gracefully and the next spawn takes `--resume <id>`. False, and nothing changes, while a turn runs or stops, while a send is
    /// unsettled, for an id that is not a UUID and for the conversation already in use.
    @discardableResult func resume(_ id: String, title: String) -> Bool
}

public extension ChatSessionDriving {
    /// A plain send of the draft's text.
    @discardableResult func send(_ text: String) -> Bool { send(ChatSendRequest(text: text)) }
}
