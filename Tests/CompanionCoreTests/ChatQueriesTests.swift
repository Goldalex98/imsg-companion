@testable import CompanionCore
import XCTest

final class ChatQueriesTests: XCTestCase {
    private let alice = "+15555550100", bob = "+15555550101"

    func test_sendIdentityIgnoresServiceName() throws {
        let f = try CompanionFixture()
        try f.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice], service: "SMS")
        let identity = try XCTUnwrap(try ChatQueries(path: f.url.path).sendIdentity(chatGUID: "any;-;+15555550100"))
        XCTAssertEqual(identity.kind, .direct)
        XCTAssertEqual(identity.handles, [alice])
        XCTAssertEqual(identity.participantsFingerprint, CompanionFingerprint.of(handles: [alice]))
    }

    func test_sendIdentityMissingThread() throws {
        let f = try CompanionFixture()
        XCTAssertNil(try ChatQueries(path: f.url.path).sendIdentity(chatGUID: "any;-;+15555550199"))
    }

    func test_threadsByGUIDAndRowID() throws {
        let f = try CompanionFixture()
        let group = try f.addChat(guid: "any;+;chat-test", style: 43, displayName: " ", handles: [alice, bob])
        let q = try ChatQueries(path: f.url.path)
        let byGUID = try q.threads(guids: ["any;+;chat-test"])
        XCTAssertEqual(byGUID.map(\.kind), [.group])
        XCTAssertNil(byGUID.first?.displayName, "blank names are dropped")
        XCTAssertEqual(try q.threads(chatRowIDs: [group])[group], byGUID.first)
        XCTAssertEqual(try q.threads(chatRowIDs: [999]), [:])
    }

    func test_twinChats() throws {
        let f = try CompanionFixture()
        let a = try f.addChat(guid: "any;+;chat-test", style: 43, displayName: nil, handles: [alice, bob])
        let b = try f.addChat(guid: "any;+;chat-twin", style: 43, displayName: nil,
                              handles: ["+1 (555) 555-0101", "+1 555 555 0100"])
        try f.addChat(guid: "any;+;chat-bigger", style: 43, displayName: nil, handles: [alice, bob, "+15555550102"])
        XCTAssertEqual(try ChatQueries(path: f.url.path).twinChatRowIDs(chatGUID: "any;+;chat-test"), [a, b])
        XCTAssertEqual(try ChatQueries(path: f.url.path).twinChatRowIDs(chatGUID: "any;+;none"), [])
    }

    func test_rowFacts() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice])
        let system = try f.addMessage(chats: [chat], itemType: 1)
        let blobOnly = try f.addMessage(chats: [chat], attributedBody: Data([1, 2, 3]))
        let failed = try f.addMessage(chats: [chat], text: "x", fromMe: true, error: 22, isSent: false)
        let sent = try f.addMessage(chats: [chat], text: "y", fromMe: true, isSent: true)
        let facts = try ChatQueries(path: f.url.path).rowFacts(rowIDs: [system, blobOnly, failed, sent, 999])
        XCTAssertEqual(facts[system], RowFacts(itemType: 1, hasBody: false, error: 0, isSent: false))
        XCTAssertEqual(facts[blobOnly], RowFacts(itemType: 0, hasBody: true, error: 0, isSent: false))
        XCTAssertEqual(facts[failed], RowFacts(itemType: 0, hasBody: true, error: 22, isSent: false))
        XCTAssertEqual(facts[sent]?.isSent, true)
        XCTAssertNil(facts[999])
        XCTAssertEqual(try ChatQueries(path: f.url.path).rowFacts(rowIDs: []), [:])
    }

    func test_fromMeChats() throws {
        let f = try CompanionFixture()
        let written = try f.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice])
        let silent = try f.addChat(guid: "any;-;+15555550101", style: 45, displayName: nil, handles: [bob])
        try f.addMessage(chats: [written], text: "hi", fromMe: true)
        try f.addMessage(chats: [silent], text: "code 1234", handle: bob)
        XCTAssertEqual(try ChatQueries(path: f.url.path).fromMeChatRowIDs(), [written])
    }

    func test_highWaterSurvivesDeletingNewest() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], text: "a", handle: alice)
        let last = try f.addMessage(chats: [chat], text: "b", handle: alice)
        try f.deleteMessage(last)
        let q = try ChatQueries(path: f.url.path)
        XCTAssertEqual(try q.maxRowID(), last - 1)
        XCTAssertEqual(try q.highWaterRowID(), last)
    }

    func test_firstRowIDSince() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "any;-;+15555550100", style: 45, displayName: nil, handles: [alice])
        let now = Date()
        try f.addMessage(chats: [chat], text: "old", date: now.addingTimeInterval(-5 * 86_400), handle: alice)
        let recent = try f.addMessage(chats: [chat], text: "new", date: now.addingTimeInterval(-3600), handle: alice)
        XCTAssertEqual(try ChatQueries(path: f.url.path).firstRowID(since: now.addingTimeInterval(-86_400)), recent)
        XCTAssertNil(try ChatQueries(path: f.url.path).firstRowID(since: now.addingTimeInterval(60)))
    }

    func test_openIsReadOnly() throws {
        let f = try CompanionFixture()
        let q = try ChatQueries(path: f.url.path)
        XCTAssertThrowsError(try q.execForTesting("UPDATE message SET text = 'x'"))
    }

    func test_missingFileIsUnreadable() {
        XCTAssertThrowsError(try ChatQueries(path: "/nonexistent/chat.db")) { error in
            guard case ChatQueryError.unreadable = error else { return XCTFail("\(error)") }
        }
    }
}
