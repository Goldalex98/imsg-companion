import XCTest
@testable import CompanionCore

// Review Focus 5: HomeChat can pause the agent, never unpause a local pause.
final class PauseStateTests: XCTestCase {
    func test_remotePausePauses() {
        let pause = PauseState()
        pause.setRemote(true)
        XCTAssertTrue(pause.effective(local: false))
    }

    func test_remoteUnpauseNeverOverridesLocal() {
        let pause = PauseState()
        pause.setRemote(false)
        XCTAssertTrue(pause.effective(local: true))
    }

    func test_noControlFollowsLocal() {
        let pause = PauseState()
        pause.setRemote(true)
        pause.setRemote(nil)
        XCTAssertFalse(pause.effective(local: false))
        XCTAssertTrue(pause.effective(local: true))
    }

    func test_controlFromAPollIsSeenAtOnce() {
        let pause = PauseState()
        pause.apply(SendsPage.Control(paused: true))
        XCTAssertTrue(pause.remotePaused, "set synchronously, before the executor's next check")
    }
}
