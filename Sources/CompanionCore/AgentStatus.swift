import Foundation

public enum PermissionState: String, Codable, Sendable { case granted, denied, unknown }

/// `POST /imsg/status` (contract, 2026-11-15 additions). Every key is always sent; empty values go as null.
public struct AgentStatus: Codable, Sendable, Equatable {
    public struct Permissions: Codable, Sendable, Equatable {
        public var fullDiskAccess: PermissionState
        public var automationMessages: PermissionState
        public var contacts: PermissionState
        public init(fullDiskAccess: PermissionState, automationMessages: PermissionState, contacts: PermissionState) {
            self.fullDiskAccess = fullDiskAccess; self.automationMessages = automationMessages; self.contacts = contacts
        }
        enum CodingKeys: String, CodingKey {
            case fullDiskAccess = "full_disk_access", automationMessages = "automation_messages", contacts
        }
    }

    public struct LastUpdate: Codable, Sendable, Equatable {
        public enum Result: String, Codable, Sendable { case installed, rolledBack = "rolled_back", failed, none }
        public var result: Result
        public var version: String?
        public var at: Date?
        public init(result: Result, version: String?, at: Date?) { self.result = result; self.version = version; self.at = at }
        public static let none = LastUpdate(result: .none, version: nil, at: nil)

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(result, forKey: .result)
            try c.encode(version, forKey: .version)
            try c.encode(at, forKey: .at)
        }
        enum CodingKeys: String, CodingKey { case result, version, at }
    }

    public var deviceID: String
    public var agentVersion: String
    public var imsgcoreVersion: String
    public var permissions: Permissions
    public var paused: Bool
    public var sendsEnabled: Bool
    public var lastUplinkAt: Date?
    /// Short text with no message data, such as "database_replaced".
    public var lastError: String?
    public var lastUpdate: LastUpdate
    public var bumpPendingSince: Date?
    public var ciRedSince: Date?
    public var watcherRestarts: Int
    public var forkRunning: Bool

    public init(deviceID: String, agentVersion: String, imsgcoreVersion: String = CompanionCore.imsgCoreVersion,
                permissions: Permissions, paused: Bool, sendsEnabled: Bool, lastUplinkAt: Date?, lastError: String?,
                lastUpdate: LastUpdate, bumpPendingSince: Date?, ciRedSince: Date?, watcherRestarts: Int,
                forkRunning: Bool) {
        self.deviceID = deviceID; self.agentVersion = agentVersion; self.imsgcoreVersion = imsgcoreVersion
        self.permissions = permissions; self.paused = paused; self.sendsEnabled = sendsEnabled
        self.lastUplinkAt = lastUplinkAt; self.lastError = lastError; self.lastUpdate = lastUpdate
        self.bumpPendingSince = bumpPendingSince; self.ciRedSince = ciRedSince; self.watcherRestarts = watcherRestarts
        self.forkRunning = forkRunning
    }

    /// What decides "changed": everything except the last uplink time, which moves with every batch.
    var withoutTimestamps: AgentStatus {
        var copy = self
        copy.lastUplinkAt = nil
        return copy
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(agentVersion, forKey: .agentVersion)
        try c.encode(imsgcoreVersion, forKey: .imsgcoreVersion)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(paused, forKey: .paused)
        try c.encode(sendsEnabled, forKey: .sendsEnabled)
        try c.encode(lastUplinkAt, forKey: .lastUplinkAt)
        try c.encode(lastError, forKey: .lastError)
        try c.encode(lastUpdate, forKey: .lastUpdate)
        try c.encode(bumpPendingSince, forKey: .bumpPendingSince)
        try c.encode(ciRedSince, forKey: .ciRedSince)
        try c.encode(watcherRestarts, forKey: .watcherRestarts)
        try c.encode(forkRunning, forKey: .forkRunning)
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", agentVersion = "agent_version", imsgcoreVersion = "imsgcore_version", permissions,
             paused, sendsEnabled = "sends_enabled", lastUplinkAt = "last_uplink_at", lastError = "last_error",
             lastUpdate = "last_update", bumpPendingSince = "bump_pending_since", ciRedSince = "ci_red_since",
             watcherRestarts = "watcher_restarts", forkRunning = "fork_running"
    }
}
