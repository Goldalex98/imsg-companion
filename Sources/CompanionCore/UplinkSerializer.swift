import Foundation

/// Every `POST /imsg/messages` (the reading loop's batches and the unsend re-posts) goes through one of these, so
/// batches go up one at a time, as the contract requires.
public actor UplinkSerializer {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func post(_ batch: UplinkBatch, via uplink: any CompanionUplinking) async throws(UplinkError) -> UplinkAck {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        // Hand the turn straight to the next waiter, so a new caller can't slip in between.
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
        return try await uplink.post(batch)
    }
}
