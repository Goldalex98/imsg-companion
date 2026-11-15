import XCTest
@testable import CompanionCore

final class StatusReporterTests: XCTestCase {
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa")
            .save(to: configURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func sample(paused: Bool = false, lastUplink: Date? = nil) -> AgentStatus {
        AgentStatus(deviceID: "mac-0000aaaa", agentVersion: "abc1234",
                    permissions: .init(fullDiskAccess: .granted, automationMessages: .unknown, contacts: .denied),
                    paused: paused, sendsEnabled: false, lastUplinkAt: lastUplink, lastError: nil,
                    lastUpdate: .none, bumpPendingSince: nil, ciRedSince: nil, watcherRestarts: 0, forkRunning: false)
    }

    private func reporter(_ uplink: RecordingStatusUplink, _ current: StatusBox) -> StatusReporter {
        StatusReporter(configURL: configURL, tokens: FakeTokens("t"), makeUplink: { _, _ in uplink },
                       snapshot: { current.value })
    }

    func test_postsEveryFifteenMinutes() async {
        let uplink = RecordingStatusUplink(), current = StatusBox(sample())
        let r = reporter(uplink, current)
        await r.tick(now: t0)
        await r.tick(now: t0 + 899)
        XCTAssertEqual(uplink.posted.count, 1)
        await r.tick(now: t0 + 900)
        XCTAssertEqual(uplink.posted.count, 2)
    }

    func test_postsAtOnceOnAChange() async {
        let uplink = RecordingStatusUplink(), current = StatusBox(sample())
        let r = reporter(uplink, current)
        await r.tick(now: t0)
        current.value = sample(lastUplink: t0 + 10)
        await r.tick(now: t0 + 20)
        XCTAssertEqual(uplink.posted.count, 1, "a newer timestamp alone is not a change")
        current.value = sample(paused: true, lastUplink: t0 + 10)
        await r.tick(now: t0 + 30)
        XCTAssertEqual(uplink.posted.count, 2)
        XCTAssertEqual(uplink.posted.last?.paused, true)
    }

    func test_failedPostBacksOffThenRetries() async {
        let uplink = RecordingStatusUplink(), current = StatusBox(sample())
        uplink.errors = [.retryable(503)]
        let r = reporter(uplink, current)
        await r.tick(now: t0)
        await r.tick(now: t0 + 1)
        XCTAssertEqual(uplink.posted.count, 1, "waits out the backoff")
        await r.tick(now: t0 + 5)
        XCTAssertEqual(uplink.posted.count, 2)
    }

    func test_unauthorizedStops() async {
        let uplink = RecordingStatusUplink(), current = StatusBox(sample())
        uplink.errors = [.unauthorized]
        let r = reporter(uplink, current)
        await r.tick(now: t0)
        current.value = sample(paused: true)
        await r.tick(now: t0 + 1000)
        XCTAssertEqual(uplink.posted.count, 1, "stopped until the token or URL changes")
    }

    // The contract's key list, exactly: a strict mirror fails on any extra or missing key.
    func test_jsonHasOnlyTheContractKeys() throws {
        let data = try CompanionJSON.encoder.encode(sample())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["device_id", "agent_version", "imsgcore_version", "permissions", "paused",
                                          "sends_enabled", "last_uplink_at", "last_error", "last_update",
                                          "bump_pending_since", "ci_red_since", "watcher_restarts", "fork_running"])
        XCTAssertEqual(Set((object["permissions"] as? [String: Any])?.keys ?? [:].keys),
                       ["full_disk_access", "automation_messages", "contacts"])
        XCTAssertEqual(Set((object["last_update"] as? [String: Any])?.keys ?? [:].keys), ["result", "version", "at"])
        XCTAssertEqual(object["imsgcore_version"] as? String, "0.21.0")
        XCTAssertTrue(object["last_uplink_at"] is NSNull, "nulls are sent, not left out")
        XCTAssertEqual((object["permissions"] as? [String: String])?["contacts"], "denied")
        XCTAssertEqual((object["last_update"] as? [String: Any])?["result"] as? String, "none")
    }

    func test_automationFromScriptResults() {
        XCTAssertEqual(Permissions.automation(from: nil), .unknown)
        XCTAssertEqual(Permissions.automation(from: .notSubmitted(code: -1743)), .denied)
        XCTAssertEqual(Permissions.automation(from: .ready), .granted)
        XCTAssertEqual(Permissions.automation(from: .submitted), .granted)
        XCTAssertEqual(Permissions.automation(from: .failedToStart), .unknown)
    }

    func test_fullDiskAccessOfAMissingFileIsUnknown() {
        XCTAssertEqual(Permissions.fullDiskAccess(path: folder.appendingPathComponent("missing.db").path), .unknown)
    }

    // Review Focus 4: Contacts denied → names nil, the uplink still goes, and the status says denied.
    func test_contactsDeniedStillUplinks() async throws {
        let f = try CompanionFixture()
        let chat = try f.addChat(guid: "iMessage;-;direct", style: 45, displayName: nil, handles: ["+15550100001"])
        try f.addMessage(chats: [chat], text: "m", handle: "+15550100001")
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            cursor: 0).save(to: configURL)
        let resolver = ContactsNameResolver(store: DeniedContacts())
        let uplink = RecordingUplink()
        let service = CompanionService(databasePath: f.url.path, configURL: configURL, tokens: FakeTokens("t"),
                                       names: resolver, makeUplink: { _, _ in uplink })
        _ = await service.tick()
        XCTAssertEqual(uplink.batches.count, 1)
        XCTAssertEqual(uplink.batches[0].threads.first?.participants.map(\.name), [nil])
        XCTAssertEqual(resolver.permission, .denied)
    }
}

private struct DeniedContacts: ContactSource {
    func authorization() -> PermissionState { .denied }
    func allHandles() -> [(name: String, handles: [String])] { [("Test Person", ["+15550100001"])] }
}

final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentStatus
    init(_ value: AgentStatus) { stored = value }
    var value: AgentStatus {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class RecordingStatusUplink: StatusUplinking, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentStatus] = []
    nonisolated(unsafe) var errors: [UplinkError] = []
    var posted: [AgentStatus] { lock.withLock { recorded } }
    func postStatus(_ status: AgentStatus) async throws(UplinkError) {
        let error: UplinkError? = lock.withLock {
            recorded.append(status)
            return errors.isEmpty ? nil : errors.removeFirst()
        }
        if let error { throw error }
    }
}
