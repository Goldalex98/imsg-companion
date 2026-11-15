import Foundation
import SQLite3

// The agent's own read-only queries for what IMsgCore doesn't give: threads and participants, system rows,
// the from-me thread set, send identity, twin chats and read-back facts (agent design §5.2, §5.4). The database is
// opened with SQLITE_OPEN_READONLY and only SELECT and PRAGMA statements run.

public enum ChatQueryError: Error, Equatable {
    /// The SQLite result code. SQLITE_CANTOPEN, SQLITE_AUTH and SQLITE_PERM mean no permission or no file.
    case unreadable(Int32)
    case unsupportedSchema(String)
    case query(String)
}

/// Which file a path pointed at when the queries opened it: device and inode from `stat`.
public struct CompanionFileIdentity: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64

    /// nil when the path can't be stat'ed (missing file, no permission).
    public static func of(path: String) -> CompanionFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return CompanionFileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

public struct CompanionSendIdentity: Equatable, Sendable {
    public let kind: CompanionThread.Kind
    /// `handle.id` as stored, the values passed to the send script.
    public let handles: [String]
    public let participantsFingerprint: String
}

/// What our per-page query knows about a row that IMsgCore's `Message` doesn't expose.
public struct RowFacts: Equatable, Sendable {
    public let itemType: Int
    /// `text` or `attributedBody` is present, so an empty decoded text means the body couldn't be read.
    public let hasBody: Bool
    public let error: Int
    public let isSent: Bool
    public init(itemType: Int, hasBody: Bool, error: Int, isSent: Bool) {
        self.itemType = itemType; self.hasBody = hasBody; self.error = error; self.isSent = isSent
    }
}

public final class ChatQueries: @unchecked Sendable {
    private var db: OpaquePointer?
    /// The file identity taken just before the database was opened; compare it with `CompanionFileIdentity.of`
    /// to notice that the path now points at a different file.
    public let fileIdentity: CompanionFileIdentity?
    private let lock = NSLock()

    private static let required: [String: Set<String>] = [
        "message": ["guid", "text", "attributedBody", "date", "is_from_me", "item_type", "error", "is_sent"],
        "chat": ["guid", "style", "display_name"],
        "handle": ["id"],
        "chat_handle_join": ["chat_id", "handle_id"],
        "chat_message_join": ["chat_id", "message_id"],
    ]

    public init(path: String) throws(ChatQueryError) {
        // Before the open: a swap in between then shows as a mismatch on the next check, never as a missed one.
        fileIdentity = CompanionFileIdentity.of(path: path)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw .unreadable(result)
        }
        db = handle
        sqlite3_busy_timeout(handle, 1500)
        do throws(ChatQueryError) {
            for (table, columns) in Self.required.sorted(by: { $0.key < $1.key }) {
                var present = Set<String>()
                try each("PRAGMA table_info(\(table))") { present.insert(Self.text($0, 1) ?? "") }
                let missing = columns.subtracting(present)
                guard missing.isEmpty else {
                    throw ChatQueryError.unsupportedSchema("\(table): \(missing.sorted().joined(separator: ","))")
                }
            }
        } catch {
            sqlite3_close(handle); db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func maxRowID() throws(ChatQueryError) -> Int64 {
        var value: Int64 = 0
        try each("SELECT COALESCE(MAX(ROWID), 0) FROM message") { value = sqlite3_column_int64($0, 0) }
        return value
    }

    /// The highest ROWID `message` has ever handed out. chat.db's message table uses AUTOINCREMENT, whose
    /// `sqlite_sequence` entry stays put when the newest messages are deleted, unlike MAX(ROWID). Falls back to
    /// MAX(ROWID) when the database has no such entry.
    public func highWaterRowID() throws(ChatQueryError) -> Int64 {
        var hasSequence = false
        try each("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'") { _ in hasSequence = true }
        var sequence: Int64 = 0
        if hasSequence {
            try each("SELECT seq FROM sqlite_sequence WHERE name = 'message'") { sequence = sqlite3_column_int64($0, 0) }
        }
        return max(sequence, try maxRowID())
    }

    /// The lowest ROWID dated at or after `since`, or nil when there is none.
    public func firstRowID(since: Date) throws(ChatQueryError) -> Int64? {
        var value: Int64?
        let sql = "SELECT MIN(ROWID) FROM message WHERE (CASE WHEN date > 1000000000000 THEN date / 1000000000.0 ELSE date END) >= ?"
        try each(sql, [.double(since.timeIntervalSinceReferenceDate)]) {
            if sqlite3_column_type($0, 0) != SQLITE_NULL { value = sqlite3_column_int64($0, 0) }
        }
        return value
    }

    public func threads(guids: Set<String>) throws(ChatQueryError) -> [CompanionThread] {
        guard !guids.isEmpty else { return [] }
        let ordered = guids.sorted()
        let marks = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        var seen = Set<String>()
        return try chats(where: "guid IN (\(marks))", ordered.map { .text($0) })
            .filter { seen.insert($0.thread.guid).inserted }.map(\.thread)
    }

    /// Keyed by chat ROWID; a ROWID with no chat row is left out.
    public func threads(chatRowIDs: Set<Int64>) throws(ChatQueryError) -> [Int64: CompanionThread] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let ordered = chatRowIDs.sorted()
        let marks = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        var result: [Int64: CompanionThread] = [:]
        for chat in try chats(where: "ROWID IN (\(marks))", ordered.map { .int($0) }) { result[chat.rowID] = chat.thread }
        return result
    }

