import CryptoKit
import Foundation
import IMsgCore

// One read-and-uplink cycle per tick(); the caller owns the timer. New rows come from IMsgCore paging; threads,
// system rows and the from-me set from our own `ChatQueries` (agent design §5.2).

public protocol CompanionNameResolving: Sendable {
    /// Contact names by handle; handles with no known name are left out.
    func names(for handles: [String]) async -> [String: String]
}

public protocol CompanionUplinking: Sendable {
    func post(_ batch: UplinkBatch) async throws(UplinkError) -> UplinkAck
}

extension UplinkClient: CompanionUplinking {}

public struct CompanionStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case paused, notConfigured, noDatabaseAccess, idle, uplinking
        case offline(retryIn: TimeInterval)
        /// Carries only an HTTP status or an error kind, never message text or handles.
        case stopped(String)
    }
    public var state: State
    public var lastUplinkAt: Date?
    public var lastBatchCount: Int
    public var cursor: Int64?
    public var pendingEstimate: Int64?
    public init(state: State, lastUplinkAt: Date? = nil, lastBatchCount: Int = 0, cursor: Int64? = nil,
                pendingEstimate: Int64? = nil) {
        self.state = state; self.lastUplinkAt = lastUplinkAt; self.lastBatchCount = lastBatchCount
        self.cursor = cursor; self.pendingEstimate = pendingEstimate
    }
}

