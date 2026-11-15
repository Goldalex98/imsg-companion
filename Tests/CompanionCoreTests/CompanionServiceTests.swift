import XCTest
@testable import CompanionCore
import IMsgCore

final class CompanionServiceTests: XCTestCase {
    private let alice = "+15550100001"
    private let bob = "test@example.invalid"
    private let day: TimeInterval = 86_400
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }
    private var clock: TestClock!
    private var tokens: FakeTokens!
    private var uplink: RecordingUplink!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("companion-service-\(UUID().uuidString)")
        clock = TestClock(Date(timeIntervalSince1970: 1_794_000_000))
        tokens = FakeTokens("test-token")
        uplink = RecordingUplink()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func configure(cursor: Int64?, url: URL? = URL(string: "https://uplink-test.invalid")) throws {
        try CompanionConfig(uplinkURL: url, deviceID: "mac-0000aaaa", paused: false, cursor: cursor).save(to: configURL)
    }

    private var savedCursor: Int64? { CompanionConfig.load(from: configURL).cursor }

    private func service(_ path: String, names: [String: String] = [:], paging: (any MessagePaging)? = nil,
                         paused: Bool = false) -> CompanionService {
        let uplink = self.uplink!, clock = self.clock!
        return CompanionService(databasePath: path, configURL: configURL, tokens: tokens, names: FakeNames(names),
                                makeUplink: { _, _ in uplink },
                                makePaging: { path in try paging ?? IMsgCorePaging(path: path) },
                                isPaused: { paused }, now: { clock.now })
    }

    private func directChat(_ f: CompanionFixture) throws -> Int64 {
        try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
    }

    func test_firstRunUplinksLastThreeDaysOnly() async throws {
        try configure(cursor: nil)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        let now = clock.now
        try f.addMessage(chats: [chat], text: "old", date: now - 5 * day, handle: alice)
        try f.addMessage(chats: [chat], guid: "recent-guid", text: "recent", date: now - 2 * day, handle: alice)
        try f.addMessage(chats: [chat], text: "newest", date: now - 1 * day, handle: alice)
        let s = service(f.url.path)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertEqual(uplink.batches[0].messages.map(\.rowid), [2, 3])
        XCTAssertEqual(uplink.batches[0].messages.first?.guid, "recent-guid", "the row's own guid goes up")
        XCTAssertTrue(uplink.batches[0].firstRun)
        XCTAssertEqual(savedCursor, 3)
        try f.addMessage(chats: [chat], text: "later", date: now, handle: alice)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 2)
        XCTAssertEqual(uplink.batches[1].messages.map(\.rowid), [4])
        XCTAssertFalse(uplink.batches[1].firstRun)
    }

    func test_cursorAdvancesOnlyOnAck() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<3 { try f.addMessage(chats: [chat], text: "m", handle: alice) }
        uplink.script([.failure(.retryable(503))])
        let status = await service(f.url.path).tick()
        XCTAssertEqual(status.state, .offline(retryIn: 5))
        XCTAssertEqual(savedCursor, 0)
    }

    func test_failedPostKeepsCursorAndReplaysSameRows() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<3 { try f.addMessage(chats: [chat], text: "m", handle: alice) }
        uplink.script([.failure(.retryable(503)), .failure(.retryable(nil))])
        let s = service(f.url.path)
        _ = await s.tick()
        clock.advance(1)
        let waiting = await s.tick()
        XCTAssertEqual(waiting.state, .offline(retryIn: 4))
        XCTAssertEqual(uplink.batches.count, 1, "no post inside the backoff window")
        clock.advance(4)
        let second = await s.tick()
        XCTAssertEqual(second.state, .offline(retryIn: 10), "backoff doubles")
        clock.advance(10)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 3)
        XCTAssertEqual(Set(uplink.batches.map { $0.messages.map(\.guid) }).count, 1, "every attempt replays the same rows")
        XCTAssertEqual(savedCursor, 3)
    }

    func test_backoffCapsAt300Seconds() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", handle: alice)
        uplink.script(Array(repeating: .failure(.retryable(nil)), count: 9))
        let s = service(f.url.path)
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            if case .offline(let delay) = await s.tick().state { delays.append(delay); clock.advance(delay) }
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 80, 160, 300, 300, 300])
    }

    func test_ackBelowBatchCursorIsRespected() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<5 { try f.addMessage(chats: [chat], text: "m", handle: alice) }
        uplink.script([.success(UplinkAck(acceptedCursor: 3))])
        _ = await service(f.url.path).tick()
        XCTAssertEqual(savedCursor, 3)
    }

    func test_ackAboveBatchCursorIsClamped() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<2 { try f.addMessage(chats: [chat], text: "m", handle: alice) }
        uplink.script([.success(UplinkAck(acceptedCursor: 99))])
        _ = await service(f.url.path).tick()
        XCTAssertEqual(savedCursor, 2)
    }

    func test_orphanOnlyStretchAdvancesWithoutPost() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<2 { try f.addMessage(chats: [chat], text: "m", handle: alice) }
        let s = service(f.url.path)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1)
        try f.addMessage(chats: [], text: "orphan", date: clock.now, handle: alice)
        try f.addMessage(chats: [], text: "orphan", date: clock.now, handle: alice)
        _ = await s.tick()
        XCTAssertEqual(savedCursor, 2, "fresh chat-less rows hold the cursor; Messages may still link them")
        clock.advance(11)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertEqual(savedCursor, 4)
    }

    func test_backlogIsBatched() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<450 { try f.addMessage(chats: [chat], text: "m", date: clock.now, handle: alice) }
        let s = service(f.url.path)
        var cursors: [Int64?] = []
        for _ in 0..<3 { _ = await s.tick(); cursors.append(savedCursor) }
        XCTAssertEqual(uplink.batches.map(\.messages.count), [200, 200, 50])
        XCTAssertEqual(uplink.batches.map(\.cursor), [200, 400, 450])
        XCTAssertEqual(cursors, [200, 400, 450])
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 3, "caught up and nothing changed")
    }

    func test_oversizedBatchIsSplitUnderTheBodyLimit() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        let long = String(repeating: "👋", count: 4000)  // 16 KB of UTF-8 each; 200 of them is over 3 MB
        for _ in 0..<200 { try f.addMessage(chats: [chat], text: long, date: clock.now - 60, handle: alice) }
        let s = service(f.url.path)
        for _ in 0..<20 where savedCursor != 200 { _ = await s.tick() }
        XCTAssertEqual(savedCursor, 200)
        XCTAssertGreaterThan(uplink.batches.count, 1)
        for batch in uplink.batches {
            XCTAssertLessThanOrEqual(try CompanionJSON.encoder.encode(batch).count, 1_000_000)
            XCTAssertEqual(batch.cursor, batch.messages.last?.rowid, "a cut batch's cursor ends at its last message")
            XCTAssertEqual(Set(batch.threads.map(\.guid)), Set(batch.messages.map(\.threadGUID)))
        }
        XCTAssertEqual(uplink.batches.flatMap { $0.messages.map(\.rowid) }, Array(1...200))
    }

    func test_ssnInAttributedBodyOnlyIsScrubbed() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)],
                         attributedBody: CompanionFixture.archived("mine is 123-45-6789 ok"), handle: alice)
        _ = await service(f.url.path).tick()
        let text = try XCTUnwrap(uplink.batches.first?.messages.first?.text)
        XCTAssertEqual(text, "mine is [SSN removed] ok")
        XCTAssertNil(text.range(of: "6789"))
    }

    func test_skippedMessagesAreSentWithoutText() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "Your verification code is 482913", handle: alice)
        _ = await service(f.url.path).tick()
        let message = try XCTUnwrap(uplink.batches.first?.messages.first)
        XCTAssertEqual(message.kind, .skipped)
        XCTAssertNil(message.text)
    }

    func test_unreadableDatabaseReportsPermission() async throws {
        try configure(cursor: 0)
        let missing = folder.appendingPathComponent("missing.db").path
        let status = await service(missing).tick()
        XCTAssertEqual(status.state, .noDatabaseAccess)
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertEqual(savedCursor, 0)
    }

    func test_pausedDoesNothing() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", handle: alice)
        let s = service(f.url.path)
        let paused = await s.setPaused(true)
        XCTAssertEqual(paused.state, .paused)
        let ticked = await s.tick()
        XCTAssertEqual(ticked.state, .paused)
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertTrue(CompanionConfig.load(from: configURL).paused)
        let missing = service(folder.appendingPathComponent("missing.db").path)
        let pausedMissing = await missing.tick()
        XCTAssertEqual(pausedMissing.state, .paused, "paused is checked before the database is opened")
        _ = await s.setPaused(false)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1)
    }

    func test_pauseDuringPostIsKept() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", handle: alice)
        let s = service(f.url.path)
        uplink.onPost = { _ = await s.setPaused(true) }
        let status = await s.tick()
        let saved = CompanionConfig.load(from: configURL)
        XCTAssertTrue(saved.paused, "the cursor save must not undo a pause made while posting")
        XCTAssertEqual(saved.cursor, 1, "the accepted batch is still recorded")
        XCTAssertEqual(status.state, .paused)
    }

    func test_overlappingTicksPostOnce() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", handle: alice)
        let s = service(f.url.path)
        let nested = NestedStatus()
        uplink.onPost = { await nested.set(await s.tick()) }
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1, "a tick that starts while one is posting does nothing")
        let inner = await nested.value
        XCTAssertEqual(inner?.state, .uplinking)
    }

    func test_unauthorizedStops() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        try f.addMessage(chats: [chat], text: "m", handle: alice)
        uplink.script([.failure(.unauthorized)])
        let s = service(f.url.path)
        let stopped = await s.tick()
        guard case .stopped = stopped.state else { return XCTFail("got \(stopped.state)") }
        try f.addMessage(chats: [chat], text: "m", handle: alice)
        clock.advance(600)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1, "no posts while stopped")
        tokens.write("new-token")
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 2)
        XCTAssertEqual(savedCursor, 2)
    }

    func test_rejectedStopsWithoutMessageContent() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "secret words", handle: alice)
        uplink.script([.failure(.rejected(422))])
        let status = await service(f.url.path).tick()
        guard case .stopped(let reason) = status.state else { return XCTFail("got \(status.state)") }
        XCTAssertTrue(reason.contains("422"), reason)
        XCTAssertFalse(reason.contains("secret") || reason.contains(alice), reason)
    }

    func test_namesAttached() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let group = try f.addChat(guid: "iMessage;+;group", style: 43, displayName: "", handles: [alice, bob])
        try f.addMessage(chats: [group], text: "m", handle: bob)
        _ = await service(f.url.path, names: [alice: "Test Person"]).tick()
        let thread = try XCTUnwrap(uplink.batches.first?.threads.first)
        XCTAssertEqual(thread.kind, .group)
        XCTAssertNil(thread.displayName)
        XCTAssertEqual(thread.participants.first { $0.handle == alice }?.name, "Test Person")
        XCTAssertNil(thread.participants.first { $0.handle == bob }?.name)
    }

    func test_contactsDeniedGivesNullNames() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let group = try f.addChat(guid: "iMessage;+;group", style: 43, displayName: nil, handles: [alice, bob])
        try f.addMessage(chats: [group], text: "m", handle: bob)
        _ = await service(f.url.path, names: [:]).tick()
        let thread = try XCTUnwrap(uplink.batches.first?.threads.first)
        XCTAssertEqual(thread.participants.count, 2)
        XCTAssertTrue(thread.participants.allSatisfy { $0.name == nil })
        XCTAssertNil(thread.displayName)
    }

    func test_reopensWhenTheDatabaseFileIsReplaced() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        try f.addMessage(chats: [chat], text: "first", date: clock.now - 60, handle: alice)
        let s = service(f.url.path)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.flatMap { $0.messages.map(\.rowid) }, [1])
        let replacement = try CompanionFixture()
        let newChat = try directChat(replacement)
        try replacement.addMessage(chats: [newChat], text: "first", date: clock.now - 60, handle: alice)
        try replacement.addMessage(chats: [newChat], text: "second", date: clock.now - 60, handle: alice)
        XCTAssertEqual(rename(replacement.url.path, f.url.path), 0)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 2)
        XCTAssertEqual(uplink.batches[1].messages.map(\.rowid), [2])
        XCTAssertEqual(savedCursor, 2)
    }

    func test_fileGoneAfterOpenReportsNoAccess() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", date: clock.now - 60, handle: alice)
        let s = service(f.url.path)
        _ = await s.tick()
        try FileManager.default.removeItem(at: f.url)
        let status = await s.tick()
        XCTAssertEqual(status.state, .noDatabaseAccess)
    }

    func test_cursorAheadOfDatabaseStopsAndRecoversWhenReset() async throws {
        try configure(cursor: 10_000)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<40 { try f.addMessage(chats: [chat], text: "m", date: clock.now - 60, handle: alice) }
        let s = service(f.url.path)
        let status = await s.tick()
        XCTAssertEqual(status.state, .stopped("database_replaced"))
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertEqual(savedCursor, 10_000, "the cursor is never lowered on its own")
        let again = await s.tick()
        XCTAssertEqual(again.state, status.state, "still stopped on the next tick")
        try ConfigEdits.resetCursor(configURL: configURL)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.count, 1, "reset-cursor lets the next tick start again")
        XCTAssertTrue(uplink.batches[0].firstRun)
    }

    // Final review I3: new rows filling the gap below the old cursor must not quietly resume reading past them.
    func test_databaseReplacedStaysStoppedAsNewRowsArrive() async throws {
        try configure(cursor: 45)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<40 { try f.addMessage(chats: [chat], text: "m", date: clock.now - 60, handle: alice) }
        let s = service(f.url.path)
        _ = await s.tick()
        for _ in 0..<10 { try f.addMessage(chats: [chat], text: "new", date: clock.now - 10, handle: alice) }
        let later = await s.tick()
        XCTAssertEqual(later.state, .stopped("database_replaced"))
        let restarted = await service(f.url.path).tick()
        XCTAssertEqual(restarted.state, .stopped("database_replaced"), "kept across a restart")
        XCTAssertTrue(uplink.batches.isEmpty, "rows 41-45 are never skipped")
        XCTAssertEqual(savedCursor, 45)
    }

    // Reset days after the replacement: rows that arrived since the replacement are still read (the first-run
    // window counts back from the replacement, not from the reset).
    func test_resetCursorReadsFromTheReplacementWindow() async throws {
        try configure(cursor: 45)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<40 { try f.addMessage(chats: [chat], text: "old", date: clock.now - 10 * 86_400, handle: alice) }
        let s = service(f.url.path)
        _ = await s.tick()
        let replaced = clock.now
        clock.advance(5 * 86_400)
        for _ in 0..<3 { try f.addMessage(chats: [chat], text: "new", date: replaced + 86_400, handle: alice) }
        try ConfigEdits.resetCursor(configURL: configURL)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.first?.messages.map(\.rowid), [41, 42, 43])
    }

    func test_deletingTheNewestMessagesIsNotAReset() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        for _ in 0..<3 { try f.addMessage(chats: [chat], text: "m", date: clock.now - 60, handle: alice) }
        let s = service(f.url.path)
        _ = await s.tick()
        XCTAssertEqual(savedCursor, 3)
        try f.exec("DELETE FROM message WHERE ROWID = 3")
        let after = await s.tick()
        XCTAssertNotEqual(after.state, .stopped("database_replaced"))
        try f.addMessage(chats: [chat], text: "new", date: clock.now - 10, handle: alice)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.last?.messages.map(\.rowid), [4], "AUTOINCREMENT never reuses ROWID 3")
    }

    func test_systemRowsAreNotUplinkedButTheCursorPassesThem() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;+;group", style: 43, displayName: nil, handles: [alice, bob])
        try f.addMessage(chats: [chat], text: "one", date: clock.now - 60, handle: alice)
        for type in 1...3 { try f.addMessage(chats: [chat], date: clock.now - 60, handle: bob, itemType: type) }
        try f.addMessage(chats: [chat], text: "two", date: clock.now - 60, handle: bob)
        try f.addMessage(chats: [chat], date: clock.now - 60, handle: bob, itemType: 1)
        try f.addMessage(chats: [chat], text: "kept", date: clock.now - 60, handle: bob, itemType: 2)
        _ = await service(f.url.path).tick()
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertEqual(uplink.batches[0].messages.map(\.rowid), [1, 5, 7], "a non-zero item_type with text is still read")
        XCTAssertEqual(savedCursor, 7)
    }

    func test_notConfigured() async throws {
        try configure(cursor: 0, url: nil)
        let missing = folder.appendingPathComponent("missing.db").path
        let noURL = await service(missing).tick()
        XCTAssertEqual(noURL.state, .notConfigured)
        try configure(cursor: 0)
        tokens.write(nil)
        let noToken = await service(missing).tick()
        XCTAssertEqual(noToken.state, .notConfigured)
        XCTAssertTrue(uplink.batches.isEmpty)
    }

    // MARK: - Agent changes (plan Task 5)

    func test_cursorAdvancesToNextRowIDPastHiddenRows() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        try f.addMessage(chats: [chat], text: "m", date: clock.now - 60, handle: alice)
        let visible = try XCTUnwrap(try MessageStore(path: f.url.path)
            .messagesAfterPage(afterRowID: 0, chatID: nil, limit: 10, includeReactions: true).messages.first)
        // IMsgCore scanned up to ROWID 9 but returned only ROWID 1 (it hides duplicate URL-preview rows).
        let page = MessagesAfterPage(messages: [visible], nextRowID: 9, hasMore: false)
        let s = service(f.url.path, paging: FakePaging([page]))
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.first?.messages.map(\.rowid), [1])
        XCTAssertEqual(uplink.batches.first?.cursor, 9)
        XCTAssertEqual(savedCursor, 9)
    }

    func test_recentOrphanMidPageHoldsCursorBelowIt() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        try f.addMessage(chats: [chat], text: "before", date: clock.now - 60, handle: alice)
        try f.addMessage(chats: [], text: "orphan", date: clock.now, handle: alice)
        try f.addMessage(chats: [chat], text: "after", date: clock.now, handle: alice)
        let s = service(f.url.path)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.first?.messages.map(\.rowid), [1])
        XCTAssertEqual(savedCursor, 1, "nothing past a fresh orphan, so it can still be linked")
        clock.advance(11)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.last?.messages.map(\.rowid), [3])
        XCTAssertEqual(savedCursor, 3)
    }

    func test_serviceIsPerMessage() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "any;+;chat-test", style: 43, displayName: nil, handles: [alice, bob],
                                 service: "SMS")
        try f.addMessage(chats: [chat], text: "blue", date: clock.now - 60, handle: alice, service: "iMessage")
        try f.addMessage(chats: [chat], text: "green", date: clock.now - 60, handle: bob, service: "SMS")
        _ = await service(f.url.path).tick()
        XCTAssertEqual(uplink.batches.first?.messages.map(\.service), ["iMessage", "SMS"])
    }

    func test_codeTextGoesUpInAThreadAlexWritesIn() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let written = try directChat(f)
        let silent = try f.addChat(guid: "any;-;silent", style: 45, displayName: nil, handles: [bob])
        try f.addMessage(chats: [written], text: "what's the code?", date: clock.now - 120, fromMe: true)
        try f.addMessage(chats: [written], text: "the code is 4829", date: clock.now - 60, handle: alice)
        try f.addMessage(chats: [silent], text: "Your code is 482913", date: clock.now - 60, handle: bob)
        _ = await service(f.url.path).tick()
        let messages = try XCTUnwrap(uplink.batches.first?.messages)
        XCTAssertEqual(messages.map(\.kind), [.text, .text, .skipped])
        XCTAssertEqual(messages[1].text, "the code is 4829")
        XCTAssertNil(messages[2].text)
    }

    func test_fromMeInThisPageCountsForLaterRows() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        let chat = try directChat(f)
        let s = service(f.url.path)
        _ = await s.tick()
        try f.addMessage(chats: [chat], text: "send me the pin", date: clock.now - 2, fromMe: true)
        try f.addMessage(chats: [chat], text: "pin 4829", date: clock.now - 1, handle: alice)
        _ = await s.tick()
        XCTAssertEqual(uplink.batches.last?.messages.map(\.kind), [.text, .text])
    }

    func test_pausedSkipsUplink() async throws {
        try configure(cursor: 0)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", date: clock.now - 60, handle: alice)
        let s = service(f.url.path, paused: true)
        let status = await s.tick()
        XCTAssertEqual(status.state, .paused)
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertEqual(savedCursor, 0)
    }

    func test_backoffComesFromTunables() async throws {
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            cursor: 0, tunables: .init(backoffInitialSeconds: 2, backoffMaxSeconds: 3)).save(to: configURL)
        let f = try CompanionFixture()
        try f.addMessage(chats: [try directChat(f)], text: "m", date: clock.now - 60, handle: alice)
        uplink.script([.failure(.retryable(503)), .failure(.retryable(503)), .failure(.retryable(503))])
        let s = service(f.url.path)
        var waits: [CompanionStatus.State] = []
        for _ in 0..<3 { waits.append(await s.tick().state); clock.advance(10) }
        XCTAssertEqual(waits, [.offline(retryIn: 2), .offline(retryIn: 3), .offline(retryIn: 3)])
    }
}

