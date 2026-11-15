import XCTest
@testable import CompanionCore
import IMsgCore

final class CompanionSendExecutorTests: XCTestCase {
    private let alice = "+15555550100", bob = "bob@example.invalid", carol = "+15555550102"
    private let directGUID = "iMessage;-;+15555550100", groupGUID = "iMessage;+;chat-test"
    private let t0 = Date(timeIntervalSince1970: 1_794_492_000)

    private var folder: URL!
    private var fixture: CompanionFixture!
    private var directChat: Int64 = 0
    private var groupChat: Int64 = 0
    private var clock: TestClock!
    private var uplink: FakeSendUplink!
    private var runner: FakeRunner!

    private var configURL: URL { folder.appendingPathComponent("companion.json") }
    private var ledgerFolder: URL { folder.appendingPathComponent("companion-sends") }
    private var ledger: CompanionSendLedger { CompanionSendLedger(folder: ledgerFolder) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("send-exec-\(UUID().uuidString)")
        fixture = try CompanionFixture()
        directChat = try fixture.addChat(guid: directGUID, style: 45, displayName: nil, handles: [alice])
        groupChat = try fixture.addChat(guid: groupGUID, style: 43, displayName: nil, handles: [alice, bob, carol])
        try fixture.addMessage(chats: [directChat], text: "earlier", handle: alice)
        try fixture.addMessage(chats: [groupChat], text: "earlier in group", handle: bob)
        clock = TestClock(t0)
        uplink = FakeSendUplink()
        runner = FakeRunner()
        controls = ControlLog()
        try writeConfig(sendsEnabled: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeConfig(sendsEnabled: Bool, paused: Bool = false) throws {
        try Self.writeConfig(to: configURL, sendsEnabled: sendsEnabled, paused: paused)
    }

    private static func writeConfig(to url: URL, sendsEnabled: Bool, paused: Bool = false) throws {
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0123abcd", paused: paused,
                            cursor: 1, sendsEnabled: sendsEnabled).save(to: url)
    }

    private var controls: ControlLog!

    private func executor(token: String? = "tok", paused: PauseFlag? = nil) -> CompanionSendExecutor {
        let clock = clock!
        let uplink = uplink!
        let controls = self.controls!
        return CompanionSendExecutor(databasePath: fixture.url.path, configURL: configURL, ledgerFolder: ledgerFolder,
                                     tokens: FakeTokens(token), makeUplink: { _, _ in uplink }, runner: runner,
                                     isPaused: { paused?.value ?? false }, onControl: { controls.append($0) },
                                     now: { clock.now }, sleep: { clock.advance($0) })
    }

    private func send(_ id: String = "snd-1", thread: String? = nil, handles: [String]? = nil, text: String = "See you at 6",
                      expiresIn: TimeInterval = 540) -> ApprovedSend {
        let thread = thread ?? directGUID
        let handles = handles ?? (thread == groupGUID ? [alice, bob, carol] : [alice])
        return ApprovedSend(sendID: id, threadGUID: thread, participantsFingerprint: CompanionFingerprint.of(handles: handles),
                            text: text, textSHA256: CompanionTextHash.of(text), approvedAt: clock.now.addingTimeInterval(-60),
                            expiresAt: clock.now.addingTimeInterval(expiresIn))
    }

    /// Simulates Messages: the script "sends" by inserting an outgoing row into the fixture.
    private func messagesWrites(text: String = "See you at 6", chat: Int64? = nil, guid: String = "sent-row",
                                isSent: Bool = true, error: Int = 0, service: String = "iMessage",
                                output: ScriptRunOutput = .output("SUBMITTED")) {
        nonisolated(unsafe) let fixture = fixture!
        let chat = chat ?? directChat
        runner.behaviour = { _, _ in
            _ = try? fixture.addMessage(chats: [chat], guid: guid, text: text, fromMe: true, error: error, isSent: isSent,
                                        service: service)
            return output
        }
    }

    // MARK: Happy paths

    func test_happyPath1to1() async throws {
        messagesWrites()
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.arguments, [directGUID, "1", alice, "See you at 6"])
        XCTAssertEqual(runner.calls.first?.source, CompanionSendScript.source(dispatch: true))
        XCTAssertEqual(uplink.results, [SendResult(sendID: "snd-1", outcome: .sent, anchorGUID: "sent-row",
                                                   textSHA256: CompanionTextHash.of("See you at 6"), detail: .confirmed,
                                                   sentService: "iMessage")])
        let record = try XCTUnwrap(ledger.record("snd-1"))
        XCTAssertEqual(record.state, .finished)
        XCTAssertNotNil(record.dispatchedAt)
        XCTAssertNotNil(record.reportedAt)
        XCTAssertEqual(record.textLength, 12)
    }

