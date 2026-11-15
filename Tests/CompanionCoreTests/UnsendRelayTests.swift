import XCTest
@testable import CompanionCore
import IMsgCore

final class UnsendRelayTests: XCTestCase {
    private let alice = "+15550100001"
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }
    private var clock: TestClock!
    private var uplink: RecordingUplink!
    private var fixture: CompanionFixture!
    private var chat: Int64 = 0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("unsend-relay-\(UUID().uuidString)")
        clock = TestClock(Date(timeIntervalSince1970: 1_794_000_000))
        uplink = RecordingUplink()
        fixture = try CompanionFixture()
        chat = try fixture.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        for _ in 0..<3 { try fixture.addMessage(chats: [chat], text: "m", handle: alice) }
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            paused: false, cursor: 3).save(to: configURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var savedCursor: Int64? { CompanionConfig.load(from: configURL).cursor }

    private func event(_ rowID: Int64, _ mutation: Message.MutationEvent?, text: String = "") -> Message {
        Message(rowID: rowID, chatID: chat, sender: alice, text: text, date: clock.now - 60, isFromMe: false,
                service: "iMessage", handleID: 1, attachmentsCount: 0, guid: "guid-\(rowID)",
                unsentAt: mutation == .unsent ? clock.now : nil, mutationEvent: mutation)
    }

    private func relay(_ events: FakeEvents, paused: Bool = false) -> UnsendRelay {
        let uplink = self.uplink!, clock = self.clock!
        return UnsendRelay(events: { events.next() }, databasePath: fixture.url.path, configURL: configURL,
                           tokens: FakeTokens("test-token"), names: FakeNames([alice: "Test Person"]),
                           makeUplink: { _, _ in uplink }, serializer: UplinkSerializer(),
                           isPaused: { paused }, now: { clock.now }, restartDelay: { _ in })
    }

    func test_unsendIsRepostedWithoutTextAndKeepsTheCursor() async throws {
        let r = relay(FakeEvents([([event(2, .unsent)], nil)]))
        await r.run()
        XCTAssertEqual(uplink.batches.count, 1)
        let batch = uplink.batches[0]
        XCTAssertEqual(batch.cursor, 3)
        XCTAssertFalse(batch.firstRun)
        XCTAssertEqual(batch.threads.map(\.guid), ["iMessage;-;direct"])
        XCTAssertEqual(batch.threads[0].participants.map(\.name), ["Test Person"])
        XCTAssertEqual(batch.messages.count, 1)
        let message = batch.messages[0]
        XCTAssertEqual(message.guid, "guid-2")
        XCTAssertEqual(message.unsent, true)
        XCTAssertNil(message.text)
        XCTAssertEqual(message.kind, .text)
        XCTAssertEqual(message.attachmentCount, 0)
        XCTAssertEqual(savedCursor, 3)
        let pending = await r.pending
        XCTAssertEqual(pending, 0)
    }

    func test_editsAndNewRowsPostNothing() async throws {
        let r = relay(FakeEvents([([event(2, .edited, text: "changed"), event(4, nil, text: "new")], nil)]))
        await r.run()
        XCTAssertTrue(uplink.batches.isEmpty)
    }

    // HomeChat has never seen a row past the saved cursor; the reading loop sends it, already unsent.
    func test_unsendPastTheCursorIsLeftToTheReader() async throws {
        let r = relay(FakeEvents([([event(4, .unsent)], nil)]))
        await r.run()
        XCTAssertTrue(uplink.batches.isEmpty)
        let pending = await r.pending
        XCTAssertEqual(pending, 0)
    }

    func test_failedRepostStaysPendingAndGoesOnTheNextTry() async throws {
        uplink.script([.failure(.retryable(503))])
        let r = relay(FakeEvents([([event(2, .unsent)], nil)]))
        await r.run()
        XCTAssertEqual(uplink.batches.count, 1)
        var pending = await r.pending
        XCTAssertEqual(pending, 1)
        await r.flush()
        XCTAssertEqual(uplink.batches.count, 1, "waits out the backoff")
        clock.advance(5)
        await r.flush()
        XCTAssertEqual(uplink.batches.count, 2)
        XCTAssertEqual(uplink.batches[1].messages.map(\.guid), ["guid-2"])
        pending = await r.pending
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(savedCursor, 3)
    }

    func test_pausedHoldsTheRepost() async throws {
        let r = relay(FakeEvents([([event(2, .unsent)], nil)]), paused: true)
        await r.run()
        XCTAssertTrue(uplink.batches.isEmpty)
        let pending = await r.pending
        XCTAssertEqual(pending, 1)
    }

    // Review Focus 2: an overflowed watcher is started again and keeps relaying.
    func test_overflowRestartsTheWatcher() async throws {
        let r = relay(FakeEvents([([], MessageWatcherOverflowError(resumeAfterRowID: 3)), ([event(1, .unsent)], nil)]))
        await r.run()
        let restarts = await r.restarts
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(uplink.batches.flatMap(\.messages).map(\.guid), ["guid-1"])
    }
}

final class UplinkSerializerTests: XCTestCase {
    func test_postsOneAtATime() async throws {
        let uplink = SlowUplink()
        let serializer = UplinkSerializer()
        let batch = UplinkBatch(deviceID: "mac-0000aaaa", batchID: UUID(), cursor: 1, firstRun: false, threads: [],
                                messages: [])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try? await serializer.post(batch, via: uplink) } }
        }
        XCTAssertEqual(uplink.posts, 4)
        XCTAssertEqual(uplink.maxConcurrent, 1)
    }
}

final class FakeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [([Message], (any Error)?)]
    init(_ runs: [([Message], (any Error)?)]) { self.runs = runs }
    func next() -> AsyncThrowingStream<Message, any Error> {
        let run = lock.withLock { runs.isEmpty ? ([], nil) : runs.removeFirst() }
        return AsyncThrowingStream { continuation in
            for message in run.0 { continuation.yield(message) }
            continuation.finish(throwing: run.1)
        }
    }
}

final class SlowUplink: CompanionUplinking, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxConcurrent = 0
    private(set) var posts = 0
    func post(_ batch: UplinkBatch) async throws(UplinkError) -> UplinkAck {
        lock.withLock { active += 1; posts += 1; maxConcurrent = max(maxConcurrent, active) }
        try? await Task.sleep(for: .milliseconds(20))
        lock.withLock { active -= 1 }
        return UplinkAck(acceptedCursor: batch.cursor)
    }
}
