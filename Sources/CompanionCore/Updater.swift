import Foundation

// The nightly updater (agent design §5.6): build main's head only when its CI run is green and it differs from the
// installed build, swap it in while no send is in progress, and roll back unless the new agent proves itself.

public struct UpdaterPaths: Sendable {
    public let support: URL
    public let src: URL
    public let app: URL
    public let previous: URL
    /// The new app, copied next to the installed one so the swap is two renames on one volume.
    public let staging: URL
    public let build: URL
    public let state: URL
    public let agentPlist: URL

    public init(support: URL, app: URL, agentPlist: URL) {
        self.support = support; self.app = app; self.agentPlist = agentPlist
        src = support.appendingPathComponent("src", isDirectory: true)
        previous = support.appendingPathComponent("previous/ImsgCompanion.app", isDirectory: true)
        staging = app.deletingLastPathComponent().appendingPathComponent(".ImsgCompanion-staging.app", isDirectory: true)
        build = support.appendingPathComponent("build", isDirectory: true)
        state = support.appendingPathComponent("update-state.json")
    }
}

/// `<support>/update-state.json`; the agent's status reads it.
public struct UpdateState: Codable, Equatable, Sendable {
    public var failedCommits: [String] = []
    public var lastResult: AgentStatus.LastUpdate?
    public var ciRedSince: Date?
    public var bumpPendingSince: Date?

    public init() {}

    public static func load(from url: URL) -> UpdateState {
        (try? Data(contentsOf: url)).flatMap { try? CompanionJSON.decoder.decode(UpdateState.self, from: $0) }
            ?? UpdateState()
    }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? CompanionJSON.encoder.encode(self).write(to: url, options: .atomic)
    }

    enum CodingKeys: String, CodingKey {
        case failedCommits = "failed_commits", lastResult = "last_result", ciRedSince = "ci_red_since",
             bumpPendingSince = "bump_pending_since"
    }
}

public protocol UpdateSource: Sendable {
    func headSHA() async throws -> String
    /// The newest `ci.yml` run for this commit on `main` succeeded.
    func isGreen(sha: String) async throws -> Bool
    func oldestOpenDependabotPR() async throws -> Date?
}

/// Held for one run; a second run that can't take it does nothing.
public final class UpdaterLock {
    private let descriptor: Int32

