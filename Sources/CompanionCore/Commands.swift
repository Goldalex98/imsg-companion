import Foundation

/// `imsg-companion <command>` (agent design §5.1). No command sends a message: sends come only from HomeChat,
/// through the executor, after Alex approved the exact text.
public enum Command: Equatable, Sendable {
    case run, setup(url: URL), status, pause, resume, sendsOn, sendsOff, preflight(chatRowID: Int64), promptContacts,
         update, resetCursor

    public static func parse(_ args: [String]) -> Command? {
        switch args {
        case [], ["run"]: .run
        case ["status"]: .status
        case ["pause"]: .pause
        case ["resume"]: .resume
        case ["sends", "on"]: .sendsOn
        case ["sends", "off"]: .sendsOff
        case ["prompt-contacts"]: .promptContacts
        case ["update"]: .update
        case ["reset-cursor"]: .resetCursor
        case let a where a.count == 2 && a[0] == "setup": URL(string: a[1]).map { .setup(url: $0) }
        case let a where a.count == 2 && a[0] == "preflight":
            Int64(a[1]).flatMap { $0 > 0 ? .preflight(chatRowID: $0) : nil }
        default: nil
        }
    }

    public static let usage = """
        usage: imsg-companion [run]
               imsg-companion setup <https-url>     (reads the token from stdin)
               imsg-companion status | pause | resume | sends on | sends off
               imsg-companion preflight <chat-rowid>  (checks a chat without sending)
               imsg-companion update                  (the nightly updater's run)
               imsg-companion reset-cursor            (after database_replaced: read again from the first-run window)
        """
}

/// The config edits behind the commands. Each changes only its own field, under the config lock.
public enum ConfigEdits {
    public static func setPaused(_ paused: Bool, configURL: URL) throws {
        try CompanionConfig.update(at: configURL) { $0.paused = paused }
    }

    /// After a `database_replaced` stop: forget the cursor, so reading starts again from the first-run window
    /// before the replacement, however long ago that was. HomeChat ignores rows it already holds (by guid).
    public static func resetCursor(configURL: URL) throws {
        try CompanionConfig.update(at: configURL) {
            $0.firstRunSince = $0.databaseReplacedAt.map { $0 - CompanionService.firstRunWindow }
            $0.cursor = nil
            $0.databaseReplacedAt = nil
        }
    }

    public static func setSendsEnabled(_ enabled: Bool, configURL: URL) throws {
        try CompanionConfig.update(at: configURL) { $0.sendsEnabled = enabled }
    }

    /// The fork's Settings save: https only; the token goes to the Keychain store and never into the config. An
    /// empty token with none saved is an error.
    public static func setup(url: URL, tokenInput: String, configURL: URL,
                             tokens: any CompanionTokenStoring) -> CompanionSettingsOutcome {
        CompanionConfig.saveSettings(url: url.absoluteString, token: tokenInput, configURL: configURL, tokens: tokens)
    }
}

/// `preflight <chat-rowid>` writes a request; the running agent (which holds the Automation grant) runs the
/// script's checks without sending and writes the result.
public struct PreflightFiles: Sendable {
    public struct Request: Codable, Equatable { public let chatRowID: Int64
        enum CodingKeys: String, CodingKey { case chatRowID = "chat_rowid" } }
    public struct Result: Codable, Equatable, Sendable {
        public let chatRowID: Int64
        public let result: String
        public let code: Int?
        public let at: Date
        enum CodingKeys: String, CodingKey { case chatRowID = "chat_rowid", result, code, at }
    }

    public let requestURL: URL
    public let resultURL: URL

    public init(folder: URL) {
        requestURL = folder.appendingPathComponent("preflight-request.json")
        resultURL = folder.appendingPathComponent("preflight-result.json")
    }

    public func request(chatRowID: Int64) throws {
        try FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CompanionJSON.encoder.encode(Request(chatRowID: chatRowID)).write(to: requestURL, options: .atomic)
    }

    /// Takes a pending request (removing it first, so it runs once) and writes what `run` returned.
    public func handle(now: Date, run: (Int64) async -> PreflightResult) async {
        guard let data = try? Data(contentsOf: requestURL) else { return }
        try? FileManager.default.removeItem(at: requestURL)
        guard let request = try? CompanionJSON.decoder.decode(Request.self, from: data) else { return }
        let outcome = await run(request.chatRowID)
        let result: Result = switch outcome {
        case .ready: Result(chatRowID: request.chatRowID, result: "ready", code: nil, at: now)
        case .refused(let code): Result(chatRowID: request.chatRowID, result: "refused", code: code, at: now)
        }
        try? CompanionJSON.encoder.encode(result).write(to: resultURL, options: .atomic)
    }

    public func result() -> Result? {
        (try? Data(contentsOf: resultURL)).flatMap { try? CompanionJSON.decoder.decode(Result.self, from: $0) }
    }
}

/// Builds the status body from the parts' own states. Every string in it is a fixed code or a count.
public enum StatusSnapshot {
    public static func lastError(reader: CompanionStatus, sender: CompanionSendStatus) -> String? {
        switch reader.state {
        case .stopped(let reason): return reason
        case .noDatabaseAccess: return "no_database_access"
        default: break
        }
        if case .stopped(let reason) = sender.state { return reason }
        return nil
    }

    public static func make(config: CompanionConfig, agentVersion: String, reader: CompanionStatus,
                            sender: CompanionSendStatus, permissions: AgentStatus.Permissions, remotePaused: Bool,
                            watcherRestarts: Int, forkRunning: Bool, update: UpdateState = UpdateState()) -> AgentStatus {
        AgentStatus(deviceID: config.deviceID, agentVersion: agentVersion, permissions: permissions,
                    paused: config.paused || remotePaused, sendsEnabled: config.sendsEnabled,
                    lastUplinkAt: reader.lastUplinkAt, lastError: lastError(reader: reader, sender: sender),
                    lastUpdate: update.lastResult ?? .none, bumpPendingSince: update.bumpPendingSince,
                    ciRedSince: update.ciRedSince, watcherRestarts: watcherRestarts,
                    forkRunning: forkRunning)
    }
}

/// `<support>/agent-status.json`: the running agent's own snapshot, so `status` from a terminal shows the agent's
/// permissions (a terminal's grants are its own, not the agent's).
public struct AgentStatusFile: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let at: Date
        public let status: AgentStatus
    }

    public let url: URL

    public init(folder: URL) { url = folder.appendingPathComponent("agent-status.json") }

    public func write(_ status: AgentStatus, at: Date) {
        try? CompanionJSON.encoder.encode(Entry(at: at, status: status)).write(to: url, options: .atomic)
    }

    public func read() -> Entry? {
        (try? Data(contentsOf: url)).flatMap { try? CompanionJSON.decoder.decode(Entry.self, from: $0) }
    }
}
