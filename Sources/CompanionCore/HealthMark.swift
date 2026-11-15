import Foundation

/// `<support>/health.json`: what the updater reads to decide whether a new build works (agent design §5.8).
public struct HealthMark: Codable, Equatable, Sendable {
    public var version: String
    public var startedAt: Date
    /// The last tick that read chat.db without an error.
    public var readOKAt: Date?
    /// The last 2xx from HomeChat (an accepted batch or a status post).
    public var homechatOKAt: Date?

    enum CodingKeys: String, CodingKey {
        case version, startedAt = "started_at", readOKAt = "read_ok_at", homechatOKAt = "homechat_ok_at"
    }
}

public final class HealthMarkStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var mark: HealthMark?
    private var lastUplinkSeen: Date?

    public init(folder: URL) { url = folder.appendingPathComponent("health.json") }

    /// A fresh mark for this run: nothing is proven until a tick and a 2xx happen.
    public func start(version: String, now: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try lock.withLock {
            let fresh = HealthMark(version: version, startedAt: now, readOKAt: nil, homechatOKAt: nil)
            try write(fresh)
            mark = fresh
        }
    }

    /// After each reader tick: an idle or uplinking tick read chat.db; a new `lastUplinkAt` means HomeChat took a batch.
    public func record(_ status: CompanionStatus, now: Date) {
        lock.withLock {
            guard var current = mark else { return }
            switch status.state {
            case .idle, .uplinking: current.readOKAt = now
            default: break
            }
            if let at = status.lastUplinkAt, at != lastUplinkSeen {
                lastUplinkSeen = at
                current.homechatOKAt = now
            }
            if current != mark, (try? write(current)) != nil { mark = current }
        }
    }

    public func homechatOK(now: Date) {
        lock.withLock {
            guard var current = mark else { return }
            current.homechatOKAt = now
            if (try? write(current)) != nil { mark = current }
        }
    }

    public func read() -> HealthMark? {
        (try? Data(contentsOf: url)).flatMap { try? CompanionJSON.decoder.decode(HealthMark.self, from: $0) }
    }

    private func write(_ mark: HealthMark) throws {
        try CompanionJSON.encoder.encode(mark).write(to: url, options: .atomic)
    }
}
