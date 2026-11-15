import Foundation
import IMsgCore

/// What one IMsgCore row becomes on the wire (agent design §5.2: kinds map 1:1 to the contract).
public enum MappedRow: Equatable, Sendable {
    case message(CompanionMessage)
    /// A group event or other system row: passed over, as in the fork.
    case system
    /// No chat yet (or a chat ROWID with no chat row): the caller decides whether to hold the cursor.
    case orphan
}

public enum MessageMapper {
    public static func map(_ m: Message, facts: RowFacts?, thread: CompanionThread?) -> MappedRow {
        let text = clean(m.text)
        // Unsent rows arrive with empty text and 0 attachments, so this comes before every kind rule.
        if m.unsentAt != nil {
            guard let thread, m.chatID > 0 else { return .orphan }
            return .message(message(m, thread: thread, kind: .text, text: nil, attachments: 0, unsent: true))
        }
        // As the fork: a non-zero item_type with no text, body or attachments. Anything carrying one is read.
        if let facts, facts.itemType != 0, !facts.hasBody, text == nil, m.attachmentsCount == 0 { return .system }
        guard m.chatID > 0, let thread else { return .orphan }
        if m.isReaction {
            return .message(message(m, thread: thread, kind: .reaction, text: nil, attachments: m.attachmentsCount))
        }
        if let text {
            return .message(message(m, thread: thread, kind: .text, text: text, attachments: m.attachmentsCount))
        }
        // IMsgCore has no unreadable signal: an empty decode with no attachments is unreadable, as in the fork.
        let kind: CompanionMessage.Kind = m.attachmentsCount > 0 ? .attachmentOnly : .unreadable
        return .message(message(m, thread: thread, kind: kind, text: nil, attachments: m.attachmentsCount))
    }

    private static func message(_ m: Message, thread: CompanionThread, kind: CompanionMessage.Kind, text: String?,
                                attachments: Int, unsent: Bool? = nil) -> CompanionMessage {
        CompanionMessage(guid: m.guid, rowid: m.rowID, threadGUID: thread.guid, fromMe: m.isFromMe,
                         senderHandle: m.isFromMe || m.sender.isEmpty ? nil : m.sender, sentAt: m.date, kind: kind,
                         text: text, replyToGUID: m.threadOriginatorGUID.flatMap { $0.isEmpty ? nil : $0 },
                         attachmentCount: attachments, service: m.service, unsent: unsent)
    }

    /// Strips U+FFFC (the attachment placeholder) and surrounding whitespace; empty becomes nil (as the fork).
    static func clean(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
