import XCTest
@testable import CompanionCore

final class CommandsTests: XCTestCase {
    private var folder: URL!
    private var configURL: URL { folder.appendingPathComponent("companion.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID().uuidString)")
        try CompanionConfig(uplinkURL: URL(string: "https://uplink-test.invalid"), deviceID: "mac-0000aaaa",
                            paused: false, cursor: 42, sendsEnabled: false).save(to: configURL)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var config: CompanionConfig { CompanionConfig.load(from: configURL) }

    func test_parse() {
        XCTAssertEqual(Command.parse(["sends", "on"]), .sendsOn)
        XCTAssertEqual(Command.parse(["sends", "off"]), .sendsOff)
        XCTAssertEqual(Command.parse([]), .run)
        XCTAssertEqual(Command.parse(["run"]), .run)
        XCTAssertEqual(Command.parse(["pause"]), .pause)
        XCTAssertEqual(Command.parse(["resume"]), .resume)
        XCTAssertEqual(Command.parse(["status"]), .status)
        XCTAssertEqual(Command.parse(["update"]), .update)
        XCTAssertEqual(Command.parse(["prompt-contacts"]), .promptContacts)
        XCTAssertEqual(Command.parse(["preflight", "17"]), .preflight(chatRowID: 17))
        XCTAssertEqual(Command.parse(["setup", "https://uplink-test.invalid"]),
                       .setup(url: URL(string: "https://uplink-test.invalid")!))
        XCTAssertNil(Command.parse(["sends"]))
        XCTAssertNil(Command.parse(["sends", "maybe"]))
        XCTAssertNil(Command.parse(["preflight", "x"]))
        XCTAssertNil(Command.parse(["preflight", "0"]))
        XCTAssertNil(Command.parse(["setup"]))
        XCTAssertNil(Command.parse(["send"]), "no command sends a message")
    }

    func test_pauseLeavesSendsAlone() throws {
        try ConfigEdits.setSendsEnabled(true, configURL: configURL)
        try ConfigEdits.setPaused(true, configURL: configURL)
        XCTAssertTrue(config.paused)
        XCTAssertTrue(config.sendsEnabled)
        try ConfigEdits.setPaused(false, configURL: configURL)
        XCTAssertFalse(config.paused)
        XCTAssertTrue(config.sendsEnabled)
    }

    func test_sendsOnWritesOnlySendsEnabled() throws {
        let before = config
        try ConfigEdits.setSendsEnabled(true, configURL: configURL)
        var expected = before
        expected.sendsEnabled = true
        XCTAssertEqual(config, expected)
    }

    func test_setupSavesTokenOnlyInTheStore() throws {
        let tokens = FakeTokens(nil)
        let outcome = ConfigEdits.setup(url: URL(string: "https://other-test.invalid")!, tokenInput: "secret-token\n",
                                        configURL: configURL, tokens: tokens)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(tokens.read(), "secret-token")
        XCTAssertEqual(config.uplinkURL?.host, "other-test.invalid")
        XCTAssertEqual(config.cursor, 42, "the read position is kept")
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret-token"), "never written to config")
    }

    func test_setupWithEmptyTokenIsAnError() {
        let outcome = ConfigEdits.setup(url: URL(string: "https://uplink-test.invalid")!, tokenInput: "  \n",
                                        configURL: configURL, tokens: FakeTokens(nil))
        XCTAssertNotNil(outcome.error)
    }

    func test_setupRefusesHTTP() {
        let tokens = FakeTokens(nil)
        let outcome = ConfigEdits.setup(url: URL(string: "http://uplink-test.invalid")!, tokenInput: "t",
                                        configURL: configURL, tokens: tokens)
        XCTAssertNotNil(outcome.error)
        XCTAssertNil(tokens.read())
    }

    func test_configUpdateKeepsOtherFields() throws {
        try CompanionConfig.update(at: configURL) { $0.cursor = 50 }
        XCTAssertEqual(config.cursor, 50)
        XCTAssertEqual(config.deviceID, "mac-0000aaaa")
        XCTAssertEqual(config.uplinkURL?.host, "uplink-test.invalid")
    }

    // A preflight request file is consumed once and its result written.
    func test_preflightRequestConsumedOnce() async throws {
        let files = PreflightFiles(folder: folder)
        try files.request(chatRowID: 7)
        let calls = Counter()
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        await files.handle(now: now) { id in calls.add(); return id == 7 ? .refused(code: 9004) : .ready }
        await files.handle(now: now) { _ in calls.add(); return .ready }
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.requestURL.path))
        let result = try XCTUnwrap(files.result())
        XCTAssertEqual(result, PreflightFiles.Result(chatRowID: 7, result: "refused", code: 9004, at: now))
    }

    func test_agentStatusFileRoundTrips() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = AgentStatusFile(folder: folder)
        XCTAssertNil(file.read())
        let status = StatusSnapshot.make(config: config, agentVersion: "abc1234", reader: .init(state: .notConfigured),
                                         sender: .init(state: .off),
                                         permissions: .init(fullDiskAccess: .denied, automationMessages: .unknown,
                                                            contacts: .unknown),
                                         remotePaused: false, watcherRestarts: 3, forkRunning: false)
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        file.write(status, at: at)
        XCTAssertEqual(file.read(), AgentStatusFile.Entry(at: at, status: status))
    }

    func test_lastErrorComesFromFixedStates() {
        XCTAssertEqual(StatusSnapshot.lastError(reader: .init(state: .stopped("database_replaced")),
                                                sender: .init(state: .waiting)), "database_replaced")
        XCTAssertEqual(StatusSnapshot.lastError(reader: .init(state: .noDatabaseAccess), sender: .init(state: .off)),
                       "no_database_access")
        XCTAssertEqual(StatusSnapshot.lastError(reader: .init(state: .idle), sender: .init(state: .stopped("token rejected"))),
                       "token rejected")
        XCTAssertNil(StatusSnapshot.lastError(reader: .init(state: .idle), sender: .init(state: .waiting)))
    }

    func test_statusCarriesTheUpdaterResults() {
        var update = UpdateState()
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        update.lastResult = .init(result: .rolledBack, version: "bbbbbbbbbbbb", at: at)
        update.ciRedSince = at
        update.bumpPendingSince = at
        let status = StatusSnapshot.make(config: config, agentVersion: "x", reader: .init(state: .idle),
                                         sender: .init(state: .off),
                                         permissions: .init(fullDiskAccess: .granted, automationMessages: .unknown,
                                                            contacts: .unknown),
                                         remotePaused: false, watcherRestarts: 0, forkRunning: false, update: update)
        XCTAssertEqual(status.lastUpdate, update.lastResult)
        XCTAssertEqual(status.ciRedSince, at)
        XCTAssertEqual(status.bumpPendingSince, at)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
