import XCTest

/// The bundle and launchd files as checked in (agent design §5.1, §5.8).
final class PackagingTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: "__HOME__", with: "/Users/example")
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func test_infoPlist() throws {
        let info = try plist("Resources/Info.plist")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "io.github.goldalex98.imsg-companion")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "imsg-companion")
        XCTAssertEqual(info["CFBundleName"] as? String, "ImsgCompanion")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(info["NSContactsUsageDescription"])
        XCTAssertNotNil(info["NSAppleEventsUsageDescription"])
        XCTAssertNil(info["SUFeedURL"], "no Sparkle")
    }

    func test_entitlementsAreAppleEventsOnly() throws {
        XCTAssertEqual(try plist("Resources/ImsgCompanion.entitlements") as NSDictionary,
                       ["com.apple.security.automation.apple-events": true] as NSDictionary)
    }

    // ExitTimeOut covers a 40 s send fetch, a 35 s script and a ~22 s read-back after SIGTERM (Task 9 review).
    func test_agentPlist() throws {
        let agent = try plist("launchd/agent.plist.template")
        XCTAssertEqual(agent["Label"] as? String, "io.github.goldalex98.imsg-companion")
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(agent["KeepAlive"] as? NSDictionary, ["SuccessfulExit": false] as NSDictionary)
        XCTAssertGreaterThanOrEqual(agent["ExitTimeOut"] as? Int ?? 0, 120)
        XCTAssertEqual(agent["ProgramArguments"] as? [String],
                       ["/Users/example/Applications/ImsgCompanion.app/Contents/MacOS/imsg-companion", "run"])
    }

    func test_updaterPlist() throws {
        let updater = try plist("launchd/updater.plist.template")
        XCTAssertEqual(updater["Label"] as? String, "io.github.goldalex98.imsg-companion.updater")
        XCTAssertEqual(updater["StartCalendarInterval"] as? NSDictionary, ["Hour": 3, "Minute": 30] as NSDictionary)
        XCTAssertEqual((updater["ProgramArguments"] as? [String])?.last, "update")
        XCTAssertNil(updater["KeepAlive"])
    }
}
