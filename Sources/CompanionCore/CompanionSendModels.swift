import CryptoKit
import Foundation

// Wire types for the send routes in the uplink contract
// (`GET /imsg/sends`, `POST /imsg/send-results`).

/// A send Alex approved on HomeChat, with its exact text.
public struct ApprovedSend: Codable, Sendable, Equatable {
    public let sendID: String
    public let threadGUID: String
    public let participantsFingerprint: String
    /// Sent exactly as is; never trimmed.
    public let text: String
    public let textSHA256: String
    public let approvedAt: Date
    public let expiresAt: Date

    public init(sendID: String, threadGUID: String, participantsFingerprint: String, text: String, textSHA256: String,
                approvedAt: Date, expiresAt: Date) {
        self.sendID = sendID; self.threadGUID = threadGUID; self.participantsFingerprint = participantsFingerprint
        self.text = text; self.textSHA256 = textSHA256; self.approvedAt = approvedAt; self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case sendID = "send_id", threadGUID = "thread_guid", participantsFingerprint = "participants_fingerprint", text,
             textSHA256 = "text_sha256", approvedAt = "approved_at", expiresAt = "expires_at"
    }
}

public struct SendsPage: Codable, Sendable, Equatable {
    public let sends: [ApprovedSend]
    /// Optional remote control (contract, 2026-11-15). It can pause the agent, never turn sends on.
    public let control: Control?
    public init(sends: [ApprovedSend], control: Control? = nil) { self.sends = sends; self.control = control }

    public struct Control: Codable, Sendable, Equatable {
        public let paused: Bool?
        public init(paused: Bool?) { self.paused = paused }
    }
}

public enum SendOutcome: String, Codable, Sendable { case sent, notSent = "not_sent", ambiguous }

/// The fixed codes a result may carry. Never free text.
public enum SendDetail: String, Codable, Sendable, CaseIterable {
    case confirmed, expired, approvalTooLong = "approval_too_long", textRules = "text_rules",
         hashMismatch = "hash_mismatch", dailyCap = "daily_cap", paused, sendsOff = "sends_off",
         threadMissing = "thread_missing", threadChanged = "thread_changed", notIMessage = "not_imessage",
         badTarget = "bad_target", automationDenied = "automation_denied", scriptRefused = "script_refused",
         messagesError = "messages_error", noReadback = "no_readback", multipleMatches = "multiple_matches",
         notConfirmed = "not_confirmed", scriptUncertain = "script_uncertain", databaseUnreadable = "database_unreadable",
         recoveredAfterRestart = "recovered_after_restart"
}

public struct SendResult: Codable, Sendable, Equatable {
    public let sendID: String
    public let outcome: SendOutcome
    public let anchorGUID: String?
    /// The Mac's own hash of the text it fetched.
    public let textSHA256: String
    public let detail: SendDetail
    /// The service of the sent row read back from chat.db; nil when none was read back. Always encoded.
    public let sentService: String?

    public init(sendID: String, outcome: SendOutcome, anchorGUID: String?, textSHA256: String, detail: SendDetail,
                sentService: String? = nil) {
        self.sendID = sendID; self.outcome = outcome; self.anchorGUID = anchorGUID; self.textSHA256 = textSHA256
        self.detail = detail; self.sentService = sentService
    }

    enum CodingKeys: String, CodingKey {
        case sendID = "send_id", outcome, anchorGUID = "anchor_guid", textSHA256 = "text_sha256", detail,
             sentService = "sent_service"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sendID, forKey: .sendID)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(anchorGUID, forKey: .anchorGUID)
        try c.encode(textSHA256, forKey: .textSHA256)
        try c.encode(detail, forKey: .detail)
        try c.encode(sentService, forKey: .sentService)
    }
}

public enum CompanionTextHash {
    /// Lowercase hex SHA-256 of the exact UTF-8 bytes (no trimming, no Unicode normalization).
    public static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One outgoing `chat.db` row after a send, for the read-back decision.
public struct CompanionOutgoingRow: Equatable, Sendable {
    public let rowID: Int64
    public let guid: String
    /// The decoded text; exact, never trimmed or scrubbed. Kept in memory only.
    public let body: String?
    public let error: Int
    public let isSent: Bool
    public init(rowID: Int64, guid: String, body: String?, error: Int, isSent: Bool) {
        self.rowID = rowID; self.guid = guid; self.body = body; self.error = error; self.isSent = isSent
    }
}
