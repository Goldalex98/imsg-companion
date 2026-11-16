import Foundation

// Local, non-secret settings. The token lives in the Keychain, never here.
public struct CompanionConfig: Codable, Sendable, Equatable {
    public var uplinkURL: URL?
    public var deviceID: String
    public var paused: Bool
    /// The highest chat.db ROWID HomeChat has accepted; nil until the first batch is accepted.
    public var cursor: Int64?
    /// Phase 3: fetch and send approved replies. Off until Alex turns it on; files from before phase 3 load as off.
    public var sendsEnabled: Bool
    /// Settings that were constants in the fork, so a change is a config edit, not a rebuild.
    public var tunables: Tunables
    /// When the database's ROWIDs were first seen below the cursor (a restore or replacement). Reading stays
    /// stopped until `reset-cursor` clears it, even if new rows later climb past the old cursor.
    public var databaseReplacedAt: Date?
    /// Set by `reset-cursor`: the first run reads from here (the first-run window before the replacement) instead
    /// of counting back from now. Cleared once a cursor is saved.
    public var firstRunSince: Date?
    /// The deletion reconcile's last attempt, whatever its outcome: at most one a day.
    public var lastPresentAttemptAt: Date?
    /// Its last run that HomeChat answered 2xx throughout. Informational.
    public var lastPresentAt: Date?
    /// After a 401: a digest of the URL and token it was refused with. No run until either changes.
    public var presentAuthBlockedFor: String?

    public static let supportFolder = "imsg-companion"

    public struct Tunables: Codable, Sendable, Equatable {
        public var dailySendCap: Int
        public var backoffInitialSeconds: TimeInterval
        public var backoffMaxSeconds: TimeInterval

        public init(dailySendCap: Int = 30, backoffInitialSeconds: TimeInterval = 5, backoffMaxSeconds: TimeInterval = 300) {
            self.dailySendCap = dailySendCap; self.backoffInitialSeconds = backoffInitialSeconds
            self.backoffMaxSeconds = backoffMaxSeconds
        }

        enum CodingKeys: String, CodingKey {
            case dailySendCap = "daily_send_cap", backoffInitialSeconds = "backoff_initial_seconds",
                 backoffMaxSeconds = "backoff_max_seconds"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Tunables()
            dailySendCap = try c.decodeIfPresent(Int.self, forKey: .dailySendCap) ?? defaults.dailySendCap
            backoffInitialSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .backoffInitialSeconds)
                ?? defaults.backoffInitialSeconds
            backoffMaxSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .backoffMaxSeconds)
                ?? defaults.backoffMaxSeconds
        }
    }

    public init(uplinkURL: URL? = nil, deviceID: String = CompanionConfig.newDeviceID(), paused: Bool = false,
                cursor: Int64? = nil, sendsEnabled: Bool = false, tunables: Tunables = Tunables()) {
        self.uplinkURL = uplinkURL; self.deviceID = deviceID; self.paused = paused; self.cursor = cursor
        self.sendsEnabled = sendsEnabled; self.tunables = tunables
    }

    enum CodingKeys: String, CodingKey {
        case uplinkURL = "uplink_url", deviceID = "device_id", paused, cursor, sendsEnabled = "sends_enabled", tunables,
             databaseReplacedAt = "database_replaced_at", firstRunSince = "first_run_since",
             lastPresentAttemptAt = "last_present_attempt_at", lastPresentAt = "last_present_at",
             presentAuthBlockedFor = "present_auth_blocked_for"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uplinkURL = try c.decodeIfPresent(URL.self, forKey: .uplinkURL)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        paused = try c.decode(Bool.self, forKey: .paused)
        cursor = try c.decodeIfPresent(Int64.self, forKey: .cursor)
        sendsEnabled = try c.decodeIfPresent(Bool.self, forKey: .sendsEnabled) ?? false
        tunables = try c.decodeIfPresent(Tunables.self, forKey: .tunables) ?? Tunables()
        databaseReplacedAt = try c.decodeIfPresent(Date.self, forKey: .databaseReplacedAt)
        firstRunSince = try c.decodeIfPresent(Date.self, forKey: .firstRunSince)
        lastPresentAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastPresentAttemptAt)
        lastPresentAt = try c.decodeIfPresent(Date.self, forKey: .lastPresentAt)
        presentAuthBlockedFor = try c.decodeIfPresent(String.self, forKey: .presentAuthBlockedFor)
    }

    public static func newDeviceID() -> String {
        "mac-" + (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func defaultURL(supportFolder: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportFolder, isDirectory: true)
            .appendingPathComponent("companion.json")
    }

    /// A missing or corrupt file gives a fresh config (new device ID, not paused, no cursor).
    public static func load(from url: URL) -> CompanionConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(CompanionConfig.self, from: data),
              config.deviceID.range(of: "^mac-[0-9a-f]{8}$", options: .regularExpression) != nil
        else { return CompanionConfig() }
        return config
    }

    /// Atomic, mode 0600.
    public func save(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = folder.appendingPathComponent(".companion-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(self),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public extension CompanionConfig {
    /// Load, change and save under an exclusive lock on a file beside the config, so the running agent and a command
    /// never overwrite each other's change (a cursor advance against a `pause`, say).
    static func update(at url: URL, _ change: (inout CompanionConfig) -> Void) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.appendingPathComponent(".companion.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        var config = load(from: url)
        change(&config)
        try config.save(to: url)
    }
}

/// What a Settings save did, for the status section to show.
public struct CompanionSettingsOutcome: Equatable, Sendable {
    /// The saved address's host; nil when the address wasn't saved.
    public var host: String?
    /// The config's device ID; nil when the address wasn't saved.
    public var deviceID: String?
    public var tokenSaved: Bool
    /// Shown in red. nil means the uplink has an address and a readable token.
    public var error: String?
}

public extension CompanionConfig {
    static let tokenNeededMessage = "Address saved. Paste the uplink token too: none is saved yet."
    static let tokenUnreadableMessage = "The token was written but can't be read back from the Keychain. Paste it again."

    /// The Settings section's Save. `url` must be https with a host. An empty `token` keeps the saved one; with
    /// none saved, the address is still saved and the outcome says a token is needed. The token is read back
    /// after a write, so a write that didn't stick is reported instead of showing as saved.
    static func saveSettings(url: String, token: String?, configURL: URL,
                             tokens: CompanionTokenStoring) -> CompanionSettingsOutcome {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), parsed.scheme?.lowercased() == "https", let host = parsed.host,
              !host.isEmpty else {
            return CompanionSettingsOutcome(host: nil, deviceID: nil, tokenSaved: tokens.read() != nil,
                                            error: "Enter an https:// address.")
        }
        var config = CompanionConfig.load(from: configURL)
        do {
            try CompanionConfig.update(at: configURL) { $0.uplinkURL = parsed; config = $0 }
        } catch {
            return CompanionSettingsOutcome(host: nil, deviceID: nil, tokenSaved: tokens.read() != nil,
                                            error: "Couldn't save the settings file.")
        }
        var outcome = CompanionSettingsOutcome(host: host, deviceID: config.deviceID, tokenSaved: false, error: nil)
        let entered = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !entered.isEmpty, !tokens.write(entered) {
            outcome.tokenSaved = tokens.read() != nil
            outcome.error = "Couldn't save the token to the Keychain."
            return outcome
        }
        outcome.tokenSaved = tokens.read() != nil
        if !outcome.tokenSaved { outcome.error = entered.isEmpty ? tokenNeededMessage : tokenUnreadableMessage }
        return outcome
    }
}
