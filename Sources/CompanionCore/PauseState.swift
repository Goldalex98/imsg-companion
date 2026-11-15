import Foundation

/// HomeChat's `control.paused`, held in memory only (agent design §5.6): it can pause the agent, never undo Alex's
/// local pause. A lock, not an actor, so the executor's synchronous `onControl` takes effect before its next check.
/// After a restart the remote pause comes back with the next poll (up to `fetchWait`).
public final class PauseState: @unchecked Sendable {
    private let lock = NSLock()
    private var remote: Bool?

    public init() {}

    /// nil (no control in the poll) clears the remote opinion.
    public func setRemote(_ paused: Bool?) { lock.withLock { remote = paused } }

    public func apply(_ control: SendsPage.Control?) { setRemote(control?.paused) }

    public var remotePaused: Bool { lock.withLock { remote == true } }

    public func effective(local: Bool) -> Bool { local || remotePaused }
}
