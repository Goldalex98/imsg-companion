import XCTest
@testable import CompanionCore

final class CompanionScrubberTests: XCTestCase {
    private func message(text: String?, sender: String? = "+15550100001", kind: CompanionMessage.Kind = .text) -> CompanionMessage {
        CompanionMessage(guid: "g-1", rowid: 9, threadGUID: "iMessage;-;direct", fromMe: false, senderHandle: sender,
                         sentAt: Date(timeIntervalSince1970: 1_794_000_000), kind: kind, text: text, replyToGUID: nil,
                         attachmentCount: 0)
    }

    func test_ssnShapes() {
        XCTAssertEqual(CompanionScrubber.scrub("123-45-6789"), "[SSN removed]")
        XCTAssertEqual(CompanionScrubber.scrub("123 45 6789"), "[SSN removed]")
        XCTAssertEqual(CompanionScrubber.scrub("my ssn is 123456789."), "my ssn is [SSN removed].")
        XCTAssertEqual(CompanionScrubber.scrub("a 123-45-6789 and 987654321 b"), "a [SSN removed] and [SSN removed] b")
        for unchanged in ["5550100001", "call 555-010-0001", "order 1234567890123", "2026-11-08", "$123.45"] {
            XCTAssertEqual(CompanionScrubber.scrub(unchanged), unchanged)
        }
    }

    func test_ssnVariants() {
        XCTAssertEqual(CompanionScrubber.scrub("ssn 123.45.6789 ok"), "ssn [SSN removed] ok")
        XCTAssertEqual(CompanionScrubber.scrub("１２３-４５-６７８９"), "[SSN removed]")
        XCTAssertEqual(CompanionScrubber.scrub("pi is 3.14159"), "pi is 3.14159")
    }

    func test_verificationVariantsSkipped() {
        for text in ["Your WhatsApp code: 123-456", "Your code is 482 913", "Your PIN is 4821",
                     "G-482913 is your verification code"] {
            XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "+15550100001", text: text, threadHasFromMe: false), text)
        }
        XCTAssertFalse(CompanionScrubber.isSkipped(senderHandle: "+15550100001", text: "pinned it, see you at 1234 Main St", threadHasFromMe: false))
    }

    func test_shortCodeSenderSkipped() {
        XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "72975", text: "hello", threadHasFromMe: false))
        XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "262966", text: nil, threadHasFromMe: false))
        XCTAssertFalse(CompanionScrubber.isSkipped(senderHandle: "+15550100001", text: "hello", threadHasFromMe: false))
        XCTAssertFalse(CompanionScrubber.isSkipped(senderHandle: nil, text: "hello", threadHasFromMe: false))
    }

    func test_verificationCodeSkipped() {
        for text in ["Your verification code is 482913", "123456 is your login code", "Use passcode 4829 to sign in",
                     "Your OTP: 902113"] {
            XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "+15550100001", text: text, threadHasFromMe: false), text)
        }
        for text in ["the code review is at 3", "meet at 1234 Main St"] {
            XCTAssertFalse(CompanionScrubber.isSkipped(senderHandle: "+15550100001", text: text, threadHasFromMe: false), text)
        }
    }

    func test_applySkippedDropsText() {
        let scrubbed = CompanionScrubber.apply(to: message(text: "Your verification code is 482913"), threadHasFromMe: false)
        XCTAssertEqual(scrubbed.guid, "g-1")
        XCTAssertEqual(scrubbed.threadGUID, "iMessage;-;direct")
        XCTAssertFalse(scrubbed.fromMe)
        XCTAssertEqual(scrubbed.kind, .skipped)
        XCTAssertNil(scrubbed.text)
    }

    func test_applyScrubsSSN() {
        XCTAssertEqual(CompanionScrubber.apply(to: message(text: "it's 123-45-6789"), threadHasFromMe: false).text, "it's [SSN removed]")
    }

    func test_applyTruncates() {
        let long = CompanionScrubber.apply(to: message(text: String(repeating: "x", count: 5000)), threadHasFromMe: false).text ?? ""
        XCTAssertEqual(long.count, 4000)
        XCTAssertTrue(long.hasSuffix("…[truncated]"))
        let emoji = CompanionScrubber.apply(to: message(text: String(repeating: "👋🏽", count: 3000)), threadHasFromMe: false).text ?? ""
        XCTAssertLessThanOrEqual(emoji.unicodeScalars.count, 4000, "the server counts code points")
        XCTAssertTrue(emoji.hasSuffix("…[truncated]"))
        XCTAssertEqual(CompanionScrubber.apply(to: message(text: String(repeating: "x", count: 4000)), threadHasFromMe: false).text?.count, 4000)
    }

    // Agent design §5.2: the verification-code skip applies only where Alex has never written.
    func test_codeSkipOnlyInThreadsWithoutFromMe() {
        XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "+15555550100", text: "Your code is 482913",
                                                  threadHasFromMe: false))
        XCTAssertFalse(CompanionScrubber.isSkipped(senderHandle: "+15555550100", text: "Your code is 482913",
                                                   threadHasFromMe: true))
    }

    func test_shortCodeSkippedEitherWay() {
        XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "72345", text: "hello", threadHasFromMe: true))
        XCTAssertTrue(CompanionScrubber.isSkipped(senderHandle: "72345", text: "hello", threadHasFromMe: false))
    }

    func test_ssnStillScrubbedInWrittenThread() {
        let message = CompanionMessage(guid: "g", rowid: 1, threadGUID: "any;-;+15555550100", fromMe: false,
                                       senderHandle: "+15555550100", sentAt: Date(), kind: .text,
                                       text: "code 1234, ssn 123-45-6789", replyToGUID: nil, attachmentCount: 0)
        let result = CompanionScrubber.apply(to: message, threadHasFromMe: true)
        XCTAssertEqual(result.kind, .text)
        XCTAssertEqual(result.text, "code 1234, ssn [SSN removed]")
    }
}
