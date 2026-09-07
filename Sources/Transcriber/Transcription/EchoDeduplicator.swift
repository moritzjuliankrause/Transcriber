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
        return isEcho(meText: me.text, meStart: me.start, themText: them.text, themStart: them.start, themEnd: them.end)
    }

    /// Text-level echo test usable for partial (in-progress) text as well. `themEnd` is nil
    /// while the far-end segment is still open.
    static func isEcho(meText: String, meStart: Double, themText: String, themStart: Double, themEnd: Double?) -> Bool {
        // Echo arrives a bit later than the original; allow generous slack.
        guard meStart >= themStart - 1.5 else { return false }
        if let themEnd, meStart > themEnd + 1.5 { return false }
        let a = tokens(meText), b = tokens(themText)
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
