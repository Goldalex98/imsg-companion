import Foundation
import IMsgCore

/// New rows come from IMsgCore's ROWID paging (agent design §5.2). A protocol so tests can script pages.
public protocol MessagePaging: Sendable {
    func page(after rowID: Int64, limit: Int) throws -> MessagesAfterPage
}

/// Read-only: `MessageStore` opens chat.db with `mode=ro`. The reader includes reactions so they reach HomeChat as
/// kind `reaction`; the send read-back leaves them out. `nextRowID` is the last physical row scanned, so a cursor
/// passes rows IMsgCore hides.
public struct IMsgCorePaging: MessagePaging, @unchecked Sendable {
    private let store: MessageStore
    private let includeReactions: Bool

    public init(path: String, includeReactions: Bool = true) throws {
        store = try MessageStore(path: path)
        self.includeReactions = includeReactions
    }

    public func page(after rowID: Int64, limit: Int) throws -> MessagesAfterPage {
        try store.messagesAfterPage(afterRowID: rowID, chatID: nil, limit: limit, includeReactions: includeReactions)
    }
}
