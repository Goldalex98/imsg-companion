@testable import CompanionCore
import XCTest

/// The changes made while lifting the fork's core (plan Task 3, Step 4).
final class LiftChangesTests: XCTestCase {
    func test_tokenStoreServiceIsFixed() {
        XCTAssertEqual(KeychainTokenStore.defaultService, "io.github.goldalex98.imsg-companion.companion-uplink")
    }

    func test_supportFolder() {
        XCTAssertEqual(CompanionConfig.supportFolder, "imsg-companion")
    }

    func test_missingTunablesGiveDefaults() throws {
        let json = #"{"device_id":"mac-0a1b2c3d","paused":false}"#
        let config = try CompanionJSON.decoder.decode(CompanionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.tunables.dailySendCap, 30)
        XCTAssertEqual(config.tunables.backoffInitialSeconds, 5)
        XCTAssertEqual(config.tunables.backoffMaxSeconds, 300)
    }

    func test_tunablesRoundTripAndIgnoreUnknownKeys() throws {
        let json = #"{"device_id":"mac-0a1b2c3d","paused":false,"tunables":{"daily_send_cap":5,"something_new":1}}"#
        let config = try CompanionJSON.decoder.decode(CompanionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.tunables.dailySendCap, 5)
        XCTAssertEqual(config.tunables.backoffMaxSeconds, 300)
        let again = try CompanionJSON.decoder.decode(CompanionConfig.self, from: CompanionJSON.encoder.encode(config))
        XCTAssertEqual(again, config)
    }

    func test_scriptHasNoServiceCheck() {
        XCTAssertFalse(CompanionSendScript.source(dispatch: true).contains("service type"))
        XCTAssertFalse(CompanionSendScript.source(dispatch: true).contains("9003"))
        XCTAssertTrue(CompanionSendScript.source(dispatch: true).contains("send messageText to targetChat"))
    }

    func test_preflightSourceNeverSends() {
        let source = CompanionSendScript.source(dispatch: false)
        XCTAssertFalse(source.contains("send "))
        XCTAssertTrue(source.contains(#"return "READY""#))
        for code in ["9001", "9002", "9004"] { XCTAssertTrue(source.contains(code), code) }
    }

    func test_readyParses() {
        XCTAssertEqual(CompanionSendScript.parse("READY\n"), .ready)
    }

    func test_sendsPageControlIsOptional() throws {
        let bare = try CompanionJSON.decoder.decode(SendsPage.self, from: Data(#"{"sends":[]}"#.utf8))
        XCTAssertNil(bare.control)
        let paused = try CompanionJSON.decoder.decode(SendsPage.self,
                                                      from: Data(#"{"sends":[],"control":{"paused":true}}"#.utf8))
        XCTAssertEqual(paused.control?.paused, true)
    }

    func test_sendResultAlwaysCarriesSentService() throws {
        let result = SendResult(sendID: "snd-1", outcome: .notSent, anchorGUID: nil, textSHA256: "x", detail: .expired,
                                sentService: nil)
        let json = String(decoding: try CompanionJSON.encoder.encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""sent_service":null"#), json)
    }

    func test_unsentRepostKeySet() throws {
        let message = CompanionMessage(guid: "g-1", rowid: 7, threadGUID: "any;-;+15555550100", fromMe: false,
                                       senderHandle: "+15555550100", sentAt: Date(timeIntervalSince1970: 0),
                                       kind: .text, text: nil, replyToGUID: nil, attachmentCount: 0,
                                       service: "SMS", unsent: true)
        let object = try JSONSerialization.jsonObject(with: CompanionJSON.encoder.encode(message)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["guid", "rowid", "thread_guid", "from_me", "sender_handle", "sent_at", "kind",
                                          "text", "reply_to_guid", "attachment_count", "service", "unsent"])
        XCTAssertEqual(object["unsent"] as? Bool, true)
        XCTAssertEqual(object["service"] as? String, "SMS")
    }

    func test_ordinaryMessageOmitsUnsent() throws {
        let message = CompanionMessage(guid: "g-2", rowid: 8, threadGUID: "any;-;+15555550100", fromMe: true,
                                       senderHandle: nil, sentAt: Date(timeIntervalSince1970: 0), kind: .text,
                                       text: "hi", replyToGUID: nil, attachmentCount: 0, service: "iMessage",
                                       unsent: nil)
        let object = try JSONSerialization.jsonObject(with: CompanionJSON.encoder.encode(message)) as! [String: Any]
        XCTAssertNil(object["unsent"])
        XCTAssertEqual(object["service"] as? String, "iMessage")
    }

    /// READY only comes from the preflight source; if a dispatch run ever printed it, the decision stays uncertain.
    func test_readyDuringDispatchIsNeverSent() {
        XCTAssertEqual(CompanionSendDecision.decide(script: .ready, rows: [], text: "hi", deadlinePassed: true),
                       .final(.ambiguous, .scriptUncertain, anchorGUID: nil))
    }
}