    public init?(folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appendingPathComponent(".updater.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public actor Updater {
    public static let repository = "https://github.com/Goldalex98/imsg-companion.git"
    static let healthWait: TimeInterval = 180
    static let sendWait: TimeInterval = 600

    private let paths: UpdaterPaths
    private let label: String
    private let uid: UInt32
    private let runner: any CommandRunning
    private let github: any UpdateSource
    private let homechatReachable: @Sendable () async -> Bool
    private let sendInProgress: @Sendable () -> Bool
    private let isPaused: @Sendable () -> Bool
    private let installedVersion: @Sendable () -> String?
    private let health: @Sendable () -> HealthMark?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(paths: UpdaterPaths, label: String, uid: UInt32, runner: any CommandRunning, github: any UpdateSource,
                homechatReachable: @escaping @Sendable () async -> Bool, sendInProgress: @escaping @Sendable () -> Bool,
                isPaused: @escaping @Sendable () -> Bool = { false },
                installedVersion: @escaping @Sendable () -> String?, health: @escaping @Sendable () -> HealthMark?,
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.paths = paths; self.label = label; self.uid = uid; self.runner = runner; self.github = github
        self.homechatReachable = homechatReachable; self.sendInProgress = sendInProgress; self.isPaused = isPaused
        self.installedVersion = installedVersion; self.health = health; self.now = now; self.sleep = sleep
    }

    private var job: String { "gui/\(uid)/\(label)" }

    /// One night's run. `none` means nothing was installed (up to date, red, offline, deferred or skipped).
    public func runOnce() async -> AgentStatus.LastUpdate {
        guard let lock = UpdaterLock(folder: paths.support) else { return .none }
        defer { withExtendedLifetime(lock) {} }
        var state = UpdateState.load(from: paths.state)
        defer { state.save(to: paths.state) }

        let files = FileManager.default
        if !files.fileExists(atPath: paths.app.path), files.fileExists(atPath: paths.previous.path) {
            _ = await runner.run("/bin/mv", [paths.previous.path, paths.app.path])
            _ = await runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", paths.agentPlist.path])
        } else if !(await run("/bin/launchctl", ["print", job])) {
            // Left stopped (an updater killed mid-swap, say): never leave the agent down.
            await startAgent()
        }
        if let since = try? await github.oldestOpenDependabotPR() { state.bumpPendingSince = since } else {
            state.bumpPendingSince = nil
        }

        guard let head = try? await github.headSHA(), head.count >= 12 else { return .none }
        let version = String(head.prefix(12))
        if let installed = installedVersion(), head.hasPrefix(installed) {
            state.ciRedSince = nil
            return .none
        }
        if state.failedCommits.contains(head) { return .none }
        guard let green = try? await github.isGreen(sha: head) else { return .none }
        guard green else {
            state.ciRedSince = state.ciRedSince ?? now()
            return .none
        }
        state.ciRedSince = nil
        guard await homechatReachable() else { return .none }
        // A paused agent reads nothing, so it could never pass the health check: try again another night.
        guard !isPaused() else { return .none }

        // Build the commit that was checked green, in a clone that's only ours.
        if !files.fileExists(atPath: paths.src.path) {
            guard await runner.run("/usr/bin/git", ["clone", "--quiet", Self.repository, paths.src.path]).succeeded
            else { return .none }
        }
        guard await runner.run("/usr/bin/git", ["-C", paths.src.path, "fetch", "--quiet", "origin", "main"]).succeeded,
              await runner.run("/usr/bin/git", ["-C", paths.src.path, "checkout", "--quiet", "--detach", head]).succeeded
        else { return .none }
        guard await runner.run("/usr/bin/swift", ["test", "--package-path", paths.src.path]).succeeded,
              await runner.run(paths.src.appendingPathComponent("scripts/build-app.sh").path,
                               ["--out", paths.build.path], cwd: paths.src.path).succeeded
        else { return finish(&state, .failed, version: version, failed: head) }

        // Never swap under a send: wait for the ledger to have nothing in progress, or try again tomorrow.
        var waited: TimeInterval = 0
        while sendInProgress() {
            guard waited < Self.sendWait else { return .none }
            await sleep(10)
            waited += 10
        }
        // Paused while building: the new agent couldn't pass the health check, so try another night.
        guard !isPaused() else { return .none }

        // Stage the new app beside the old one first, so the agent stops only for two renames. A failure from here
        // on is the Mac's, not the commit's: nothing is added to `failedCommits` until the new app has run.
        _ = await runner.run("/bin/rm", ["-rf", paths.staging.path])
        guard await run("/usr/bin/ditto", [paths.build.appendingPathComponent("ImsgCompanion.app").path,
                                           paths.staging.path])
        else { return finish(&state, .failed, version: version, failed: nil) }

        await stopAgent()
        _ = await runner.run("/bin/rm", ["-rf", paths.previous.path])
        _ = await runner.run("/bin/mkdir", ["-p", paths.previous.deletingLastPathComponent().path])
        guard await run("/bin/mv", [paths.app.path, paths.previous.path]) else {
            await startAgent()
            return finish(&state, .failed, version: version, failed: nil)
        }
        guard await run("/bin/mv", [paths.staging.path, paths.app.path]) else {
            _ = await runner.run("/bin/mv", [paths.previous.path, paths.app.path])
            await startAgent()
            return finish(&state, .failed, version: version, failed: nil)
        }
        let started = now()
        await startAgent()

        // The new agent must read chat.db and reach HomeChat within 3 minutes.
        var elapsed: TimeInterval = 0
        while elapsed < Self.healthWait {
            if let mark = health(), mark.version == version, mark.startedAt >= started, mark.readOKAt != nil,
               mark.homechatOKAt != nil {
                return finish(&state, .installed, version: version, failed: nil)
            }
            await sleep(5)
            elapsed += 5
        }
        // Roll back without ever deleting the only app: the failed one moves aside, and is deleted once the old
        // one is back. If the old one can't come back, the new one stays rather than leaving none.
        // A pause during the wait, not the build, explains a missing mark: roll back, but retry the commit later.
        let condemned = isPaused() ? nil : head
        await stopAgent()
        _ = await runner.run("/bin/rm", ["-rf", paths.staging.path])
        // If the failed app can't move aside, `mv previous app` would nest the old app inside it: keep it running.
        guard await run("/bin/mv", [paths.app.path, paths.staging.path]) else {
            await startAgent()
            return finish(&state, .failed, version: version, failed: condemned)
        }
        if await run("/bin/mv", [paths.previous.path, paths.app.path]) {
            await startAgent()
            _ = await runner.run("/bin/rm", ["-rf", paths.staging.path])
        } else {
            _ = await runner.run("/bin/mv", [paths.staging.path, paths.app.path])
            await startAgent()
        }
        return finish(&state, .rolledBack, version: version, failed: condemned)
    }

    private func run(_ executable: String, _ arguments: [String]) async -> Bool {
        await runner.run(executable, arguments).succeeded
    }

    private func startAgent() async {
        _ = await runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", paths.agentPlist.path])
    }

    /// bootout, not a kill: KeepAlive would restart the old binary mid-swap. The agent finishes a send in flight.
    private func stopAgent() async {
        _ = await runner.run("/bin/launchctl", ["bootout", job])
        for _ in 0..<130 {
            if !(await runner.run("/bin/launchctl", ["print", job])).succeeded { return }
            await sleep(1)
        }
    }

    private func finish(_ state: inout UpdateState, _ result: AgentStatus.LastUpdate.Result, version: String,
                        failed: String?) -> AgentStatus.LastUpdate {
        if let failed, !state.failedCommits.contains(failed) { state.failedCommits.append(failed) }
        let update = AgentStatus.LastUpdate(result: result, version: version, at: now())
        state.lastResult = update
        return update
    }
}

/// The public GitHub API, unauthenticated (no secret on the Mac).
public struct GitHubUpdateSource: UpdateSource {
    static let api = "https://api.github.com/repos/Goldalex98/imsg-companion"
    private let session: URLSession

    public init(session: URLSession = .companionEphemeral) { self.session = session }

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: Self.api + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    public func headSHA() async throws -> String { try Self.parseHead(await get("/commits/main")) }

    public func isGreen(sha: String) async throws -> Bool {
        try Self.parseGreen(await get("/actions/workflows/ci.yml/runs?branch=main&head_sha=\(sha)&per_page=20"), sha: sha)
    }

    public func oldestOpenDependabotPR() async throws -> Date? {
        try Self.parseOldestDependabot(await get("/pulls?state=open&per_page=100"))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func parseHead(_ data: Data) throws -> String {
        struct Commit: Decodable { let sha: String }
        return try decoder.decode(Commit.self, from: data).sha
    }

    /// Only main's own runs of this commit count: a push, or the dispatch the automerge job starts. A pull request
    /// run is never main's, even from a fork whose branch is called main.
    static func parseGreen(_ data: Data, sha: String) throws -> Bool {
        struct Runs: Decodable {
            struct Run: Decodable {
                let conclusion: String?
                let created_at: Date
                let event: String
                let head_branch: String?
                let head_sha: String
            }
            let workflow_runs: [Run]
        }
        let newest = try decoder.decode(Runs.self, from: data).workflow_runs
            .filter { ["push", "workflow_dispatch"].contains($0.event) && $0.head_branch == "main" && $0.head_sha == sha }
            .max { $0.created_at < $1.created_at }
        return newest?.conclusion == "success"
    }

    static func parseOldestDependabot(_ data: Data) throws -> Date? {
        struct Pull: Decodable {
            struct User: Decodable { let login: String }
            let user: User
            let created_at: Date
        }
        return try decoder.decode([Pull].self, from: data).filter { $0.user.login == "dependabot[bot]" }
            .map(\.created_at).min()
    }
}
