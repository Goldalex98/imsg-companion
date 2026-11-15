import XCTest
@testable import CompanionCore

final class UpdaterTests: XCTestCase {
    private let installed = "aaaaaaaaaaaa1111111111111111111111111111"
    private let head = "bbbbbbbbbbbb2222222222222222222222222222"
    private var folder: URL!
    private var paths: UpdaterPaths!
    private var runner: FakeCommands!
    private var github: FakeGitHub!
    private var clock: TestClock!
    private var health: HealthBox!
    private var sendBusy: PauseFlag!
    private var reachable: PauseFlag!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        paths = UpdaterPaths(support: folder, app: folder.appendingPathComponent("Applications/ImsgCompanion.app"),
                             agentPlist: folder.appendingPathComponent("LaunchAgents/agent.plist"))
        for url in [paths.src, paths.app] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        runner = FakeCommands()
        github = FakeGitHub(head: head, green: [head])
        clock = TestClock(Date(timeIntervalSince1970: 1_794_000_000))
        health = HealthBox()
        sendBusy = PauseFlag(false)
        reachable = PauseFlag(true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func updater(installedVersion: String? = nil) -> Updater {
        let clock = clock!, health = health!, runner = runner!, busy = sendBusy!, reachable = reachable!
        let version = installedVersion ?? String(installed.prefix(12))
        return Updater(paths: paths, label: "agent.label", uid: 501, runner: runner, github: github,
                       homechatReachable: { reachable.value }, sendInProgress: { busy.value },
                       installedVersion: { version }, health: { health.mark(after: runner) },
                       now: { clock.now }, sleep: { clock.advance($0) })
    }

    private var src: String { paths.src.path }
    private var app: String { paths.app.path }
    private var previous: String { paths.previous.path }
    private var built: String { paths.build.appendingPathComponent("ImsgCompanion.app").path }

    private var fetchAndBuild: [String] {
        ["git -C \(src) fetch --quiet origin main", "git -C \(src) checkout --quiet --detach \(head)",
         "swift test --package-path \(src)", "build-app.sh --out \(paths.build.path)"]
    }

    private var swap: [String] {
        ["launchctl bootout gui/501/agent.label", "launchctl print gui/501/agent.label", "rm -rf \(previous)",
         "mkdir -p \(paths.previous.deletingLastPathComponent().path)", "mv \(app) \(previous)", "ditto \(built) \(app)",
         "launchctl bootstrap gui/501 \(paths.agentPlist.path)"]
    }

    private var rollback: [String] {
        ["launchctl bootout gui/501/agent.label", "launchctl print gui/501/agent.label", "rm -rf \(app)",
         "mv \(previous) \(app)", "launchctl bootstrap gui/501 \(paths.agentPlist.path)"]
    }

    func test_headAlreadyInstalledDoesNothing() async {
        let result = await updater(installedVersion: String(head.prefix(12))).runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertEqual(runner.calls, [])
    }

    func test_redHeadMarksCIRedThenClears() async {
        github.green = []
        var result = await updater().runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(UpdateState.load(from: paths.state).ciRedSince, clock.now)
        let since = clock.now
        clock.advance(86_400)
        _ = await updater().runOnce()
        XCTAssertEqual(UpdateState.load(from: paths.state).ciRedSince, since, "kept from the first red night")
        github.green = [head]
        health.version = String(head.prefix(12))
        result = await updater().runOnce()
        XCTAssertEqual(result.result, .installed)
        XCTAssertNil(UpdateState.load(from: paths.state).ciRedSince)
    }

    func test_greenNewHeadInstallsAfterHealthMark() async {
        health.version = String(head.prefix(12))
        let result = await updater().runOnce()
        XCTAssertEqual(result, AgentStatus.LastUpdate(result: .installed, version: String(head.prefix(12)), at: clock.now))
        XCTAssertEqual(runner.calls, fetchAndBuild + swap)
        XCTAssertEqual(UpdateState.load(from: paths.state).lastResult?.result, .installed)
    }

    func test_noHealthMarkRollsBackAndSkipsThatCommitAfter() async {
        let start = clock.now
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .rolledBack)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 180)
        XCTAssertEqual(runner.calls, fetchAndBuild + swap + rollback)
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [head])
        runner.calls = []
        let next = await updater().runOnce()
        XCTAssertEqual(next.result, .none)
        XCTAssertEqual(runner.calls, [], "the same commit isn't retried")
    }

    // An offline night must never roll back a good build: nothing is touched.
    func test_homeChatUnreachableTouchesNothing() async {
        reachable.value = false
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertEqual(runner.calls, [])
    }

    func test_sendInProgressDefersTheSwap() async {
        sendBusy.value = true
        let start = clock.now
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 600)
        XCTAssertEqual(runner.calls, fetchAndBuild, "built, never swapped")
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [], "deferred, not failed")
    }

    func test_missingAppIsRestoredFromPrevious() async throws {
        try FileManager.default.removeItem(at: paths.app)
        try FileManager.default.createDirectory(at: paths.previous, withIntermediateDirectories: true)
        _ = await updater(installedVersion: String(head.prefix(12))).runOnce()
        XCTAssertEqual(Array(runner.calls.prefix(2)),
                       ["mv \(previous) \(app)", "launchctl bootstrap gui/501 \(paths.agentPlist.path)"])
    }

    func test_failingTestsRecordTheCommitAndSwapNothing() async {
        runner.failing = ["swift test"]
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(runner.calls, Array(fetchAndBuild.prefix(3)))
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [head])
    }

    func test_firstRunClonesTheRepo() async throws {
        try FileManager.default.removeItem(at: paths.src)
        health.version = String(head.prefix(12))
        _ = await updater().runOnce()
        XCTAssertEqual(runner.calls.first, "git clone --quiet https://github.com/Goldalex98/imsg-companion.git \(src)")
    }

    func test_overlappingRunIsSkipped() async throws {
        let held = try XCTUnwrap(UpdaterLock(folder: folder))
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertEqual(runner.calls, [])
        _ = held
    }

    func test_bumpPendingSinceFromDependabot() async {
        let opened = clock.now - 4 * 86_400
        github.dependabotSince = opened
        _ = await updater(installedVersion: String(head.prefix(12))).runOnce()
        XCTAssertEqual(UpdateState.load(from: paths.state).bumpPendingSince, opened)
    }

    func test_githubParsing() throws {
        XCTAssertEqual(try GitHubUpdateSource.parseHead(Data(#"{"sha": "abc", "commit": {}}"#.utf8)), "abc")
        let runs = #"{"workflow_runs": [{"conclusion": "success", "created_at": "2026-11-15T10:00:00Z"},"#
            + #" {"conclusion": "failure", "created_at": "2026-11-15T09:00:00Z"}]}"#
        XCTAssertTrue(try GitHubUpdateSource.parseGreen(Data(runs.utf8)))
        let red = #"{"workflow_runs": [{"conclusion": null, "created_at": "2026-11-15T11:00:00Z"},"#
            + #" {"conclusion": "success", "created_at": "2026-11-15T10:00:00Z"}]}"#
        XCTAssertFalse(try GitHubUpdateSource.parseGreen(Data(red.utf8)), "the newest run decides")
        XCTAssertFalse(try GitHubUpdateSource.parseGreen(Data(#"{"workflow_runs": []}"#.utf8)))
        let pulls = #"[{"user": {"login": "someone"}, "created_at": "2026-11-01T00:00:00Z"},"#
            + #" {"user": {"login": "dependabot[bot]"}, "created_at": "2026-11-10T00:00:00Z"},"#
            + #" {"user": {"login": "dependabot[bot]"}, "created_at": "2026-11-12T00:00:00Z"}]"#
        XCTAssertEqual(try GitHubUpdateSource.parseOldestDependabot(Data(pulls.utf8)),
                       ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
    }
}

final class FakeCommands: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    nonisolated(unsafe) var failing: [String] = []
    var calls: [String] {
        get { lock.withLock { recorded } }
        set { lock.withLock { recorded = newValue } }
    }
    func run(_ executable: String, _ arguments: [String], cwd: String?) async -> CommandResult {
        let line = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        lock.withLock { recorded.append(line) }
        if failing.contains(where: { line.hasPrefix($0) }) { return CommandResult(status: 1, output: "") }
        // `launchctl print` failing means the job has left launchd.
        if line.hasPrefix("launchctl print") { return CommandResult(status: 113, output: "") }
        return CommandResult(status: 0, output: "")
    }
}

final class FakeGitHub: UpdateSource, @unchecked Sendable {
    nonisolated(unsafe) var head: String
    nonisolated(unsafe) var green: Set<String>
    nonisolated(unsafe) var dependabotSince: Date?
    init(head: String, green: Set<String>) { self.head = head; self.green = green }
    func headSHA() async throws -> String { head }
    func isGreen(sha: String) async throws -> Bool { green.contains(sha) }
    func oldestOpenDependabotPR() async throws -> Date? { dependabotSince }
}

/// The new build's health mark appears only after the agent was started again.
final class HealthBox: @unchecked Sendable {
    nonisolated(unsafe) var version: String?
    func mark(after runner: FakeCommands) -> HealthMark? {
        guard let version, runner.calls.contains(where: { $0.hasPrefix("launchctl bootstrap") }) else { return nil }
        return HealthMark(version: version, startedAt: .distantFuture, readOKAt: .distantFuture,
                          homechatOKAt: .distantFuture)
    }
}
