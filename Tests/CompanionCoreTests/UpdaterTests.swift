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
    private var paused: PauseFlag!

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
        paused = PauseFlag(false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func updater(installedVersion: String? = nil) -> Updater {
        let clock = clock!, health = health!, runner = runner!, busy = sendBusy!, reachable = reachable!, paused = paused!
        let version = installedVersion ?? String(installed.prefix(12))
        return Updater(paths: paths, label: "agent.label", uid: 501, runner: runner, github: github,
                       homechatReachable: { reachable.value }, sendInProgress: { busy.value }, isPaused: { paused.value },
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

    private var staging: String { paths.staging.path }
    private var bootstrap: String { "launchctl bootstrap gui/501 \(paths.agentPlist.path)" }
    private var stop: [String] { ["launchctl bootout gui/501/agent.label", "launchctl print gui/501/agent.label"] }

    // The new app is staged next to the old one before the agent stops, then two renames swap them in: the app
    // is never missing while a copy is in progress (final review I1).
    private var stage: [String] { ["rm -rf \(staging)", "ditto \(built) \(staging)"] }
    private var swap: [String] {
        stage + stop + ["rm -rf \(previous)", "mkdir -p \(paths.previous.deletingLastPathComponent().path)",
                        "mv \(app) \(previous)", "mv \(staging) \(app)", bootstrap]
    }

    // The failed app moves aside before the old one comes back, and is deleted only once the old one is in place.
    private var rollback: [String] {
        stop + ["rm -rf \(staging)", "mv \(app) \(staging)", "mv \(previous) \(app)", bootstrap, "rm -rf \(staging)"]
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

    func test_stagingCopyFailureLeavesTheAgentRunning() async {
        runner.failing = ["ditto"]
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(runner.calls, fetchAndBuild + stage, "the agent is never stopped")
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [], "a disk problem doesn't condemn the commit")
    }

    func test_moveAsideFailureRestartsTheOldApp() async {
        runner.failing = ["mv \(app) \(previous)"]
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(runner.calls, fetchAndBuild + stage + stop + ["rm -rf \(previous)",
                       "mkdir -p \(paths.previous.deletingLastPathComponent().path)", "mv \(app) \(previous)", bootstrap])
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [])
    }

    func test_moveInFailurePutsTheOldAppBack() async {
        runner.failing = ["mv \(staging) \(app)"]
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(Array(runner.calls.suffix(3)), ["mv \(staging) \(app)", "mv \(previous) \(app)", bootstrap])
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [])
    }

    func test_rollbackNeverDeletesTheOnlyApp() async {
        runner.failing = ["mv \(previous) \(app)"]
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .rolledBack)
        XCTAssertFalse(runner.calls.contains("rm -rf \(app)"))
        XCTAssertEqual(Array(runner.calls.suffix(3)), ["mv \(previous) \(app)", "mv \(staging) \(app)", bootstrap],
                       "the new app goes back in place rather than leaving none")
    }

    // A paused agent writes no read mark, so an update would always roll back and condemn a good commit (I4).
    func test_pausedAgentSkipsTheNight() async {
        paused.value = true
        let result = await updater().runOnce()
        XCTAssertEqual(result.result, .none)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(UpdateState.load(from: paths.state).failedCommits, [])
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
        func run(_ conclusion: String?, _ at: String, event: String = "push", branch: String = "main",
                 sha: String = "abc") -> String {
            let value = conclusion.map { "\"\($0)\"" } ?? "null"
            return #"{"conclusion": \#(value), "created_at": "\#(at)", "event": "\#(event)", "#
                + #""head_branch": "\#(branch)", "head_sha": "\#(sha)"}"#
        }
        func green(_ runs: String...) throws -> Bool {
            try GitHubUpdateSource.parseGreen(Data(#"{"workflow_runs": [\#(runs.joined(separator: ","))]}"#.utf8), sha: "abc")
        }
        XCTAssertTrue(try green(run("success", "2026-11-15T10:00:00Z"), run("failure", "2026-11-15T09:00:00Z")))
        XCTAssertFalse(try green(run(nil, "2026-11-15T11:00:00Z"), run("success", "2026-11-15T10:00:00Z")),
                       "the newest run decides")
        XCTAssertFalse(try green())
        // Main's CI after a Dependabot automerge is started by hand (workflow_dispatch).
        XCTAssertTrue(try green(run("success", "2026-11-15T10:00:00Z", event: "workflow_dispatch")))
        // Only main's own runs count: a pull request run (a fork's branch can be called main), another branch or
        // another commit never makes a sha green.
        XCTAssertFalse(try green(run("success", "2026-11-15T10:00:00Z", event: "pull_request")))
        XCTAssertFalse(try green(run("success", "2026-11-15T10:00:00Z", event: "pull_request_target")))
        XCTAssertFalse(try green(run("success", "2026-11-15T10:00:00Z", branch: "feature")))
        XCTAssertFalse(try green(run("success", "2026-11-15T10:00:00Z", sha: "def")))
        XCTAssertFalse(try green(run("failure", "2026-11-15T10:00:00Z"),
                                 run("success", "2026-11-15T11:00:00Z", event: "pull_request")),
                       "a newer pull request run doesn't outvote main's red run")
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
