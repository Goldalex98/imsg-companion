import CryptoKit
import Foundation
import IMsgCore

// Fetches sends Alex approved on HomeChat, checks them again, sends each at most once and reports the outcome
// (agent design §5.5). The central rule: a send_id with any ledger record is never dispatched again. The poll runs
// even while sends are off or paused, so HomeChat's control reaches the agent; a send fetched then is ignored.

public enum PreflightResult: Equatable, Sendable { case ready, refused(code: Int) }

public struct CompanionSendStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case off, paused, notConfigured, waiting, sending, offline(retryIn: TimeInterval), stopped(String)
    }
    public struct LastSend: Sendable, Equatable {
        public let outcome: SendOutcome
        public let at: Date
    }
    public var state: State
    public var last: LastSend?
    /// Ambiguous results in the last 7 days: "may or may not have sent: check Messages".
    public var ambiguousCount: Int

    public init(state: State, last: LastSend? = nil, ambiguousCount: Int = 0) {
        self.state = state; self.last = last; self.ambiguousCount = ambiguousCount
    }
}

public actor CompanionSendExecutor {
    public static let fetchWait = 25
    static let controlRetry: TimeInterval = 60
    public static let scriptTimeout: TimeInterval = 35
    /// Read-back after the script returns: one poll now, then one a second for 20 s (Alex, 2026-11-11).
    public static let readbackPolls = 20
    /// Extra polls a confirmed match must survive before it counts as sent (review finding, 2026-11-11).
    public static let settlePolls = 2
    public static let retention: TimeInterval = 90 * 86_400
    static let ambiguousWindow: TimeInterval = 7 * 86_400
    /// Read-back page size; pages are read until IMsgCore reports no more.
    static let readbackPage = 50

    private let databasePath: String
    private let configURL: URL
    private let ledger: CompanionSendLedger
    private let tokens: any CompanionTokenStoring
    private let makeUplink: @Sendable (URL, String) -> any CompanionSendUplinking
    private let runner: any CompanionScriptRunning
    private let makePaging: @Sendable (String) throws -> any MessagePaging
    /// A pause from elsewhere (HomeChat's `control.paused`, the fork-running guard); the config's flag is checked too.
    private let isPaused: @Sendable () async -> Bool
    /// Each poll's `control`, nil when HomeChat sent none.
    private let onControl: @Sendable (SendsPage.Control?) -> Void
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var backoff: TimeInterval = 0
    private var retryAt: Date?
    /// Set by a 401, a 409 on a result or another rejection; cleared when the URL or token changes.
    private var stop: (key: String, reason: String, tokenRejected: Bool)?
    private var controlRetryAt: Date?
    private var inFlight = false
    private var current = CompanionSendStatus(state: .off)

    public init(databasePath: String, configURL: URL, ledgerFolder: URL, tokens: any CompanionTokenStoring,
                makeUplink: @escaping @Sendable (URL, String) -> any CompanionSendUplinking,
                runner: any CompanionScriptRunning,
                makePaging: @escaping @Sendable (String) throws -> any MessagePaging = {
                    try IMsgCorePaging(path: $0, includeReactions: false)
                },
                isPaused: @escaping @Sendable () async -> Bool = { false },
                onControl: @escaping @Sendable (SendsPage.Control?) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.databasePath = databasePath; self.configURL = configURL
        self.ledger = CompanionSendLedger(folder: ledgerFolder); self.tokens = tokens; self.makeUplink = makeUplink
        self.runner = runner; self.makePaging = makePaging; self.isPaused = isPaused; self.onControl = onControl
        self.now = now; self.sleep = sleep
    }

    /// One pass: recover, report, fetch, send. The caller loops. While sends are off or paused, only the fetch runs.
    public func cycle() async -> CompanionSendStatus {
        if inFlight { return current }
        inFlight = true
        defer { inFlight = false }
        let config = CompanionConfig.load(from: configURL)
        guard let url = config.uplinkURL, let token = tokens.read() else { return status(.notConfigured) }
        guard ledger.lockExclusively() else { return status(.stopped(Self.anotherCopy)) }
        let key = SHA256.hash(data: Data("\(url.absoluteString)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let stop {
            if stop.key == key {
                if !stop.tokenRejected { await pollControl(makeUplink(url, token), key: key) }
                return status(.stopped(stop.reason))
            }
            self.stop = nil
        }
        if let retryAt, retryAt > now() { return status(.offline(retryIn: retryAt.timeIntervalSince(now()))) }
        let uplink = makeUplink(url, token)

        if await inactive() == nil {
            if let blocked = recover() {
                await pollControl(uplink, key: key)
                return status(.stopped(blocked))
            }
            if let halted = await reportUnreported(uplink, key: key) { return status(halted) }
        }

        let page: SendsPage
        do throws(SendsError) {
            page = try await uplink.fetchSends(wait: Self.fetchWait)
        } catch {
            return status(handle(error, key: key))
        }
        clearBackoff()
        onControl(page.control)
        for send in page.sends {
            // Re-checked before each send, so a switch-off or pause mid-page stops the rest. Nothing is recorded:
            // the send waits for `sends on` or expires on HomeChat's side.
            if let state = await inactive() { return status(state) }
            if let record = ledger.record(send.sendID), record.state == .finished {
                // HomeChat handed it out again: post what happened, never dispatch it again.
                if let halted = await report(record, uplink, key: key) { return status(halted) }
                continue
            }
            if ledger.exists(send.sendID) { continue }
            guard let record = await process(send) else { return status(.stopped(Self.unreadable)) }
            if let halted = await report(record, uplink, key: key) { return status(halted) }
        }
        if let state = await inactive() { return status(state) }
        ledger.prune(finishedBefore: now() - Self.retention)
        return status(.waiting)
    }

    /// `.off` or `.paused` when nothing may be dispatched or reported; nil when sending is allowed.
    private func inactive() async -> CompanionSendStatus.State? {
        let config = CompanionConfig.load(from: configURL)
        if !config.sendsEnabled { return .off }
        if config.paused { return .paused }
        if await isPaused() { return .paused }
        return nil
    }

    /// Runs the send script's checks against one chat without sending (`source(dispatch: false)`). The ledger is
    /// never touched.
    public func preflight(chatRowID: Int64) async -> PreflightResult {
        guard let thread = try? ChatQueries(path: databasePath).threads(chatRowIDs: [chatRowID])[chatRowID],
              let arguments = try? CompanionSendScript.arguments(threadGUID: thread.guid,
                                                                handles: thread.participants.map(\.handle),
                                                                text: "preflight")
        else { return .refused(code: 0) }
        let output = await runner.run(source: CompanionSendScript.source(dispatch: false), arguments: arguments,
                                      timeout: Self.scriptTimeout)
        switch CompanionSendScript.result(of: output) {
        case .ready: return .ready
        case .notSubmitted(let code): return .refused(code: code)
        default: return .refused(code: 0)
        }
    }

    /// From-me rows after `baseline` in any of `chats` (the thread and its twins), read page by page until IMsgCore
    /// reports no more, so a busy Mac can't push the sent row past one page. `error` and `is_sent` come from our query.
    static func outgoingRows(paging: any MessagePaging, queries: ChatQueries, after baseline: Int64,
                             in chats: Set<Int64>) throws -> [CompanionOutgoingRow] {
        var mine: [Message] = []
        var after = baseline
        while true {
            let page = try paging.page(after: after, limit: readbackPage)
            mine += page.messages.filter { $0.isFromMe && chats.contains($0.chatID) && $0.rowID > baseline }
            guard page.hasMore else { break }
            guard page.nextRowID > after else { throw ChatQueryError.query("read-back made no progress") }
            after = page.nextRowID
        }
        let facts = try queries.rowFacts(rowIDs: mine.map(\.rowID))
        return mine.sorted { $0.rowID < $1.rowID }.compactMap { message in
            guard let fact = facts[message.rowID] else { return nil }
            return CompanionOutgoingRow(rowID: message.rowID, guid: message.guid,
                                        body: message.text.isEmpty ? nil : message.text, error: fact.error,
                                        isSent: fact.isSent, service: message.service.isEmpty ? nil : message.service)
        }
    }

    static let unreadable = "Can't read the Messages database"
    public static let anotherCopy = "Another copy of the app is sending replies"

    // MARK: - Recovery

    /// Resolves records a crash left in progress, never by sending: `sent` only on exactly one confirmed row with
    /// the approved text after the baseline, else `ambiguous` (Alex, 2026-11-11). Returns a reason when chat.db
    /// can't be read, so nothing new is fetched until it can.
    private func recover() -> String? {
        let pending = ledger.inProgress()
        guard !pending.isEmpty else { return nil }
        guard let queries = try? ChatQueries(path: databasePath), let paging = try? makePaging(databasePath) else {
            return Self.unreadable
        }
        for var record in pending {
            let rows = (try? Self.outgoingRows(paging: paging, queries: queries, after: record.baselineRowID ?? Int64.max,
                                               in: queries.twinChatRowIDs(chatGUID: record.threadGUID)))
            guard let rows else { return Self.unreadable }
            let decision = CompanionSendDecision.decide(script: .uncertain(code: 0), rows: rows, deadlinePassed: true) {
                $0.body.map(CompanionTextHash.of) == record.textSHA256
            }
            if case .final(.sent, _, let anchor) = decision {
                finish(&record, .sent, .recoveredAfterRestart, anchor: anchor, rows: rows)
            } else {
                finish(&record, .ambiguous, .recoveredAfterRestart, anchor: nil)
            }
        }
        return nil
    }

    // MARK: - One send

    /// nil when chat.db couldn't be read before dispatch: nothing is recorded, so HomeChat hands the send out
    /// again until it expires.
    private func process(_ send: ApprovedSend) async -> SendRecord? {
        let hash = CompanionTextHash.of(send.text)
        let started = now()
        var record = SendRecord(sendID: send.sendID, threadGUID: send.threadGUID, textLength: send.text.count,
                                textSHA256: hash, baselineRowID: nil, createdAt: started)
        let config = CompanionConfig.load(from: configURL)
        if let refusal = CompanionSendRules.refusal(for: send, now: started,
                                                    attemptsLast24h: ledger.attempts(since: started - 86_400),
                                                    dailyCap: config.tunables.dailySendCap) {
            return refuse(record, refusal)
        }

        guard let queries = try? ChatQueries(path: databasePath), let paging = try? makePaging(databasePath) else {
            return nil
        }
        let identity: CompanionSendIdentity?
        let twins: Set<Int64>
        let baseline: Int64
        do throws(ChatQueryError) {
            identity = try queries.sendIdentity(chatGUID: send.threadGUID)
            twins = try queries.twinChatRowIDs(chatGUID: send.threadGUID)
            // Global, so a row already in a twin chat can never be read back as this send.
            baseline = try queries.maxRowID()
        } catch {
            return nil
        }
        // No service check: chat.service_name is stale, and Messages picks the route (agent design §5.5).
        guard let identity else { return refuse(record, .threadMissing) }
        guard identity.participantsFingerprint == send.participantsFingerprint else { return refuse(record, .threadChanged) }
        let arguments: [String]
        do throws(CompanionSendScriptError) {
            arguments = try CompanionSendScript.arguments(threadGUID: send.threadGUID, handles: identity.handles,
                                                          text: send.text)
        } catch {
            return refuse(record, .badTarget)
        }
        if now() >= send.expiresAt { return refuse(record, .expired) }

        // Recorded before anything runs; if either write fails, nothing is dispatched.
        record = SendRecord(sendID: send.sendID, threadGUID: send.threadGUID, textLength: send.text.count,
                            textSHA256: hash, baselineRowID: baseline, createdAt: started)
        do { try ledger.begin(record) } catch { return nil }
        record.dispatchedAt = now()
        do { try ledger.update(record) } catch { return nil }

        current.state = .sending
        let script = CompanionSendScript.result(of: await runner.run(source: CompanionSendScript.source(dispatch: true),
                                                                     arguments: arguments, timeout: Self.scriptTimeout))
        // A confirmed match is re-read for `settlePolls` more polls before it counts as sent, so a matching row
        // from Alex's phone that lands just before the Mac's own row reads as two matches (ambiguous).
        var confirmations = 0
        for poll in 0...(Self.readbackPolls + Self.settlePolls) {
            if poll > 0 { await sleep(1) }
            guard let rows = try? Self.outgoingRows(paging: paging, queries: queries, after: baseline, in: twins) else {
                finish(&record, .ambiguous, .databaseUnreadable, anchor: nil)
                return record
            }
            let decision = CompanionSendDecision.decide(script: script, rows: rows, text: send.text,
                                                        deadlinePassed: poll >= Self.readbackPolls)
            switch decision {
            case .final(.sent, let detail, let anchor):
                confirmations += 1
                if confirmations > Self.settlePolls {
                    finish(&record, .sent, detail, anchor: anchor, rows: rows)
                    return record
                }
            case .final(let outcome, let detail, let anchor):
                finish(&record, outcome, detail, anchor: anchor, rows: rows)
                return record
            case .keepWaiting:
                confirmations = 0
            }
        }
        finish(&record, .ambiguous, .notConfirmed, anchor: nil)  // a match that never settled
        return record
    }

    private func refuse(_ record: SendRecord, _ detail: SendDetail) -> SendRecord? {
        var record = record
        do { try ledger.begin(record) } catch { return ledger.record(record.sendID) }
        finish(&record, .notSent, detail, anchor: nil)
        return record
    }

    private func finish(_ record: inout SendRecord, _ outcome: SendOutcome, _ detail: SendDetail, anchor: String?,
                        rows: [CompanionOutgoingRow] = []) {
        record.state = .finished; record.outcome = outcome; record.detail = detail; record.anchorGUID = anchor
        record.sentService = anchor.flatMap { guid in rows.first { $0.guid == guid }?.service }
        record.finishedAt = now()
        try? ledger.update(record)
    }

    // MARK: - Reporting

    private func reportUnreported(_ uplink: any CompanionSendUplinking, key: String) async -> CompanionSendStatus.State? {
        for record in ledger.unreported() {
            if let halted = await report(record, uplink, key: key) { return halted }
        }
        return nil
    }

    /// nil when reported (or nothing to report); otherwise the state that stops this cycle.
    private func report(_ record: SendRecord, _ uplink: any CompanionSendUplinking,
                        key: String) async -> CompanionSendStatus.State? {
        guard record.state == .finished, let outcome = record.outcome, let detail = record.detail else { return nil }
        let result = SendResult(sendID: record.sendID, outcome: outcome, anchorGUID: record.anchorGUID,
                                textSHA256: record.textSHA256, detail: detail, sentService: record.sentService)
        do throws(SendsError) {
            try await uplink.postResult(result)
        } catch .unknownSend {
            markReported(record)
            return nil
        } catch {
            return handle(error, key: key)
        }
        clearBackoff()
        markReported(record)
        return nil
    }

    private func markReported(_ record: SendRecord) {
        guard var stored = ledger.record(record.sendID), stored.reportedAt == nil else { return }
        stored.reportedAt = now()
        try? ledger.update(stored)
    }

    private func handle(_ error: SendsError, key: String) -> CompanionSendStatus.State {
        switch error {
        case .retryable, .badResponse:
            let tunables = CompanionConfig.load(from: configURL).tunables
            backoff = backoff == 0 ? tunables.backoffInitialSeconds : min(backoff * 2, tunables.backoffMaxSeconds)
            retryAt = now() + backoff
            return .offline(retryIn: backoff)
        case .unauthorized: return halt("token rejected", key: key, tokenRejected: true)
        case .conflict: return halt("HomeChat holds a different result for a send", key: key)
        case .notHTTPS: return halt("the HomeChat address must be https", key: key)
        case .unknownSend: return halt("HomeChat doesn't know a send", key: key)
        case .rejected(let code): return halt("HomeChat refused (\(code))", key: key)
        }
    }

    private func halt(_ reason: String, key: String, tokenRejected: Bool = false) -> CompanionSendStatus.State {
        stop = (key, reason, tokenRejected)
        return .stopped(reason)
    }

    /// While sends are stopped, keep fetching for HomeChat's control alone, so a pause from WhatsApp still arrives
    /// (design §5.5). The page's sends are ignored and nothing is recorded. A failed fetch just waits for the next
    /// cycle, after `controlRetry`.
    private func pollControl(_ uplink: any CompanionSendUplinking, key: String) async {
        if let controlRetryAt, controlRetryAt > now() { return }
        do throws(SendsError) {
            onControl(try await uplink.fetchSends(wait: Self.fetchWait).control)
            controlRetryAt = nil
        } catch {
            if case .unauthorized = error { _ = halt("token rejected", key: key, tokenRejected: true) }
            controlRetryAt = now() + Self.controlRetry
        }
    }

    private func clearBackoff() { backoff = 0; retryAt = nil }

    private func status(_ state: CompanionSendStatus.State) -> CompanionSendStatus {
        let recent = ledger.finished(since: now() - Self.ambiguousWindow)
        let last = recent.max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        current = CompanionSendStatus(
            state: state,
            last: last.flatMap { record in record.outcome.map { .init(outcome: $0, at: record.finishedAt ?? now()) } },
            ambiguousCount: recent.filter { $0.outcome == .ambiguous }.count)
        return current
    }
}
