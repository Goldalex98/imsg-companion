import AppKit
import Foundation

/// The single-uploader rule (agent design §5.7): nothing goes up while the fork app runs.
public protocol ForkDetecting: Sendable {
    func isForkRunning() -> Bool
}

public struct RunningForkDetector: ForkDetecting {
    public static let forkBundleID = "io.github.goldalex98.msgblast-imessage"
    public init() {}
    public func isForkRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.forkBundleID).isEmpty
    }
}

/// The pause the reader, the unsend relay and the send executor consult, on top of the config's own `paused`.
public struct ForkGuard: Sendable {
    private let detector: any ForkDetecting
    private let pause: PauseState

    public init(detector: any ForkDetecting = RunningForkDetector(), pause: PauseState) {
        self.detector = detector; self.pause = pause
    }

    public var forkRunning: Bool { detector.isForkRunning() }

    public func blocksUplink() -> Bool { pause.remotePaused || detector.isForkRunning() }
}
