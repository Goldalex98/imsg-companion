import XCTest
@testable import CompanionCore
import IMsgCore

final class ForkGuardTests: XCTestCase {
    private let alice = "+15550100001"
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fork-guard-\(UUID().uuidString)")
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            paused: false, cursor: 0).save(to: configURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func test_forkRunningStopsTheReader() async throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], text: "m", handle: alice)
        let uplink = RecordingUplink()
        let guardian = ForkGuard(detector: FakeFork(true), pause: PauseState())
        let service = CompanionService(databasePath: f.url.path, configURL: configURL, tokens: FakeTokens("t"),
                                       names: FakeNames([:]), makeUplink: { _, _ in uplink },
                                       isPaused: { guardian.blocksUplink() })
        let status = await service.tick()
        XCTAssertEqual(status.state, .paused)
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertTrue(guardian.forkRunning)
    }

    func test_forkRunningHoldsUnsends() async throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], text: "m", handle: alice)
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            paused: false, cursor: 1).save(to: configURL)
        let unsent = Message(rowID: 1, chatID: chat, sender: alice, text: "", date: Date(), isFromMe: false,
                             service: "iMessage", handleID: 1, attachmentsCount: 0, guid: "g1", unsentAt: Date(),
                             mutationEvent: .unsent)
        let uplink = RecordingUplink()
        let guardian = ForkGuard(detector: FakeFork(true), pause: PauseState())
        let events = FakeEvents([([unsent], nil)])
        let relay = UnsendRelay(events: { events.next() }, databasePath: f.url.path, configURL: configURL,
                                tokens: FakeTokens("t"), names: FakeNames([:]), makeUplink: { _, _ in uplink },
                                serializer: UplinkSerializer(), isPaused: { guardian.blocksUplink() },
                                restartDelay: { _ in })
        await relay.run()
        XCTAssertTrue(uplink.batches.isEmpty)
        let pending = await relay.pending
        XCTAssertEqual(pending, 1)
    }

    func test_remotePauseAlsoBlocks() {
        let pause = PauseState()
        let guardian = ForkGuard(detector: FakeFork(false), pause: pause)
        XCTAssertFalse(guardian.blocksUplink())
        pause.setRemote(true)
        XCTAssertTrue(guardian.blocksUplink())
        XCTAssertFalse(guardian.forkRunning)
    }
}

struct FakeFork: ForkDetecting {
    let running: Bool
    init(_ running: Bool) { self.running = running }
    func isForkRunning() -> Bool { running }
}
