import CryptoKit
import Foundation

// Wire format for docs/specs/2026-11-08-imsg-uplink-contract.md (with its 2026-11-15 additions).

public struct CompanionParticipant: Codable, Sendable, Equatable {
    public var handle: String
    public var name: String?
    public init(handle: String, name: String?) { self.handle = handle; self.name = name }
    enum CodingKeys: String, CodingKey { case handle, name }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(handle, forKey: .handle)
        try c.encode(name, forKey: .name)
    }
}

public struct CompanionThread: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case direct, group }
    public var guid: String
    public var kind: Kind
    public var displayName: String?
    public var participants: [CompanionParticipant]
    public var participantsFingerprint: String
    public init(guid: String, kind: Kind, displayName: String?, participants: [CompanionParticipant],
                participantsFingerprint: String) {
        self.guid = guid; self.kind = kind; self.displayName = displayName
        self.participants = participants; self.participantsFingerprint = participantsFingerprint
    }
    enum CodingKeys: String, CodingKey {
        case guid, kind, displayName = "display_name", participants, participantsFingerprint = "participants_fingerprint"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guid, forKey: .guid)
        try c.encode(kind, forKey: .kind)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(participants, forKey: .participants)
        try c.encode(participantsFingerprint, forKey: .participantsFingerprint)
    }
}

public struct CompanionMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case text, reaction, attachmentOnly = "attachment_only", unreadable, skipped
    }
    public var guid: String
    public var rowid: Int64
    public var threadGUID: String
    public var fromMe: Bool
    public var senderHandle: String?
    public var sentAt: Date
    public var kind: Kind
    public var text: String?
    public var replyToGUID: String?
    public var attachmentCount: Int
    /// The row's own service as IMsgCore reports it (per message, never per thread). Always encoded.
    public var service: String?
    /// True only on a re-post of a message the sender unsent; encoded only when true.
    public var unsent: Bool?
    public init(guid: String, rowid: Int64, threadGUID: String, fromMe: Bool, senderHandle: String?, sentAt: Date,
                kind: Kind, text: String?, replyToGUID: String?, attachmentCount: Int, service: String? = nil,
                unsent: Bool? = nil) {
        self.guid = guid; self.rowid = rowid; self.threadGUID = threadGUID; self.fromMe = fromMe
        self.senderHandle = senderHandle; self.sentAt = sentAt; self.kind = kind; self.text = text
        self.replyToGUID = replyToGUID; self.attachmentCount = attachmentCount; self.service = service
        self.unsent = unsent
    }
    enum CodingKeys: String, CodingKey {
        case guid, rowid, threadGUID = "thread_guid", fromMe = "from_me", senderHandle = "sender_handle",
             sentAt = "sent_at", kind, text, replyToGUID = "reply_to_guid", attachmentCount = "attachment_count",
             service, unsent
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guid, forKey: .guid)
        try c.encode(rowid, forKey: .rowid)
        try c.encode(threadGUID, forKey: .threadGUID)
        try c.encode(fromMe, forKey: .fromMe)
        try c.encode(senderHandle, forKey: .senderHandle)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(replyToGUID, forKey: .replyToGUID)
        try c.encode(attachmentCount, forKey: .attachmentCount)
        try c.encode(service, forKey: .service)
        if unsent == true { try c.encode(true, forKey: .unsent) }
    }
}

public struct UplinkBatch: Codable, Sendable, Equatable {
    public var deviceID: String
    public var batchID: UUID
    public var cursor: Int64
    public var firstRun: Bool
    public var threads: [CompanionThread]
    public var messages: [CompanionMessage]
    /// The deletion reconcile (contract 2026-11-15 additions (2)); only on a present-only request, else left out.
    public var present: [PresentEntry]?
    public init(deviceID: String, batchID: UUID, cursor: Int64, firstRun: Bool, threads: [CompanionThread],
                messages: [CompanionMessage], present: [PresentEntry]? = nil) {
        self.deviceID = deviceID; self.batchID = batchID; self.cursor = cursor; self.firstRun = firstRun
        self.threads = threads; self.messages = messages; self.present = present
    }
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", batchID = "batch_id", cursor, firstRun = "first_run", threads, messages, present
    }
}

/// Every message GUID still in `chat.db` for one thread, sent at or after `since` (Unix epoch seconds).
public struct PresentEntry: Codable, Sendable, Equatable {
    public var threadGUID: String
    public var since: Int64
    public var guids: [String]
    public init(threadGUID: String, since: Int64, guids: [String]) {
        self.threadGUID = threadGUID; self.since = since; self.guids = guids
    }
    enum CodingKeys: String, CodingKey { case threadGUID = "thread_guid", since, guids }
}

public struct UplinkAck: Codable, Sendable, Equatable {
    public var acceptedCursor: Int64
    /// True when HomeChat dropped the request's `present` whole (malformed, over a limit, too old).
    public var presentSkipped: Bool?
    public init(acceptedCursor: Int64, presentSkipped: Bool? = nil) {
        self.acceptedCursor = acceptedCursor; self.presentSkipped = presentSkipped
    }
    enum CodingKeys: String, CodingKey { case acceptedCursor = "accepted_cursor", presentSkipped = "present_skipped" }
}

/// Lowercase hex SHA-256 of the normalized handles, sorted and joined with "\n" (contract: participants_fingerprint).
public enum CompanionFingerprint {
    public static func of(handles: [String]) -> String {
        let joined = handles.map(HandleNormalizer.normalize).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CompanionJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
