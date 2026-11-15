import XCTest
@testable import CompanionCore
import IMsgCore

/// The read-back after a send: from-me rows after the baseline, in the chat or its twins, read to the end.
final class CompanionSendReadTests: XCTestCase {
    private let alice = "+15555550100"

    private func read(_ f: CompanionFixture, after baseline: Int64, chats: Set<Int64>) throws -> [CompanionOutgoingRow] {
        try CompanionSendExecutor.outgoingRows(paging: IMsgCorePaging(path: f.url.path, includeReactions: false),
                                               queries: ChatQueries(path: f.url.path), after: baseline, in: chats)
    }

    func test_strictlyAfterBaseline() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        let old = try f.addMessage(chats: [chat], text: "same", fromMe: true, isSent: true)
        try f.addMessage(chats: [chat], guid: "new-row", text: "same", fromMe: true, isSent: true)
        XCTAssertEqual(try read(f, after: old, chats: [chat]).map(\.guid), ["new-row"])
    }

    func test_decodesAttributedBodyExactly() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], attributedBody: CompanionFixture.archived("  See you at 6 "), fromMe: true,
                         isSent: true)
        XCTAssertEqual(try read(f, after: 0, chats: [chat]).map(\.body), ["  See you at 6 "], "never trimmed")
    }

    func test_readsErrorIsSentAndService() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        try f.addMessage(chats: [chat], text: "x", fromMe: true, error: 22, isSent: false, service: "SMS")
        let row = try XCTUnwrap(try read(f, after: 0, chats: [chat]).first)
        XCTAssertEqual(row.error, 22)
        XCTAssertFalse(row.isSent)
        XCTAssertEqual(row.service, "SMS")
    }

    func test_skipsIncomingAndOtherChats() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        let other = try f.addChat(guid: "iMessage;-;other", style: 45, displayName: nil, handles: ["+15555550101"])
        try f.addMessage(chats: [chat], text: "in", handle: alice)
        try f.addMessage(chats: [other], text: "elsewhere", fromMe: true, isSent: true)
        try f.addMessage(chats: [chat], guid: "mine", text: "out", fromMe: true, isSent: true)
        XCTAssertEqual(try read(f, after: 0, chats: [chat]).map(\.guid), ["mine"])
    }

    func test_pagesToTheEnd() throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: [alice])
        let other = try f.addChat(guid: "iMessage;-;other", style: 45, displayName: nil, handles: ["+15555550101"])
        for _ in 0..<120 { try f.addMessage(chats: [other], text: "busy", handle: "+15555550101") }
        try f.addMessage(chats: [chat], guid: "late", text: "out", fromMe: true, isSent: true)
        XCTAssertEqual(try read(f, after: 0, chats: [chat]).map(\.guid), ["late"])
    }
}