/// Hands out scripted pages, then empty ones.
final class FakePaging: MessagePaging, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [MessagesAfterPage]
    init(_ pages: [MessagesAfterPage]) { self.pages = pages }
    func page(after rowID: Int64, limit: Int) throws -> MessagesAfterPage {
        lock.withLock { pages.isEmpty ? MessagesAfterPage(messages: [], nextRowID: rowID, hasMore: false) : pages.removeFirst() }
    }
}

actor NestedStatus {
    var value: CompanionStatus?
    func set(_ status: CompanionStatus) { value = status }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

final class FakeTokens: CompanionTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    @discardableResult func write(_ token: String?) -> Bool { lock.lock(); self.token = token; lock.unlock(); return true }
}

struct FakeNames: CompanionNameResolving {
    let table: [String: String]
    init(_ table: [String: String]) { self.table = table }
    func names(for handles: [String]) async -> [String: String] { table.filter { handles.contains($0.key) } }
}

final class RecordingUplink: CompanionUplinking, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UplinkBatch] = []
    private var queue: [Result<UplinkAck, UplinkError>] = []
    /// Runs inside post(), while the service is suspended awaiting it.
    nonisolated(unsafe) var onPost: (@Sendable () async -> Void)?
    var batches: [UplinkBatch] { lock.lock(); defer { lock.unlock() }; return recorded }
    func script(_ responses: [Result<UplinkAck, UplinkError>]) { lock.lock(); queue = responses; lock.unlock() }
    func post(_ batch: UplinkBatch) async throws(UplinkError) -> UplinkAck {
        let next: Result<UplinkAck, UplinkError> = lock.withLock {
            recorded.append(batch)
            return queue.isEmpty ? .success(UplinkAck(acceptedCursor: batch.cursor)) : queue.removeFirst()
        }
        if let onPost { self.onPost = nil; await onPost() }
        return try next.get()
    }
}
