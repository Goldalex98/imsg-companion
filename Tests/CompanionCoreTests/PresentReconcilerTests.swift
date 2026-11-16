import XCTest
@testable import CompanionCore

final class PresentReconcilerTests: XCTestCase {
    private let alice = "+15550100001"
    private let day: TimeInterval = 86_400
    /// 2026-11-15T00:00Z, so now − 14 days is 2026-11-01T00:00Z.
    private let start = Date(timeIntervalSince1970: 1_793_491_200 + 14 * 86_400)
    private let reference: TimeInterval = 978_307_200
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }
    private var clock: TestClock!
    private var tokens: FakeTokens!
    private var uplink: RecordingUplink!
    private let idle = CompanionStatus(state: .idle, cursor: 42, pendingEstimate: 0)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("companion-present-\(UUID().uuidString)")
        clock = TestClock(start)
        tokens = FakeTokens("test-token")
        uplink = RecordingUplink()
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa", cursor: 42)
            .save(to: configURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var config: CompanionConfig { CompanionConfig.load(from: configURL) }

    private func reconciler(_ snapshot: @escaping @Sendable (Int64) async -> [String: [PresentRow]]?) -> PresentReconciler {
        let uplink = self.uplink!, clock = self.clock!
        return PresentReconciler(configURL: configURL, tokens: tokens, makeUplink: { _, _ in uplink },
                                 serializer: UplinkSerializer(), snapshot: snapshot, now: { clock.now })
    }

    /// Rows dated `offset` seconds after the window starts, in Apple reference seconds.
    private func row(_ guid: String, _ offset: TimeInterval) -> PresentRow {
        PresentRow(guid: guid, date: 1_793_491_200 - reference + offset)
    }

    private func fixed(_ rows: [String: [PresentRow]]) -> @Sendable (Int64) async -> [String: [PresentRow]]? {
        { _ in rows }
    }

    func test_sendsAPresentOnlyRequestWithTheSavedCursor() async throws {
        let outcome = await reconciler(fixed(["any;-;t1": [row("g1", 10), row("g2", 20)]])).runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .done)
        let batch = try XCTUnwrap(uplink.batches.first)
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertEqual(batch.cursor, 42)
        XCTAssertFalse(batch.firstRun)
        XCTAssertEqual(batch.deviceID, "mac-0000aaaa")
        XCTAssertTrue(batch.messages.isEmpty)
        XCTAssertTrue(batch.threads.isEmpty)
        XCTAssertEqual(batch.present, [PresentEntry(threadGUID: "any;-;t1", since: 1_793_491_200, guids: ["g1", "g2"])])
        XCTAssertEqual(config.lastPresentAt, start)
        XCTAssertEqual(config.cursor, 42, "a present request never moves the cursor")
    }

    func test_sinceAskedForIsUnixEpochSecondsFourteenDaysBack() async throws {
        let asked = AskedSince()
        clock.advance(0.75)
        _ = await reconciler({ await asked.record($0); return [:] }).runIfDue(after: idle)
        let value = await asked.value
        XCTAssertEqual(value, 1_793_491_200)
    }

    func test_notDueWithinADayOfTheLastAttemptWhateverItsOutcome() async throws {
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        uplink.script([.failure(.retryable(503))])
        let first = await r.runIfDue(after: idle)
        XCTAssertEqual(first?.result, .failed)
        XCTAssertEqual(first?.code, 503)
        for _ in 0..<100 {
            clock.advance(60)
            let again = await r.runIfDue(after: idle)
            XCTAssertNil(again)
        }
        XCTAssertEqual(uplink.batches.count, 1)
        clock.advance(day)
        let next = await r.runIfDue(after: idle)
        XCTAssertEqual(next?.result, .done)
        XCTAssertEqual(uplink.batches.count, 2)
    }

    func test_onlyRunsWhenTheReaderIsIdleAndCaughtUp() async throws {
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        let busy: [CompanionStatus] = [
            CompanionStatus(state: .paused, cursor: 42, pendingEstimate: 0),
            CompanionStatus(state: .stopped("database_replaced"), cursor: 42, pendingEstimate: 0),
            CompanionStatus(state: .offline(retryIn: 5), cursor: 42, pendingEstimate: 0),
            CompanionStatus(state: .uplinking, cursor: 42, pendingEstimate: 0),
            CompanionStatus(state: .notConfigured, cursor: 42, pendingEstimate: 0),
            CompanionStatus(state: .idle, cursor: 42, pendingEstimate: 3),
            CompanionStatus(state: .idle, cursor: 42, pendingEstimate: nil),
            CompanionStatus(state: .idle, cursor: nil, pendingEstimate: 0),
        ]
        for status in busy {
            let outcome = await r.runIfDue(after: status)
            XCTAssertNil(outcome, "\(status)")
        }
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertNil(config.lastPresentAttemptAt, "a skipped pass does not use up the day")
        let ran = await r.runIfDue(after: idle)
        XCTAssertEqual(ran?.result, .done)
    }

    func test_noTokenOrNoSavedCursorDoesNothing() async throws {
        tokens.write(nil)
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        let noToken = await r.runIfDue(after: idle)
        XCTAssertNil(noToken)
        tokens.write("test-token")
        try CompanionConfig.update(at: configURL) { $0.cursor = nil }
        let noCursor = await r.runIfDue(after: idle)
        XCTAssertNil(noCursor)
        XCTAssertTrue(uplink.batches.isEmpty)
    }

    func test_unauthorizedBlocksUntilTheTokenChanges() async throws {
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        uplink.script([.failure(.unauthorized)])
        let first = await r.runIfDue(after: idle)
        XCTAssertEqual(first?.code, 401)
        clock.advance(3 * day)
        let blocked = await r.runIfDue(after: idle)
        XCTAssertNil(blocked)
        let forced = await r.runIfDue(after: idle, force: true)
        XCTAssertNil(forced, "present-now does not get past a 401")
        tokens.write("new-token")
        let after = await r.runIfDue(after: idle)
        XCTAssertEqual(after?.result, .done)
        XCTAssertEqual(uplink.batches.count, 2)
    }

    // If the daily stamp can't be saved, nothing is sent: otherwise every 2 s idle pass would post again.
    func test_noRunWhenTheDailyStampCannotBeSaved() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        for _ in 0..<3 {
            let outcome = await r.runIfDue(after: idle)
            XCTAssertNil(outcome)
        }
        XCTAssertTrue(uplink.batches.isEmpty)
    }

    func test_forceIgnoresTheDailyGate() async throws {
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        _ = await r.runIfDue(after: idle)
        let forced = await r.runIfDue(after: idle, force: true)
        XCTAssertEqual(forced?.result, .done)
        XCTAssertEqual(uplink.batches.count, 2)
    }

    func test_aBigThreadMovesItsOwnSinceAndIsNeverTruncated() async throws {
        let rows = (0..<2001).map { row("g\($0)", TimeInterval(100 + $0) + 0.25) }
        _ = await reconciler(fixed(["any;-;big": rows, "any;-;small": [row("s", 5)]])).runIfDue(after: idle)
        let present = try XCTUnwrap(uplink.batches.first?.present)
        let big = try XCTUnwrap(present.first { $0.threadGUID == "any;-;big" })
        XCTAssertGreaterThan(big.since, 1_793_491_200)
        XCTAssertLessThanOrEqual(big.guids.count, 2000)
        // Exactly the rows at or after the moved since, less one second of margin.
        let expected = rows.filter { $0.date >= TimeInterval(big.since) - reference - 1 }.map(\.guid)
        XCTAssertEqual(Set(big.guids), Set(expected))
        XCTAssertEqual(big.guids.count, expected.count)
        XCTAssertEqual(present.first { $0.threadGUID == "any;-;small" }?.since, 1_793_491_200)
    }

    func test_aThreadWhoseNewestRowsShareOneSecondIsLeftOut() async throws {
        let rows = (0..<2001).map { row("g\($0)", 500.5) }
        let outcome = await reconciler(fixed(["any;-;tied": rows, "any;-;small": [row("s", 5)]])).runIfDue(after: idle)
        XCTAssertEqual(outcome?.leftOut, 1)
        XCTAssertEqual(uplink.batches.first?.present?.map(\.threadGUID), ["any;-;small"])
    }

    func test_duplicateRowsAndOverlongStringsAreHandled() async throws {
        let long = String(repeating: "x", count: 201)
        let outcome = await reconciler(fixed([
            "any;-;dup": [row("g1", 10), row("g1", 10), row("g2", 11)],
            "any;-;longguid": [row(long, 10)],
            long: [row("g3", 10)],
        ])).runIfDue(after: idle)
        XCTAssertEqual(outcome?.leftOut, 2)
        XCTAssertEqual(uplink.batches.first?.present,
                       [PresentEntry(threadGUID: "any;-;dup", since: 1_793_491_200, guids: ["g1", "g2"])])
    }

    func test_nothingToSendStillCompletesWithoutARequest() async throws {
        let outcome = await reconciler(fixed([:])).runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .done)
        XCTAssertTrue(uplink.batches.isEmpty)
    }

    func test_requestsSplitAt200Entries() async throws {
        var rows: [String: [PresentRow]] = [:]
        for index in 0..<450 { rows["any;-;t\(index)"] = [row("g\(index)", 10)] }
        let outcome = await reconciler(fixed(rows)).runIfDue(after: idle)
        XCTAssertEqual(uplink.batches.map { $0.present?.count ?? 0 }, [200, 200, 50])
        let threads = uplink.batches.flatMap { $0.present?.map(\.threadGUID) ?? [] }
        XCTAssertEqual(Set(threads).count, 450)
        XCTAssertEqual(threads.count, 450)
        XCTAssertEqual(outcome?.requests, 3)
        XCTAssertEqual(Set(uplink.batches.map(\.batchID)).count, 3)
    }

    func test_requestsSplitUnderTheByteLimit() async throws {
        var rows: [String: [PresentRow]] = [:]
        for thread in 0..<30 {
            rows["any;-;t\(thread)"] = (0..<2000).map { row(UUID().uuidString, TimeInterval($0)) }
        }
        _ = await reconciler(fixed(rows)).runIfDue(after: idle)
        XCTAssertGreaterThan(uplink.batches.count, 1)
        for batch in uplink.batches {
            XCTAssertLessThanOrEqual(try CompanionJSON.encoder.encode(batch).count, CompanionService.maxBodyBytes)
        }
        XCTAssertEqual(uplink.batches.flatMap { $0.present ?? [] }.count, 30)
    }

    func test_aRejectionStopsTheRestOfTodaysRun() async throws {
        var rows: [String: [PresentRow]] = [:]
        for index in 0..<450 { rows["any;-;t\(index)"] = [row("g\(index)", 10)] }
        uplink.script([.failure(.rejected(422))])
        let outcome = await reconciler(fixed(rows)).runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .failed)
        XCTAssertEqual(outcome?.code, 422)
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertNil(config.presentAuthBlockedFor, "only a 401 blocks the next day")
    }

    func test_offlineStopsTheRunWithNoSameDayRetry() async throws {
        let r = reconciler(fixed(["any;-;t1": [row("g1", 10)]]))
        uplink.script([.failure(.retryable(nil))])
        let outcome = await r.runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .failed)
        XCTAssertNil(outcome?.code)
        clock.advance(3600)
        let again = await r.runIfDue(after: idle)
        XCTAssertNil(again)
    }

    func test_presentSkippedIsCountedAndTheRunCompletes() async throws {
        uplink.script([.success(UplinkAck(acceptedCursor: 42, presentSkipped: true))])
        let outcome = await reconciler(fixed(["any;-;t1": [row("g1", 10)]])).runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .skipped)
        XCTAssertEqual(outcome?.skipped, 1)
    }

    func test_anUnreadableSnapshotAbandonsTheRun() async throws {
        let outcome = await reconciler({ _ in nil }).runIfDue(after: idle)
        XCTAssertEqual(outcome?.result, .abandoned)
        XCTAssertTrue(uplink.batches.isEmpty)
        XCTAssertNotNil(config.lastPresentAttemptAt)
    }

    // End to end over a synthetic chat.db: the service's own reader, a deleted row, and no text on the wire.
    func test_aDeletedMessageDropsFromTheNextDaysList() async throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        let kept = try f.addMessage(chats: [chat], guid: "keep-1", text: "secret words", date: start - 3600, handle: alice)
        let gone = try f.addMessage(chats: [chat], guid: "gone-1", text: "secret words", date: start - 1800, handle: alice)
        try CompanionConfig.update(at: configURL) { $0.cursor = 0 }
        let clock = self.clock!, uplink = self.uplink!
        let service = CompanionService(databasePath: f.url.path, configURL: configURL, tokens: tokens, names: FakeNames([:]),
                                       makeUplink: { _, _ in uplink }, now: { clock.now })
        let r = reconciler({ await service.presentSnapshot(sinceUnix: $0) })
        var status = await service.tick()
        status = await service.tick()
        XCTAssertEqual(status.cursor, gone)
        let first = await r.runIfDue(after: status)
        XCTAssertEqual(first?.result, .done)
        XCTAssertEqual(uplink.batches.last?.present?.first?.guids, ["gone-1", "keep-1"])
        XCTAssertEqual(uplink.batches.last?.cursor, gone)

        try f.deleteMessage(gone)
        clock.advance(day + 1)
        status = await service.tick()
        _ = await r.runIfDue(after: status)
        let last = try XCTUnwrap(uplink.batches.last)
        XCTAssertEqual(last.present?.first?.guids, ["keep-1"])
        XCTAssertEqual(last.cursor, gone, "the saved cursor, even though its row is gone")
        let body = String(decoding: try CompanionJSON.encoder.encode(last), as: UTF8.self)
        XCTAssertFalse(body.contains("secret"))
        _ = kept
    }

    func test_snapshotIsNilWhenTheDatabaseFileWasReplaced() async throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], guid: "g1", text: "x", date: start - 60, handle: alice)
        let clock = self.clock!, uplink = self.uplink!
        let service = CompanionService(databasePath: f.url.path, configURL: configURL, tokens: tokens, names: FakeNames([:]),
                                       makeUplink: { _, _ in uplink }, now: { clock.now })
        _ = await service.tick()
        let before = await service.presentSnapshot(sinceUnix: 1_793_491_200)
        XCTAssertNotNil(before)
        let other = try CompanionFixture()
        _ = try FileManager.default.replaceItemAt(f.url, withItemAt: other.url)
        let after = await service.presentSnapshot(sinceUnix: 1_793_491_200)
        XCTAssertNil(after)
    }
}

actor AskedSince {
    var value: Int64?
    func record(_ since: Int64) { value = since }
}
