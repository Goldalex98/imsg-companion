import Foundation

/// Canonical form of a Messages handle. It feeds `participants_fingerprint`, which HomeChat stores and
/// compares, so its output must never change (pinned by `HandleNormalizerTests`).
public enum HandleNormalizer {
    private static let phoneCharacters: Set<Character> = ["+", "(", ")", "-", " ", "."]

    public static func normalize(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("@") { return lowered }
        let phoneLike = lowered.allSatisfy { $0.isNumber || phoneCharacters.contains($0) }
        guard phoneLike else { return lowered }
        return lowered.filter { $0.isNumber || $0 == "+" }
    }
}