    func test_happyPathGroup() async {
        messagesWrites(chat: groupChat, guid: "group-row")
        uplink.pages = [[send(thread: groupGUID)]]
        _ = await executor().cycle()
        XCTAssertEqual(runner.calls.first?.arguments, [groupGUID, "3", alice, bob, carol, "See you at 6"])
        XCTAssertEqual(uplink.results.map(\.outcome), [.sent])
        XCTAssertEqual(uplink.results.first?.anchorGUID, "group-row")
    }

    func test_unconfiguredDoesNotFetch() async throws {
        let status = await executor(token: nil).cycle()
        XCTAssertEqual(status.state, .notConfigured)
        XCTAssertEqual(uplink.fetches, 0)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // Agent design §5.5: the poll always runs, so control arrives; a send fetched while off is ignored, not refused.
    func test_pollRunsWhenSendsOff() async throws {
        try writeConfig(sendsEnabled: false)
        messagesWrites()
        uplink.pages = [[send()], [send()]]
        uplink.control = SendsPage.Control(paused: false)
        let exec = executor()
        let status = await exec.cycle()
        XCTAssertEqual(status.state, .off)
        XCTAssertEqual(uplink.fetches, 1)
        XCTAssertEqual(controls.values, [SendsPage.Control(paused: false)])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(ledger.exists("snd-1"), "no ledger record")
        XCTAssertTrue(uplink.results.isEmpty, "no send result")
        try writeConfig(sendsEnabled: true)
        _ = await exec.cycle()
        XCTAssertEqual(runner.calls.count, 1, "the same send, still unexpired, goes once sends are on")
        XCTAssertEqual(uplink.results.map(\.outcome), [.sent])
    }

    func test_pollRunsWhenPaused() async throws {
        for local in [true, false] {
            try setUpWithError()
            let flag = PauseFlag(!local)
            try writeConfig(sendsEnabled: true, paused: local)
            messagesWrites()
            uplink.pages = [[send()], [send()]]
            let exec = executor(paused: flag)
            let status = await exec.cycle()
            XCTAssertEqual(status.state, .paused)
            XCTAssertEqual(uplink.fetches, 1)
            XCTAssertEqual(controls.values.count, 1)
            XCTAssertTrue(runner.calls.isEmpty)
            XCTAssertFalse(ledger.exists("snd-1"))
            XCTAssertTrue(uplink.results.isEmpty)
            try writeConfig(sendsEnabled: true)
            flag.value = false
            _ = await exec.cycle()
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func test_emptyPageIsWaiting() async {
        uplink.pages = [[]]
        let status = await executor().cycle()
        XCTAssertEqual(status.state, .waiting)
        XCTAssertEqual(uplink.fetches, 1)
        XCTAssertEqual(uplink.lastWait, 25)
    }

    // MARK: Never twice

    func test_redeliveredSendIsNotDispatchedAgain() async {
        messagesWrites()
        uplink.pages = [[send()], [send()]]
        let exec = executor()
        _ = await exec.cycle()
        _ = await exec.cycle()
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(uplink.results.count, 2, "the recorded result is posted again")
        XCTAssertEqual(uplink.results[0], uplink.results[1])
        _ = await executor().cycle()
        XCTAssertEqual(runner.calls.count, 1, "a new executor (app relaunch) doesn't dispatch it either")
    }

    func test_ambiguousNeverRetried() async {
        runner.behaviour = { _, _ in .timedOut }
        uplink.pages = [[send()], [send()]]
        let exec = executor()
        _ = await exec.cycle()
        XCTAssertEqual(uplink.results.map(\.outcome), [.ambiguous])
        XCTAssertEqual(uplink.results.first?.detail, .scriptUncertain)
        _ = await exec.cycle()
        XCTAssertEqual(runner.calls.count, 1)
    }

    func test_notConfirmedWithinTwentySeconds() async {
        messagesWrites(isSent: false)
        uplink.pages = [[send()]]
        let start = clock.now
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first.map { [$0.outcome.rawValue, $0.detail.rawValue] }, ["ambiguous", "not_confirmed"])
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 20)
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(start), 21)
    }

