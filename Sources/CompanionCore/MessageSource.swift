import Foundation
import IMsgCore

/// New rows come from IMsgCore's ROWID paging (agent design §5.2). A protocol so tests can script pages.
public protocol MessagePaging: Sendable {
    func page(after rowID: Int64, limit: Int) throws -> MessagesAfterPage
}

/// Read-only: `MessageStore` opens chat.db with `mode=ro`. Reactions are included so they reach HomeChat as kind
/// `reaction`; `nextRowID` is the last physical row scanned, so the cursor passes rows IMsgCore hides.
public struct IMsgCorePaging: MessagePaging, @unchecked Sendable {
    private let store: MessageStore

    public init(path: String) throws {
        store = try MessageStore(path: path)
    }

    public func page(after rowID: Int64, limit: Int) throws -> MessagesAfterPage {
        try store.messagesAfterPage(afterRowID: rowID, chatID: nil, limit: limit, includeReactions: true)
    }
}
