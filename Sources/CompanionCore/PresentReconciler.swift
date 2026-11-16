import CryptoKit
import Foundation

// The deletion reconcile (contract 2026-11-15 additions (2), plan docs/plans/2026-11-15-imsg-present-reconcile.md):
// once a day, tell HomeChat every message GUID still in chat.db for the last 14 days, so it can drop its stored
// copies of messages deleted on the Mac. Nothing on the Mac changes. A GUID left out lets HomeChat delete, so every
// list is complete for its `since` or the thread is not sent at all.

/// What one run did, counts only.
public struct PresentOutcome: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        /// Every request answered 2xx.
        case done
        /// Answered 2xx, but HomeChat dropped `present` on at least one request.
        case skipped
        /// A request failed; the rest of the run was not sent.
        case failed
        /// The database couldn't be read completely; nothing was sent.
        case abandoned
    }
    public var result: Result
    /// Entries sent.
    public var threads: Int
    /// Threads with rows in the window that were not sent (no list that fits, or a string over the limit).
    public var leftOut: Int
    public var requests: Int
    /// Requests HomeChat answered with `present_skipped`.
    public var skipped: Int
    /// The HTTP status of a failure; nil for offline or no failure.
    public var code: Int?
    public var at: Date
    public init(result: Result, threads: Int, leftOut: Int, requests: Int, skipped: Int, code: Int?, at: Date) {
        self.result = result; self.threads = threads; self.leftOut = leftOut; self.requests = requests
        self.skipped = skipped; self.code = code; self.at = at
    }
    enum CodingKeys: String, CodingKey { case result, threads, leftOut = "left_out", requests, skipped, code, at }
}

public struct PresentReconciler: Sendable {
    static let window: TimeInterval = 14 * 86_400
    static let interval: TimeInterval = 86_400
    static let maxEntries = 200
    static let maxGUIDs = 2000
    static let maxString = 200

    private let configURL: URL
    private let tokens: any CompanionTokenStoring
    private let makeUplink: @Sendable (URL, String) -> any CompanionUplinking
    private let serializer: UplinkSerializer
    private let snapshot: @Sendable (Int64) async -> [String: [PresentRow]]?
    private let now: @Sendable () -> Date

    /// `snapshot` reads the rows for a `since` in Unix seconds (`CompanionService.presentSnapshot`), nil if it can't.
    public init(configURL: URL, tokens: any CompanionTokenStoring,
                makeUplink: @escaping @Sendable (URL, String) -> any CompanionUplinking, serializer: UplinkSerializer,
                snapshot: @escaping @Sendable (Int64) async -> [String: [PresentRow]]?,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.configURL = configURL; self.tokens = tokens; self.makeUplink = makeUplink; self.serializer = serializer
        self.snapshot = snapshot; self.now = now
    }

