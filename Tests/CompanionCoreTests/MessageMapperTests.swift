@testable import CompanionCore
import IMsgCore
import XCTest

final class MessageMapperTests: XCTestCase {
    private let thread = CompanionThread(guid: "any;-;+15555550100", kind: .direct, displayName: nil,
                                         participants: [CompanionParticipant(handle: "+15555550100", name: nil)],
                                         participantsFingerprint: "fp")
    private let date = Date(timeIntervalSince1970: 1_794_000_000)

    private func message(text: String = "hi", fromMe: Bool = false, attachments: Int = 0, reaction: Bool = false,
                         unsentAt: Date? = nil, chatID: Int64 = 1, service: String = "SMS",
                         sender: String = "+15555550100", originator: String? = nil) -> Message {
        Message(rowID: 7, chatID: chatID, sender: sender, text: text, date: date, isFromMe: fromMe, service: service,
                handleID: 1, attachmentsCount: attachments, guid: "g-7", threadOriginatorGUID: originator,
                isReaction: reaction, unsentAt: unsentAt)
    }

    private let body = RowFacts(itemType: 0, hasBody: true, error: 0, isSent: false)
    private let empty = RowFacts(itemType: 0, hasBody: false, error: 0, isSent: false)

    private func mapped(_ m: Message, facts: RowFacts? = nil, thread: CompanionThread? = nil) -> CompanionMessage? {
        if case .message(let result) = MessageMapper.map(m, facts: facts ?? body, thread: thread ?? self.thread) {
            return result
        }
        return nil
    }

    func test_text() throws {
        let m = try XCTUnwrap(mapped(message(text: "  hello\u{FFFC} ", originator: "g-1")))
        XCTAssertEqual(m.kind, .text)
        XCTAssertEqual(m.text, "hello", "the attachment placeholder and outer whitespace are stripped, as in the fork")
        XCTAssertEqual(m.threadGUID, "any;-;+15555550100")
        XCTAssertEqual(m.senderHandle, "+15555550100")
        XCTAssertEqual(m.replyToGUID, "g-1")
        XCTAssertEqual(m.service, "SMS")
        XCTAssertEqual(m.rowid, 7)
        XCTAssertEqual(m.guid, "g-7")
        XCTAssertEqual(m.sentAt, date)
        XCTAssertNil(m.unsent)
    }

    func test_unsentComesBeforeEveryKindRule() throws {
        let m = try XCTUnwrap(mapped(message(text: "", unsentAt: date), facts: empty))
        XCTAssertEqual(m.unsent, true)
        XCTAssertEqual(m.kind, .text)
        XCTAssertNil(m.text)
        XCTAssertEqual(m.attachmentCount, 0)
    }

    func test_systemRow() {
        let facts = RowFacts(itemType: 1, hasBody: false, error: 0, isSent: false)
        XCTAssertEqual(MessageMapper.map(message(text: ""), facts: facts, thread: thread), .system)
    }

    func test_nonZeroItemTypeWithTextIsRead() throws {
        let facts = RowFacts(itemType: 2, hasBody: true, error: 0, isSent: false)
        XCTAssertEqual(try XCTUnwrap(mapped(message(text: "kept"), facts: facts)).kind, .text)
    }

    func test_orphan() {
        XCTAssertEqual(MessageMapper.map(message(chatID: 0), facts: body, thread: nil), .orphan)
        XCTAssertEqual(MessageMapper.map(message(chatID: 5), facts: body, thread: nil), .orphan,
                       "a chat ROWID with no chat row is treated like no chat")
    }

    func test_reaction() throws {
        let m = try XCTUnwrap(mapped(message(text: "Loved a message", reaction: true)))
        XCTAssertEqual(m.kind, .reaction)
        XCTAssertNil(m.text)
    }

    func test_attachmentOnly() throws {
        let m = try XCTUnwrap(mapped(message(text: "", attachments: 2)))
        XCTAssertEqual(m.kind, .attachmentOnly)
        XCTAssertEqual(m.attachmentCount, 2)
        XCTAssertNil(m.text)
    }

    func test_undecodableBodyIsUnreadable() throws {
        XCTAssertEqual(try XCTUnwrap(mapped(message(text: ""), facts: body)).kind, .unreadable)
    }

    func test_emptyRowIsUnreadableAsInTheFork() throws {
        XCTAssertEqual(try XCTUnwrap(mapped(message(text: " "), facts: empty)).kind, .unreadable)
    }

    func test_fromMeHasNoSender() throws {
        XCTAssertNil(try XCTUnwrap(mapped(message(fromMe: true))).senderHandle)
        XCTAssertNil(try XCTUnwrap(mapped(message(sender: ""))).senderHandle)
    }
}