public actor CompanionService {
    public static let batchLimit = 200
    public static let firstRunWindow: TimeInterval = 3 * 86_400
    /// The contract's limit is 1 MB; stay under it with room for headers and rounding.
    static let maxBodyBytes = 900_000
    /// A chat-less row this new may just not be linked to its chat yet.
    static let orphanHold: TimeInterval = 10
    static let resetStatus = "database_replaced"

    private let databasePath: String
    private let configURL: URL
    private let tokens: any CompanionTokenStoring
    private let names: any CompanionNameResolving
    private let makeUplink: @Sendable (URL, String) -> any CompanionUplinking
    private let makePaging: @Sendable (String) throws -> any MessagePaging
    /// A pause from elsewhere (HomeChat's `control.paused`, the fork-running guard); the config's flag is checked too.
    private let isPaused: @Sendable () async -> Bool
    private let now: @Sendable () -> Date

    // One connection for the service's life: PRAGMA data_version is only comparable on the same connection.
    private var reader: ChatQueries?
    private var paging: (any MessagePaging)?
    /// Chats with any row from Alex, loaded when the database is opened and grown as rows are read.
    private var fromMeChats: Set<Int64>?
    private var lastDataVersion: Int64?
    private var caughtUp = false
    private var backoff: TimeInterval = 0
    private var retryAt: Date?
    /// Set by a 401 or rejection; cleared when the URL or token changes.
    private var stop: (key: String, reason: String)?
    /// While nothing has been accepted yet, the first-run start lives here, not in the config.
    private var firstRunCursor: Int64?
    private var inFlight = false
    public private(set) var status = CompanionStatus(state: .idle)

    public init(databasePath: String, configURL: URL, tokens: any CompanionTokenStoring,
                names: any CompanionNameResolving, makeUplink: @escaping @Sendable (URL, String) -> any CompanionUplinking,
                makePaging: @escaping @Sendable (String) throws -> any MessagePaging = { try IMsgCorePaging(path: $0) },
                isPaused: @escaping @Sendable () async -> Bool = { false },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.databasePath = databasePath; self.configURL = configURL; self.tokens = tokens; self.names = names
        self.makeUplink = makeUplink; self.makePaging = makePaging; self.isPaused = isPaused; self.now = now
    }

    public func setPaused(_ paused: Bool) async -> CompanionStatus {
        var config = CompanionConfig.load(from: configURL)
        config.paused = paused
        try? config.save(to: configURL)
        if paused { closeReader() }
        return update(paused ? .paused : .idle, config: config)
    }

    public func tick() async -> CompanionStatus {
        // The actor is reentrant across the awaits below, so a timer tick can arrive mid-post. Let it go.
        if inFlight { return status }
        inFlight = true
        defer { inFlight = false }
        var config = CompanionConfig.load(from: configURL)
        if config.paused { closeReader(); return update(.paused, config: config) }
        if await isPaused() { return update(.paused, config: config) }
        guard let url = config.uplinkURL, let token = tokens.read() else { return update(.notConfigured, config: config) }
        // A digest, so the stop record never holds the token itself.
        let key = SHA256.hash(data: Data("\(url.absoluteString)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let stop {
            if stop.key == key { return update(.stopped(stop.reason), config: config) }
            self.stop = nil
            lastDataVersion = nil
        }
        if let retryAt, retryAt > now() {
            return update(.offline(retryIn: retryAt.timeIntervalSince(now())), config: config)
        }

        dropReaderIfFileReplaced()
        let reader: ChatQueries
        do throws(ChatQueryError) {
            reader = try openReader()
            // A cursor past the highest ROWID ever handed out means the database was reset (deleting the newest
            // messages doesn't count: see highWaterRowID). Not sticky: it is re-checked each tick, so clearing the
            // cursor lets the next tick start again. The cursor itself is never lowered here.
            if let cursor = config.cursor, try reader.highWaterRowID() < cursor {
                caughtUp = false
                return update(.stopped(Self.resetStatus), config: config)
            }
            let version = try reader.dataVersion()
            if version == lastDataVersion, caughtUp, retryAt == nil { return update(.idle, config: config) }
            lastDataVersion = version
        } catch {
            return databaseFailure(error, config: config)
        }

        let firstRun = config.cursor == nil
        let start: Int64
        let read: (messages: [CompanionMessage], lastScannedRowID: Int64)
        let threads: [CompanionThread]
        do throws(ChatQueryError) {
            if let cursor = config.cursor {
                start = cursor
            } else if let cursor = firstRunCursor {
                start = cursor
            } else {
                if let recent = try reader.firstRowID(since: now() - Self.firstRunWindow) {
                    start = recent - 1
                } else {
                    start = try reader.maxRowID()
                }
                firstRunCursor = start
            }
            let result = try readPage(reader, after: start)
            read = (result.messages, result.lastScannedRowID)
            threads = result.threads
        } catch {
            return databaseFailure(error, config: config)
        }

        if read.messages.isEmpty {
            if read.lastScannedRowID > start { advance(to: read.lastScannedRowID, firstRun: firstRun, config: &config) }
            caughtUp = isCaughtUp(reader, cursor: read.lastScannedRowID)
            return update(.idle, config: config)
        }

        let handles = Array(Set(threads.flatMap { $0.participants.map(\.handle) })).sorted()
        let known = handles.isEmpty ? [:] : await names.names(for: handles)
        let named = threads.map { thread -> CompanionThread in
            var thread = thread
            thread.participants = thread.participants.map { CompanionParticipant(handle: $0.handle, name: known[$0.handle]) }
            return thread
        }
        let batch = Self.fitted(UplinkBatch(deviceID: config.deviceID, batchID: UUID(), cursor: read.lastScannedRowID,
                                            firstRun: firstRun, threads: named, messages: read.messages))
        status.state = .uplinking

        do throws(UplinkError) {
            let ack = try await makeUplink(url, token).post(batch)
            // Never past this batch, never back behind where it started.
            let accepted = min(max(ack.acceptedCursor, start), batch.cursor)
            advance(to: accepted, firstRun: false, config: &config)
            backoff = 0
            retryAt = nil
            caughtUp = isCaughtUp(reader, cursor: accepted)
            status.lastUplinkAt = now()
            status.lastBatchCount = batch.messages.count
            if config.paused { closeReader(); return update(.paused, config: config) }
            return update(.idle, config: config)
        } catch {
            switch error {
            case .unauthorized:
                return halt("token rejected", key: key, config: config)
            case .rejected(let code):
                return halt("rejected (HTTP \(code))", key: key, config: config)
            case .notHTTPS:
                return halt("uplink URL must be https", key: key, config: config)
            case .retryable, .badResponse:
                let tunables = config.tunables
                backoff = backoff == 0 ? tunables.backoffInitialSeconds : min(backoff * 2, tunables.backoffMaxSeconds)
                retryAt = now() + backoff
                return update(.offline(retryIn: backoff), config: config)
            }
        }
    }

    // MARK: - Reading

    /// One page from IMsgCore, mapped and scrubbed. The scan position is IMsgCore's `nextRowID` (the last physical row
    /// it looked at), except that a chat-less row newer than `orphanHold` stops the page just below it, since Messages
    /// may not have linked it yet. Older chat-less rows and system rows are passed over.
    private func readPage(_ reader: ChatQueries, after start: Int64)
        throws(ChatQueryError) -> (messages: [CompanionMessage], lastScannedRowID: Int64, threads: [CompanionThread]) {
        let page: MessagesAfterPage
        do {
            let paging = try self.paging ?? makePaging(databasePath)
            self.paging = paging
            page = try paging.page(after: start, limit: Self.batchLimit)
        } catch let error as ChatQueryError {
            throw error
        } catch {
            throw .query("IMsgCore page failed")
        }
        let rows = page.messages.sorted { $0.rowID < $1.rowID }
        let threadsByChat = try reader.threads(chatRowIDs: Set(rows.map(\.chatID).filter { $0 > 0 }))
        let facts = try reader.rowFacts(rowIDs: rows.map(\.rowID))
        var fromMe: Set<Int64>
        if let known = fromMeChats { fromMe = known } else { fromMe = try reader.fromMeChatRowIDs() }
        var messages: [CompanionMessage] = []
        var last = max(page.nextRowID, start)
        let holdAfter = now() - Self.orphanHold
        for row in rows {
            if row.isFromMe, row.chatID > 0 { fromMe.insert(row.chatID) }
            switch MessageMapper.map(row, facts: facts[row.rowID], thread: threadsByChat[row.chatID]) {
            case .system:
                continue
            case .orphan:
                guard row.date < holdAfter else {
                    last = max(row.rowID - 1, start)
                    fromMeChats = fromMe
                    return (messages, last, used(messages, threadsByChat))
                }
            case .message(let message):
                messages.append(CompanionScrubber.apply(to: message, threadHasFromMe: fromMe.contains(row.chatID)))
            }
        }
        fromMeChats = fromMe
        return (messages, last, used(messages, threadsByChat))
    }

    private func used(_ messages: [CompanionMessage], _ threads: [Int64: CompanionThread]) -> [CompanionThread] {
        let guids = Set(messages.map(\.threadGUID))
        var seen = Set<String>()
        return threads.sorted { $0.key < $1.key }.map(\.value)
            .filter { guids.contains($0.guid) && seen.insert($0.guid).inserted }
    }

    // MARK: - Helpers

    /// Halves the batch until its JSON fits under `maxBodyBytes`, ending the cursor at the last kept message and
    /// keeping only the threads those messages use. One message (text ≤ 4000 code points) always fits.
    static func fitted(_ batch: UplinkBatch) -> UplinkBatch {
        var batch = batch
        while batch.messages.count > 1, let size = try? CompanionJSON.encoder.encode(batch).count, size > maxBodyBytes {
            batch.messages = Array(batch.messages.prefix(batch.messages.count / 2))
            batch.cursor = batch.messages[batch.messages.count - 1].rowid
            let used = Set(batch.messages.map(\.threadGUID))
            batch.threads = batch.threads.filter { used.contains($0.guid) }
        }
        return batch
    }

    private func openReader() throws(ChatQueryError) -> ChatQueries {
        if let reader { return reader }
        let opened = try ChatQueries(path: databasePath)
        reader = opened
        paging = nil
        fromMeChats = nil
        lastDataVersion = nil
        return opened
    }

    /// Messages may replace chat.db (a rename over the path, a rebuild); the open connection would keep reading
    /// the old file. A missing file also counts as a change, and the reopen then reports it as unreadable.
    private func dropReaderIfFileReplaced() {
        guard let reader else { return }
        if CompanionFileIdentity.of(path: databasePath) != reader.fileIdentity { closeReader() }
    }

    private func closeReader() {
        reader = nil
        paging = nil
        fromMeChats = nil
        lastDataVersion = nil
    }

    private func databaseFailure(_ error: ChatQueryError, config: CompanionConfig) -> CompanionStatus {
        closeReader()
        switch error {
        case .unreadable: return update(.noDatabaseAccess, config: config)
        case .unsupportedSchema: return update(.stopped("unsupported Messages database"), config: config)
        case .query: return update(.stopped("Messages database busy"), config: config)
        }
    }

    private func halt(_ reason: String, key: String, config: CompanionConfig) -> CompanionStatus {
        stop = (key, reason)
        backoff = 0
        retryAt = nil
        return update(.stopped(reason), config: config)
    }

    /// While nothing has been accepted, an orphan-only stretch moves the in-memory start only, so first_run holds.
    /// Otherwise only the cursor is written, onto the config as it is on disk now: a pause or URL change made
    /// while this tick was awaiting is kept, and `config` is refreshed to match.
    private func advance(to cursor: Int64, firstRun: Bool, config: inout CompanionConfig) {
        if firstRun {
            firstRunCursor = cursor
            return
        }
        config = CompanionConfig.load(from: configURL)
        config.cursor = cursor
        firstRunCursor = nil
        try? config.save(to: configURL)
    }

    private func isCaughtUp(_ reader: ChatQueries, cursor: Int64) -> Bool {
        guard let max = try? reader.maxRowID() else { return false }
        return max <= cursor
    }

    private func update(_ state: CompanionStatus.State, config: CompanionConfig) -> CompanionStatus {
        status.state = state
        status.cursor = config.cursor
        if let reader, let max = try? reader.maxRowID(), let cursor = config.cursor ?? firstRunCursor {
            status.pendingEstimate = Swift.max(0, max - cursor)
        } else {
            status.pendingEstimate = nil
        }
        return status
    }
}