    /// Runs when due, right after a `tick()` that left the reader idle and caught up, reading and posting in this
    /// one call so no message batch can land between the read and the posts. nil when no run happened. `force`
    /// (from `present-now`) skips only the daily gate.
    public func runIfDue(after reader: CompanionStatus, force: Bool = false) async -> PresentOutcome? {
        guard reader.state == .idle, reader.pendingEstimate == 0, reader.cursor != nil else { return nil }
        let config = CompanionConfig.load(from: configURL)
        guard !config.paused, let cursor = config.cursor, let url = config.uplinkURL, let token = tokens.read()
        else { return nil }
        let key = SHA256.hash(data: Data("\(url.absoluteString)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
        if config.presentAuthBlockedFor == key { return nil }
        let at = now()
        if !force, let last = config.lastPresentAttemptAt, at.timeIntervalSince(last) < Self.interval { return nil }
        // Unsaved, the daily gate wouldn't hold and every idle pass would post again: no run at all.
        do {
            try CompanionConfig.update(at: configURL) { $0.lastPresentAttemptAt = at; $0.presentAuthBlockedFor = nil }
        } catch {
            return nil
        }

        let since = Int64(floor(at.timeIntervalSince1970 - Self.window))
        guard let rows = await snapshot(since) else {
            return PresentOutcome(result: .abandoned, threads: 0, leftOut: 0, requests: 0, skipped: 0, code: nil, at: at)
        }
        var entries: [PresentEntry] = []
        var leftOut = 0
        for (thread, threadRows) in rows.sorted(by: { $0.key < $1.key }) {
            if let entry = Self.entry(thread: thread, rows: threadRows, since: since) { entries.append(entry) } else { leftOut += 1 }
        }

        var outcome = PresentOutcome(result: .done, threads: 0, leftOut: leftOut, requests: 0, skipped: 0, code: nil, at: at)
        let uplink = makeUplink(url, token)
        for group in Self.packed(entries, deviceID: config.deviceID, cursor: cursor) {
            let batch = UplinkBatch(deviceID: config.deviceID, batchID: UUID(), cursor: cursor, firstRun: false,
                                    threads: [], messages: [], present: group)
            outcome.requests += 1
            do throws(UplinkError) {
                let ack = try await serializer.post(batch, via: uplink)
                outcome.threads += group.count
                if ack.presentSkipped == true { outcome.skipped += 1; outcome.result = .skipped }
            } catch {
                outcome.result = .failed
                switch error {
                case .unauthorized:
                    outcome.code = 401
                    try? CompanionConfig.update(at: configURL) { $0.presentAuthBlockedFor = key }
                case .rejected(let code): outcome.code = code
                case .retryable(let code): outcome.code = code
                case .notHTTPS, .badResponse: outcome.code = nil
                }
                return outcome
            }
        }
        try? CompanionConfig.update(at: configURL) { $0.lastPresentAt = at }
        return outcome
    }

    /// One thread's entry: every GUID dated at or after its `since` less one second (the reader's margin). Past 2000
    /// GUIDs the thread's own `since` moves later, to the first whole second that fits; never a truncated list. nil
    /// when nothing fits or a string is over the contract's limit.
    static func entry(thread: String, rows: [PresentRow], since: Int64) -> PresentEntry? {
        guard !thread.isEmpty, thread.count <= maxString else { return nil }
        var dates: [String: TimeInterval] = [:]
        for row in rows {
            guard !row.guid.isEmpty, row.guid.count <= maxString else { return nil }
            dates[row.guid] = max(dates[row.guid] ?? row.date, row.date)
        }
        guard !dates.isEmpty else { return nil }
        let base = since - PresentRow.unixOffset
        func listed(from start: Int64) -> [String] {
            dates.filter { $0.value >= Double(start - 1) }.map(\.key).sorted()
        }
        if dates.count <= maxGUIDs { return PresentEntry(threadGUID: thread, since: since, guids: listed(from: base)) }
        let newest = dates.values.sorted(by: >)
        let cut = newest[maxGUIDs - 1]
        for start in [Int64(ceil(cut)) + 1, Int64(floor(cut)) + 2] where start > base {
            let guids = listed(from: start)
            if guids.count <= maxGUIDs {
                return guids.isEmpty ? nil : PresentEntry(threadGUID: thread, since: start + PresentRow.unixOffset, guids: guids)
            }
        }
        return nil
    }

    /// Requests of at most 200 entries and `CompanionService.maxBodyBytes`, each thread in one request.
    static func packed(_ entries: [PresentEntry], deviceID: String, cursor: Int64) -> [[PresentEntry]] {
        let empty = UplinkBatch(deviceID: deviceID, batchID: UUID(), cursor: cursor, firstRun: false, threads: [],
                                messages: [], present: [])
        let overhead = (try? CompanionJSON.encoder.encode(empty).count) ?? 1000
        var groups: [[PresentEntry]] = []
        var current: [PresentEntry] = []
        var size = overhead
        for entry in entries {
            // Each entry adds its own JSON and a comma.
            let added = ((try? CompanionJSON.encoder.encode(entry).count) ?? CompanionService.maxBodyBytes) + 1
            if !current.isEmpty, current.count == maxEntries || size + added > CompanionService.maxBodyBytes {
                groups.append(current)
                current = []
                size = overhead
            }
            current.append(entry)
            size += added
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
