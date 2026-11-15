import Foundation

// The checks a fetched send must pass before anything else happens (agent design §5.4). The fork's
// approval-length rule is dropped: expiry covers it.
public enum CompanionSendRules {
    public static let maxCharacters = 4000

    /// nil when the send may go ahead. Checked in this order: expiry, hash, text, cap. `dailyCap` is the number of
    /// dispatch attempts allowed in any rolling 24 h (`tunables.daily_send_cap`).
    public static func refusal(for send: ApprovedSend, now: Date, attemptsLast24h: Int, dailyCap: Int) -> SendDetail? {
        if now >= send.expiresAt { return .expired }
        if CompanionTextHash.of(send.text) != send.textSHA256 { return .hashMismatch }
        if !textAllowed(send.text) { return .textRules }
        if attemptsLast24h >= dailyCap { return .dailyCap }
        return nil
    }

    static func textAllowed(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxCharacters else {
            return false
        }
        let allowedControls: Set<Unicode.Scalar> = ["\t", "\n", "\r"]
        return !text.unicodeScalars.contains { $0.properties.generalCategory == .control && !allowedControls.contains($0) }
    }
}
