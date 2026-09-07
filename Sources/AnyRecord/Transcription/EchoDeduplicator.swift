import Foundation

/// Text-level safety net against residual echo: a microphone entry whose text
/// closely matches a system-audio entry at (almost) the same time is an echo of
/// the far end and gets dropped.
enum EchoDeduplicator {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    /// Fraction of the shorter token list that also appears in the other one.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let sa = Set(a), sb = Set(b)
        return Double(sa.intersection(sb).count) / Double(min(sa.count, sb.count))
    }

    static func isEcho(_ me: TranscriptEntry, of them: TranscriptEntry) -> Bool {
        guard me.channel == .me, them.channel == .them else { return false }
        // Echo arrives a bit later than the original; allow generous slack.
        guard me.start >= them.start - 1.5, me.start <= them.end + 1.5 else { return false }
        let a = tokens(me.text), b = tokens(them.text)
        guard a.count >= 3, b.count >= 3 else { return false }
        return similarity(a, b) >= 0.6
    }

    /// Removes microphone entries that duplicate an overlapping system entry.
    static func dedupe(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        let them = entries.filter { $0.channel == .them }
        return entries.filter { e in
            guard e.channel == .me else { return true }
            return !them.contains { isEcho(e, of: $0) }
        }
    }
}
