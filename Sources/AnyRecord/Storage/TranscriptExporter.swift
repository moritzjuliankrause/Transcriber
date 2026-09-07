import Foundation

enum TranscriptExporter {
    struct JSONDocument: Codable {
        let session: SessionMeta
        let entries: [TranscriptEntry]
    }

    static func timestamp(_ t: Double) -> String {
        let total = Int(t.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func markdown(meta: SessionMeta, entries: [TranscriptEntry]) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        var out = "# \(meta.title.isEmpty ? "Transcript" : meta.title)\n\n"
        out += "- **Date:** \(df.string(from: meta.startedAt))\n"
        if let end = meta.endedAt {
            out += "- **Duration:** \(timestamp(end.timeIntervalSince(meta.startedAt)))\n"
        }
        out += "- **Status:** \(meta.status.rawValue)\n"
        let speakers = Array(Set(entries.map(\.speaker))).sorted()
        if !speakers.isEmpty { out += "- **Speakers:** \(speakers.joined(separator: ", "))\n" }
        out += "\n---\n\n"

        // Merge consecutive entries by the same speaker into one paragraph.
        var lastSpeaker = ""
        var paragraph: [String] = []
        var paragraphStart = 0.0
        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "**\(lastSpeaker)** _[\(timestamp(paragraphStart))]_  \n\(paragraph.joined(separator: " "))\n\n"
            paragraph = []
        }
        for e in entries {
            if e.speaker != lastSpeaker || (e.start - paragraphStart) > 90 {
                flush()
                lastSpeaker = e.speaker
                paragraphStart = e.start
            }
            paragraph.append(e.text)
        }
        flush()
        return out
    }

    static func srt(entries: [TranscriptEntry]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t - t.rounded(.down)) * 1000)
            let total = Int(t)
            return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
        }
        var out = ""
        for (i, e) in entries.enumerated() {
            out += "\(i + 1)\n\(stamp(e.start)) --> \(stamp(e.end))\n\(e.speaker): \(e.text)\n\n"
        }
        return out
    }
}
