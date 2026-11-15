import XCTest

/// The agent links IMsgCore only for reading. Its send, launch, bridge, typing and contact-prompting APIs must
/// never appear in our sources (CLAUDE.md; plan Global Constraints).
final class ForbiddenAPITests: XCTestCase {
    private let forbidden = ["MessageSender", "MessagesLauncher", "IMCoreBridge", "IMsgBridgeClient", "TypingIndicator",
                             "IMsgEventTailer", "AudioMessagePreparer", "ContactResolver.create"]

    func test_noSendOrBridgeAPIs() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in forbidden {
                XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) mentions \(name)")
            }
        }
    }
}