    public func sendIdentity(chatGUID: String) throws(ChatQueryError) -> CompanionSendIdentity? {
        guard let thread = try threads(guids: [chatGUID]).first else { return nil }
        return CompanionSendIdentity(kind: thread.kind, handles: thread.participants.map(\.handle),
                                     participantsFingerprint: thread.participantsFingerprint)
    }

    /// The chat's own ROWIDs plus every chat row with the same normalized participant set (Messages can file a
    /// send under a twin row, imsg #394). Empty when the GUID has no chat.
    public func twinChatRowIDs(chatGUID: String) throws(ChatQueryError) -> Set<Int64> {
        let all = try chats(where: "1 = 1", [])
        let targets = all.filter { $0.thread.guid == chatGUID }
        guard !targets.isEmpty else { return [] }
        let wanted = Set(targets.map(\.normalized))
        return Set(all.filter { wanted.contains($0.normalized) }.map(\.rowID))
    }

    public func rowFacts(rowIDs: [Int64]) throws(ChatQueryError) -> [Int64: RowFacts] {
        guard !rowIDs.isEmpty else { return [:] }
        let ordered = Array(Set(rowIDs)).sorted()
        let marks = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        var result: [Int64: RowFacts] = [:]
        try each("""
            SELECT ROWID, COALESCE(item_type, 0), (text IS NOT NULL OR attributedBody IS NOT NULL),
                   COALESCE(error, 0), COALESCE(is_sent, 0)
            FROM message WHERE ROWID IN (\(marks))
            """, ordered.map { .int($0) }) { s in
            result[sqlite3_column_int64(s, 0)] = RowFacts(itemType: Int(sqlite3_column_int64(s, 1)),
                                                          hasBody: sqlite3_column_int64(s, 2) != 0,
                                                          error: Int(sqlite3_column_int64(s, 3)),
                                                          isSent: sqlite3_column_int64(s, 4) != 0)
        }
        return result
    }

    /// Chats with any row from Alex: the verification-code skip applies only outside these (agent design §5.2).
    public func fromMeChatRowIDs() throws(ChatQueryError) -> Set<Int64> {
        var result = Set<Int64>()
        try each("""
            SELECT DISTINCT cmj.chat_id FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE m.is_from_me = 1
            """) { result.insert(sqlite3_column_int64($0, 0)) }
        return result
    }

    // MARK: - Helpers

    private struct ChatRow {
        let rowID: Int64
        let thread: CompanionThread
        /// The sorted, normalized handles, for matching twins.
        let normalized: [String]
    }

    private func chats(where clause: String, _ bindings: [Binding]) throws(ChatQueryError) -> [ChatRow] {
        var rows: [(rowid: Int64, guid: String, style: Int64, name: String?)] = []
        try each("SELECT ROWID, guid, style, display_name FROM chat WHERE \(clause) ORDER BY ROWID", bindings) { s in
            guard let guid = Self.text(s, 1) else { return }
            rows.append((sqlite3_column_int64(s, 0), guid, sqlite3_column_int64(s, 2), Self.text(s, 3)))
        }
        var result: [ChatRow] = []
        for row in rows {
            var handles: [String] = []
            var normalized = Set<String>()
            try each("""
                SELECT h.id FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id
                WHERE ch.chat_id = ? ORDER BY h.ROWID
                """, [.int(row.rowid)]) { s in
                // One handle row per service, so the same person can appear twice.
                guard let id = Self.text(s, 0), !id.isEmpty, normalized.insert(HandleNormalizer.normalize(id)).inserted
                else { return }
                handles.append(id)
            }
            let thread = CompanionThread(
                guid: row.guid, kind: row.style == 43 ? .group : .direct,
                displayName: row.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                participants: handles.map { CompanionParticipant(handle: $0, name: nil) },
                participantsFingerprint: CompanionFingerprint.of(handles: handles))
            result.append(ChatRow(rowID: row.rowid, thread: thread, normalized: normalized.sorted()))
        }
        return result
    }

    private enum Binding { case int(Int64), double(Double), text(String) }

    private func each(_ sql: String, _ bindings: [Binding] = [], _ row: (OpaquePointer) -> Void) throws(ChatQueryError) {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure(prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
            row(statement)
        }
    }

    /// Test hook: runs a statement through the read-only connection so a test can prove writes fail.
    func execForTesting(_ sql: String) throws(ChatQueryError) { try each(sql) { _ in } }

    private func failure(_ code: Int32) -> ChatQueryError {
        let primary = code & 0xff
        if [SQLITE_CANTOPEN, SQLITE_AUTH, SQLITE_PERM, SQLITE_NOTADB].contains(primary) { return .unreadable(primary) }
        return .query(String(cString: sqlite3_errmsg(db)))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
