import CryptoKit
import Foundation

/// Posts the agent's status every 15 minutes, and at once when it changes (contract `POST /imsg/status`).
public actor StatusReporter {
    public static let interval: TimeInterval = 900

    private let configURL: URL
    private let tokens: any CompanionTokenStoring
    private let makeUplink: @Sendable (URL, String) -> any StatusUplinking
    private let snapshot: @Sendable () async -> AgentStatus

    private var lastPosted: AgentStatus?
    private var lastPostAt: Date?
    private var backoff: TimeInterval = 0
    private var retryAt: Date?
    /// Set by a 401 or another rejection; cleared when the URL or token changes.
    private var stopKey: String?

    public init(configURL: URL, tokens: any CompanionTokenStoring,
                makeUplink: @escaping @Sendable (URL, String) -> any StatusUplinking,
                snapshot: @escaping @Sendable () async -> AgentStatus) {
        self.configURL = configURL; self.tokens = tokens; self.makeUplink = makeUplink; self.snapshot = snapshot
    }

    public func tick(now: Date) async {
        let config = CompanionConfig.load(from: configURL)
        guard let url = config.uplinkURL, let token = tokens.read() else { return }
        let key = SHA256.hash(data: Data("\(url.absoluteString)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let stopKey {
            if stopKey == key { return }
            self.stopKey = nil
        }
        if let retryAt, retryAt > now { return }
        let status = await snapshot()
        let changed = lastPosted?.withoutTimestamps != status.withoutTimestamps
        let due = lastPostAt.map { now.timeIntervalSince($0) >= Self.interval } ?? true
        guard changed || due else { return }
        do throws(UplinkError) {
            try await makeUplink(url, token).postStatus(status)
            lastPosted = status
            lastPostAt = now
            backoff = 0
            retryAt = nil
        } catch {
            switch error {
            case .retryable, .badResponse:
                let tunables = config.tunables
                backoff = backoff == 0 ? tunables.backoffInitialSeconds : min(backoff * 2, tunables.backoffMaxSeconds)
                retryAt = now + backoff
            case .unauthorized, .rejected, .notHTTPS:
                stopKey = key
            }
        }
    }
}
