import Foundation
import IMsgCore

/// Re-posts messages the sender unsent, as the watcher reports them (agent design §5.2, contract `messages[].unsent`).
/// Unsends are seen only while the agent runs, and pending re-posts live in memory: both accepted by the design.
public actor UnsendRelay {
    private let events: @Sendable () -> AsyncThrowingStream<Message, any Error>
    private let databasePath: String
    private let configURL: URL
    private let tokens: any CompanionTokenStoring
    private let names: any CompanionNameResolving
    private let makeUplink: @Sendable (URL, String) -> any CompanionUplinking
    private let serializer: UplinkSerializer
    private let isPaused: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let restartDelay: @Sendable (Int) async -> Void

    private var queue: [Message] = []
    private var backoff: TimeInterval = 0
    private var retryAt: Date?
    public private(set) var restarts = 0
    public var pending: Int { queue.count }

    public init(events: @escaping @Sendable () -> AsyncThrowingStream<Message, any Error>, databasePath: String,
                configURL: URL, tokens: any CompanionTokenStoring, names: any CompanionNameResolving,
                makeUplink: @escaping @Sendable (URL, String) -> any CompanionUplinking, serializer: UplinkSerializer,
                isPaused: @escaping @Sendable () async -> Bool = { false },
                now: @escaping @Sendable () -> Date = Date.init,
                restartDelay: @escaping @Sendable (Int) async -> Void = { _ in try? await Task.sleep(for: .seconds(5)) }) {
        self.events = events; self.databasePath = databasePath; self.configURL = configURL; self.tokens = tokens
        self.names = names; self.makeUplink = makeUplink; self.serializer = serializer; self.isPaused = isPaused
        self.now = now; self.restartDelay = restartDelay
    }

    /// The production event source: unsends and edits for rows that exist when the watch starts, then new rows.
    public static func watcherEvents(databasePath: String) -> @Sendable () -> AsyncThrowingStream<Message, any Error> {
        {
            do {
                let store = try MessageStore(path: databasePath)
                return MessageWatcher(store: store).stream(configuration: MessageWatcherConfiguration(includeReactions: false))
            } catch {
                return AsyncThrowingStream { $0.finish(throwing: error) }
            }
        }
    }

    /// Runs until a watch ends without an error (it was cancelled). An overflow or a database error starts a new
    /// watch after `restartDelay`; unsends in the gap are missed, as after any restart.
    public func run() async {
        while !Task.isCancelled {
            do {
                for try await message in events() where message.mutationEvent == .unsent {
                    queue.append(message)
                    await flush()
                }
                return
            } catch {
                restarts += 1
                await restartDelay(restarts)
            }
        }
    }

    /// Posts what is pending, unless paused or backing off. The run loop also calls this each tick.
    public func flush() async {
        guard !queue.isEmpty else { return }
        if let retryAt, retryAt > now() { return }
        let config = CompanionConfig.load(from: configURL)
        if config.paused { return }
        if await isPaused() { return }
        guard let url = config.uplinkURL, let token = tokens.read() else { return }
        // HomeChat holds only rows up to the saved cursor. Later rows go up through the reading loop, already unsent.
        guard let cursor = config.cursor else { queue.removeAll(); return }
        queue.removeAll { $0.rowID > cursor }
        let rows = Array(queue.prefix(CompanionService.batchLimit))
        guard !rows.isEmpty else { return }

        let threads: [Int64: CompanionThread]
        do {
            threads = try ChatQueries(path: databasePath).threads(chatRowIDs: Set(rows.map(\.chatID)))
        } catch {
            return scheduleRetry(config)
        }
        var messages: [CompanionMessage] = []
        for row in rows {
            if case .message(let message) = MessageMapper.map(row, facts: nil, thread: threads[row.chatID]),
               message.unsent == true {
                messages.append(message)
            }
        }
        let sent = Set(rows.map(\.rowID))
        guard !messages.isEmpty else { queue.removeAll { sent.contains($0.rowID) }; return }

        let guids = Set(messages.map(\.threadGUID))
        let used = threads.sorted { $0.key < $1.key }.map(\.value).filter { guids.contains($0.guid) }
        var seen = Set<String>()
        let unique = used.filter { seen.insert($0.guid).inserted }
        let handles = Array(Set(unique.flatMap { $0.participants.map(\.handle) })).sorted()
        let known = handles.isEmpty ? [:] : await names.names(for: handles)
        let named = unique.map { thread -> CompanionThread in
            var thread = thread
            thread.participants = thread.participants.map { CompanionParticipant(handle: $0.handle, name: known[$0.handle]) }
            return thread
        }
        let batch = UplinkBatch(deviceID: config.deviceID, batchID: UUID(), cursor: cursor, firstRun: false,
                                threads: named, messages: messages)
        do throws(UplinkError) {
            _ = try await serializer.post(batch, via: makeUplink(url, token))
            queue.removeAll { sent.contains($0.rowID) }
            backoff = 0
            retryAt = nil
        } catch {
            switch error {
            case .rejected:
                // HomeChat refused this exact body; sending it again can't succeed.
                queue.removeAll { sent.contains($0.rowID) }
            case .unauthorized, .notHTTPS, .retryable, .badResponse:
                scheduleRetry(config)
            }
        }
    }

    private func scheduleRetry(_ config: CompanionConfig) {
        let tunables = config.tunables
        backoff = backoff == 0 ? tunables.backoffInitialSeconds : min(backoff * 2, tunables.backoffMaxSeconds)
        retryAt = now() + backoff
    }
}
