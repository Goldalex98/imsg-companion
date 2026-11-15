import XCTest
@testable import CompanionCore

final class HealthMarkTests: XCTestCase {
    private var folder: URL!
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func test_startWritesVersionWithNoProof() throws {
        let store = HealthMarkStore(folder: folder)
        try store.start(version: "abc1234", now: t0)
        let mark = try XCTUnwrap(store.read())
        XCTAssertEqual(mark, HealthMark(version: "abc1234", startedAt: t0, readOKAt: nil, homechatOKAt: nil))
    }

    func test_readAndHomeChatMarksFromARealTick() async throws {
        let configURL = folder.appendingPathComponent("companion.json")
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa", cursor: 0)
            .save(to: configURL)
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: ["+15550100001"])
        let uplink = RecordingUplink()
        let service = CompanionService(databasePath: f.url.path, configURL: configURL, tokens: FakeTokens("t"),
                                       names: FakeNames([:]), makeUplink: { _, _ in uplink })
        let store = HealthMarkStore(folder: folder)
        try store.start(version: "abc1234", now: t0)

        var status = await service.tick()
        store.record(status, now: t0 + 1)
        XCTAssertEqual(store.read()?.readOKAt, t0 + 1, "an idle tick read chat.db")
        XCTAssertNil(store.read()?.homechatOKAt, "nothing went up yet")

        try f.addMessage(chats: [chat], text: "m", handle: "+15550100001")
        status = await service.tick()
        store.record(status, now: t0 + 2)
        XCTAssertEqual(store.read()?.homechatOKAt, t0 + 2, "a batch was accepted")
    }

    func test_failedTickMarksNothing() throws {
        let store = HealthMarkStore(folder: folder)
        try store.start(version: "abc1234", now: t0)
        store.record(CompanionStatus(state: .noDatabaseAccess), now: t0 + 1)
        store.record(CompanionStatus(state: .offline(retryIn: 5)), now: t0 + 2)
        XCTAssertNil(store.read()?.readOKAt)
        XCTAssertNil(store.read()?.homechatOKAt)
    }

    func test_statusPostAlsoProvesHomeChat() throws {
        let store = HealthMarkStore(folder: folder)
        try store.start(version: "abc1234", now: t0)
        store.homechatOK(now: t0 + 3)
        XCTAssertEqual(store.read()?.homechatOKAt, t0 + 3)
    }
}