    func test_messagesErrorIsNotSent() async {
        messagesWrites(guid: "failed-row", isSent: false, error: 22)
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .notSent)
        XCTAssertEqual(uplink.results.first?.detail, .messagesError)
        XCTAssertEqual(uplink.results.first?.anchorGUID, "failed-row")
    }

    func test_phoneRowThenMacRowIsAmbiguous() async {
        // Alex's phone sends the same words; its row lands first and the Mac's own row a second later.
        nonisolated(unsafe) let fixture = fixture!
        let chat = directChat
        runner.behaviour = { _, _ in
            _ = try? fixture.addMessage(chats: [chat], guid: "phone-row", text: "See you at 6", fromMe: true, isSent: true)
            return .output("SUBMITTED")
        }
        let clock = clock!
        nonisolated(unsafe) var inserted = false
        let exec = CompanionSendExecutor(
            databasePath: fixture.url.path, configURL: configURL, ledgerFolder: ledgerFolder, tokens: FakeTokens("tok"),
            makeUplink: { [uplink] _, _ in uplink! }, runner: runner, now: { clock.now },
            sleep: { seconds in
                clock.advance(seconds)
                if !inserted {
                    inserted = true
                    _ = try? fixture.addMessage(chats: [chat], guid: "mac-row", text: "See you at 6", fromMe: true,
                                                isSent: true)
                }
            })
        uplink.pages = [[send()]]
        _ = await exec.cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .ambiguous)
        XCTAssertEqual(uplink.results.first?.detail, .multipleMatches)
    }

    func test_confirmedSendSettlesForTwoPolls() async {
        messagesWrites()
        uplink.pages = [[send()]]
        let start = clock.now
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .sent)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 2)
    }

    func test_secondExecutorStopsWhileFirstHoldsLock() async {
        messagesWrites()
        uplink.pages = [[]]
        let first = executor()
        _ = await first.cycle()
        uplink.pages = [[send()]]
        let status = await executor().cycle()
        XCTAssertEqual(status.state, .stopped(CompanionSendExecutor.anotherCopy))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.fetches, 1, "the second copy doesn't fetch")
        _ = first
    }

    // MARK: Refusals before dispatch

    func test_expiryRecheckedBeforeDispatch() async {
        uplink.pages = [[send(expiresIn: 5)]]
        let clock = clock!
        uplink.onFetch = { clock.advance(6) }
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.outcome, .notSent)
        XCTAssertEqual(uplink.results.first?.detail, .expired)
    }

    func test_changedParticipantsRefusedBeforeDispatch() async {
        uplink.pages = [[send(thread: groupGUID, handles: [alice, bob])]]
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.detail, .threadChanged)
        XCTAssertEqual(uplink.results.first?.outcome, .notSent)
    }

    // Agent design §5.5: `chat.service_name` is stale, so the label decides nothing; Messages picks the route.
    func test_smsLabelledChatSends() async throws {
        let sms = try fixture.addChat(guid: "any;-;+15555550109", style: 45, displayName: nil,
                                      handles: ["+15555550109"], service: "SMS")
        messagesWrites(chat: sms, guid: "sms-row", service: "SMS")
        uplink.pages = [[send(thread: "any;-;+15555550109", handles: ["+15555550109"])]]
        _ = await executor().cycle()
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(uplink.results.map(\.outcome), [.sent])
        XCTAssertEqual(uplink.results.first?.sentService, "SMS")
    }

    func test_scriptHasNo9003() async {
        messagesWrites()
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertFalse(runner.calls.first?.source.contains("9003") ?? true)
    }

    // A row in a twin chat (same people, another chat row) is the Mac's own send.
    func test_readBackFindsTwinRow() async throws {
        let twin = try fixture.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice],
                                       service: "SMS")
        messagesWrites(chat: twin, guid: "twin-row", service: "RCS")
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .sent)
        XCTAssertEqual(uplink.results.first?.anchorGUID, "twin-row")
        XCTAssertEqual(uplink.results.first?.sentService, "RCS")
    }

    // The baseline is the global max ROWID: a matching row already in a twin chat (above the direct chat's own
    // max) is never read back as the Mac's send. A per-chat baseline would see two matches.
    func test_baselineIsGlobalMax() async throws {
        let twin = try fixture.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice],
                                       service: "SMS")
        nonisolated(unsafe) let fixture = fixture!
        uplink.onFetch = { _ = try? fixture.addMessage(chats: [twin], text: "See you at 6", fromMe: true, isSent: true) }
        messagesWrites()
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .sent)
        XCTAssertEqual(uplink.results.first?.anchorGUID, "sent-row")
        XCTAssertEqual(ledger.record("snd-1")?.baselineRowID, 3, "the global max before dispatch")
    }

    // Review Focus: one page of 50 would end before the sent row; read-back pages to the end.
    func test_readBackPagesPastBusyRows() async throws {
        nonisolated(unsafe) let fixture = fixture!
        let group = groupChat, direct = directChat
        let bob = self.bob
        runner.behaviour = { _, _ in
            for _ in 0..<60 { _ = try? fixture.addMessage(chats: [group], text: "busy", handle: bob) }
            _ = try? fixture.addMessage(chats: [direct], guid: "sent-row", text: "See you at 6", fromMe: true, isSent: true)
            return .output("SUBMITTED")
        }
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .sent)
        XCTAssertEqual(uplink.results.first?.anchorGUID, "sent-row")
    }

    // Review Focus 3: a Mac that slept past the expiry refuses, and never hands that send to the runner later.
    func test_expiredAfterSleep() async {
        uplink.pages = [[send(expiresIn: -1)], [send(expiresIn: -1)]]
        let exec = executor()
        _ = await exec.cycle()
        _ = await exec.cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.outcome, .notSent)
        XCTAssertEqual(uplink.results.first?.detail, .expired)
        XCTAssertNil(ledger.record("snd-1")?.dispatchedAt)
        XCTAssertEqual(ledger.attempts(since: clock.now - 86_400), 0, "not counted against the cap")
    }

    func test_preflightNeverDispatches() async throws {
        runner.behaviour = { _, _ in .output("READY") }
        let result = await executor().preflight(chatRowID: directChat)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(runner.calls.map(\.source), [CompanionSendScript.source(dispatch: false)])
        XCTAssertEqual(runner.calls.first?.arguments.prefix(3), [directGUID, "1", alice])
        XCTAssertTrue(ledger.inProgress().isEmpty && ledger.finished(since: .distantPast).isEmpty, "the ledger is untouched")
        runner.behaviour = { _, _ in .output("NOT_SUBMITTED:9004") }
        let refused = await executor().preflight(chatRowID: directChat)
        XCTAssertEqual(refused, .refused(code: 9004))
        let missing = await executor().preflight(chatRowID: 999)
        XCTAssertEqual(missing, .refused(code: 0))
    }

    func test_missingThreadRefused() async {
        uplink.pages = [[send(thread: "iMessage;-;nobody", handles: ["nobody"])]]
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.detail, .threadMissing)
    }

    func test_hashMismatchRefused() async {
        let good = send()
        let tampered = ApprovedSend(sendID: good.sendID, threadGUID: good.threadGUID,
                                    participantsFingerprint: good.participantsFingerprint, text: "Send money",
                                    textSHA256: good.textSHA256, approvedAt: good.approvedAt, expiresAt: good.expiresAt)
        uplink.pages = [[tampered]]
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.detail, .hashMismatch)
        XCTAssertEqual(uplink.results.first?.textSHA256, CompanionTextHash.of("Send money"), "the Mac's own hash")
    }

    func test_dailyCapCountsAttempts() async throws {
        for index in 0..<30 {
            var record = SendRecord(sendID: "old-\(index)", threadGUID: directGUID, textLength: 1, textSHA256: "h",
                                    baselineRowID: 1, createdAt: clock.now.addingTimeInterval(-3600))
            try ledger.begin(record)
            record.state = .finished; record.outcome = index.isMultiple(of: 2) ? .ambiguous : .sent
            record.detail = .confirmed; record.dispatchedAt = clock.now.addingTimeInterval(-3600)
            record.finishedAt = record.dispatchedAt; record.reportedAt = record.dispatchedAt
            try ledger.update(record)
        }
        uplink.pages = [[send()]]
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results.first?.detail, .dailyCap)
    }

    func test_pausedBetweenFetchAndDispatch() async {
        uplink.pages = [[send()]]
        let url = configURL
        uplink.onFetch = { try? Self.writeConfig(to: url, sendsEnabled: true, paused: true) }
        let status = await executor().cycle()
        XCTAssertEqual(status.state, .paused)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(uplink.results.isEmpty, "ignored, not refused")
        XCTAssertFalse(ledger.exists("snd-1"))
    }

    func test_sendsTurnedOffBetweenFetchAndDispatch() async {
        uplink.pages = [[send()]]
        let url = configURL
        uplink.onFetch = { try? Self.writeConfig(to: url, sendsEnabled: false) }
        let status = await executor().cycle()
        XCTAssertEqual(status.state, .off)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(uplink.results.isEmpty, "ignored, not refused")
        XCTAssertFalse(ledger.exists("snd-1"))
    }

    // MARK: Recovery after a crash

    private func leaveInProgress(_ id: String = "snd-crash", text: String = "See you at 6") throws -> Int64 {
        let baseline = try ChatQueries(path: fixture.url.path).maxRowID()
        var record = SendRecord(sendID: id, threadGUID: directGUID, textLength: text.count,
                                textSHA256: CompanionTextHash.of(text), baselineRowID: baseline,
                                createdAt: clock.now.addingTimeInterval(-30))
        try ledger.begin(record)
        record.dispatchedAt = clock.now.addingTimeInterval(-30)
        try ledger.update(record)
        return baseline
    }

    func test_recoveryResolvesToSentOnOneExactMatch() async throws {
        _ = try leaveInProgress()
        try fixture.addMessage(chats: [directChat], text: "unrelated", fromMe: true, isSent: true)
        try fixture.addMessage(chats: [directChat], guid: "recovered-row", text: "See you at 6", fromMe: true, isSent: true)
        uplink.pages = [[]]
        _ = await executor().cycle()
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(uplink.results, [SendResult(sendID: "snd-crash", outcome: .sent, anchorGUID: "recovered-row",
                                                   textSHA256: CompanionTextHash.of("See you at 6"),
                                                   detail: .recoveredAfterRestart, sentService: "iMessage")])
    }

    func test_recoveryAmbiguousOnZeroOrTwoMatches() async throws {
        _ = try leaveInProgress("zero")
        uplink.pages = [[]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.map(\.outcome), [.ambiguous])
        XCTAssertEqual(uplink.results.first?.detail, .recoveredAfterRestart)

        _ = try leaveInProgress("two", text: "twice")
        try fixture.addMessage(chats: [directChat], text: "twice", fromMe: true, isSent: true)
        try fixture.addMessage(chats: [directChat], text: "twice", fromMe: true, isSent: true)
        uplink.pages = [[]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.last?.sendID, "two")
        XCTAssertEqual(uplink.results.last?.outcome, .ambiguous)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func test_recoveryNeverReportsNotSent() async throws {
        _ = try leaveInProgress()
        try fixture.addMessage(chats: [directChat], text: "See you at 6", fromMe: true, error: 22)
        uplink.pages = [[]]
        _ = await executor().cycle()
        XCTAssertEqual(uplink.results.first?.outcome, .ambiguous)
    }

    // MARK: Reporting

    func test_resultConflictStops() async {
        messagesWrites()
        uplink.pages = [[send()], [send("snd-2")]]
        uplink.resultErrors = [.conflict]
        let exec = executor()
        let status = await exec.cycle()
        guard case .stopped = status.state else { return XCTFail("\(status.state)") }
        _ = await exec.cycle()
        XCTAssertEqual(uplink.fetches, 1, "no further fetches while stopped")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func test_resultRetryBacksOff() async {
        messagesWrites()
        uplink.pages = [[send()]]
        uplink.resultErrors = [.retryable(503)]
        let exec = executor()
        let status = await exec.cycle()
        XCTAssertEqual(status.state, .offline(retryIn: 5))
        XCTAssertNil(ledger.record("snd-1")?.reportedAt)
        clock.advance(6)
        uplink.pages = [[]]
        _ = await exec.cycle()
        XCTAssertNotNil(ledger.record("snd-1")?.reportedAt)
        XCTAssertEqual(uplink.results.count, 2)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func test_unknownSendMarkedReported() async {
        messagesWrites()
        uplink.pages = [[send()]]
        uplink.resultErrors = [.unknownSend]
        _ = await executor().cycle()
        XCTAssertNotNil(ledger.record("snd-1")?.reportedAt)
    }

    func test_fetchUnauthorizedStopsUntilTokenChanges() async {
        uplink.fetchErrors = [.unauthorized]
        let status = await executor().cycle()
        guard case .stopped = status.state else { return XCTFail("\(status.state)") }
    }

    func test_statusCountsRecentAmbiguous() async {
        runner.behaviour = { _, _ in .timedOut }
        uplink.pages = [[send("a"), send("b")]]
        let status = await executor().cycle()
        XCTAssertEqual(status.ambiguousCount, 2)
        XCTAssertEqual(status.last?.outcome, .ambiguous)
    }
}

final class FakeRunner: CompanionScriptRunning, @unchecked Sendable {
    struct Call: Equatable { let source: String; let arguments: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    nonisolated(unsafe) var behaviour: (@Sendable (String, [String]) -> ScriptRunOutput) = { _, _ in .output("SUBMITTED") }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    func run(source: String, arguments: [String], timeout: TimeInterval) async -> ScriptRunOutput {
        lock.withLock { recorded.append(Call(source: source, arguments: arguments)) }
        return behaviour(source, arguments)
    }
}

final class FakeSendUplink: CompanionSendUplinking, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) var pages: [[ApprovedSend]] = []
    nonisolated(unsafe) var control: SendsPage.Control?
    nonisolated(unsafe) var fetchErrors: [SendsError] = []
    nonisolated(unsafe) var resultErrors: [SendsError] = []
    nonisolated(unsafe) var onFetch: (@Sendable () -> Void)?
    nonisolated(unsafe) private(set) var results: [SendResult] = []
    nonisolated(unsafe) private(set) var fetches = 0
    nonisolated(unsafe) private(set) var lastWait: Int?

    func fetchSends(wait: Int) async throws(SendsError) -> SendsPage {
        let next: Result<SendsPage, SendsError> = lock.withLock {
            fetches += 1; lastWait = wait
            if !fetchErrors.isEmpty { return .failure(fetchErrors.removeFirst()) }
            return .success(SendsPage(sends: pages.isEmpty ? [] : pages.removeFirst(), control: control))
        }
        if let onFetch { self.onFetch = nil; onFetch() }
        return try next.get()
    }

    func postResult(_ result: SendResult) async throws(SendsError) {
        let error: SendsError? = lock.withLock {
            results.append(result)
            return resultErrors.isEmpty ? nil : resultErrors.removeFirst()
        }
        if let error { throw error }
    }
}

final class ControlLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SendsPage.Control?] = []
    var values: [SendsPage.Control?] { lock.withLock { recorded } }
    func append(_ control: SendsPage.Control?) { lock.withLock { recorded.append(control) } }
}

final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
