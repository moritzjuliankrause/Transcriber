import Foundation
import NaturalLanguage

/// Guesses the real names of remote speakers from how people address each other:
/// when someone says "…, Anna?" and the next person to speak is a remote speaker,
/// that speaker is probably Anna. Self-introductions ("I'm Anna", "hier ist Anna")
/// count extra. Guessed names are added in square brackets: "Speaker 1 [Anna]".
enum SpeakerNameGuesser {
    /// Names → votes per remote speaker label.
    typealias Votes = [String: [String: Int]]

    static func guess(entries: [TranscriptEntry], myName: String, remoteLabels: Set<String>) -> [String: String] {
        guard !remoteLabels.isEmpty else { return [:] }
        let exclude = Set((tokens(myName) + remoteLabels.flatMap(tokens)).map { $0.lowercased() })
        var votes: Votes = [:]

        for (i, e) in entries.enumerated() {
            // Self-introduction by a remote speaker.
            if remoteLabels.contains(e.speaker) {
                for name in introducedNames(in: e.text) where !exclude.contains(name.lowercased()) {
                    votes[e.speaker, default: [:]][name, default: 0] += 3
                }
            }
            // Someone addresses a name; the next *other* speaker to talk is the addressee.
            let addressed = addressedNames(in: e.text).filter { !exclude.contains($0.lowercased()) }
            guard !addressed.isEmpty else { continue }
            guard let next = entries[(i + 1)...].first(where: { $0.speaker != e.speaker && $0.start <= e.end + 15 }),
                  remoteLabels.contains(next.speaker) else { continue }
            for name in addressed { votes[next.speaker, default: [:]][name, default: 0] += 1 }
        }

        // Best name per label, each name used once, at least two votes.
        var result: [String: String] = [:]
        var taken = Set<String>()
        let ranked = votes.flatMap { label, names in names.map { (label: label, name: $0.key, votes: $0.value) } }
            .sorted { $0.votes > $1.votes }
        for candidate in ranked where candidate.votes >= 2 && result[candidate.label] == nil && !taken.contains(candidate.name) {
            result[candidate.label] = candidate.name
            taken.insert(candidate.name)
        }
        return result
    }

    /// Applies guessed names: "Speaker 1" → "Speaker 1 [Anna]".
    static func relabel(_ entries: [TranscriptEntry], names: [String: String]) -> [TranscriptEntry] {
        guard !names.isEmpty else { return entries }
        return entries.map { e in
            guard e.channel == .them, let name = names[e.speaker] else { return e }
            var copy = e
            copy.speaker = "[\(name)]"
            return copy
        }
    }

    // MARK: - Name detection

    private static let greetings: Set<String> = ["hi", "hello", "hey", "hallo", "moin", "servus", "thanks", "thank", "danke", "merci", "ciao", "bye", "tschüss", "okay", "ok", "yes", "ja", "no", "nein", "right", "genau", "so", "also", "and", "und"]

    static func tokens(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0 == "-" || $0 == "'") }.map(String.init)
    }

    /// Names in vocative position: among the first or last three words, or a capitalised
    /// word right after a greeting / right before a comma or question mark.
    static func addressedNames(in text: String) -> [String] {
        let people = Set(personalNames(in: text).map { $0.lowercased() })
        let words = tokens(text)
        guard !words.isEmpty else { return [] }
        var found: [String] = []
        let sentence = text
        for (i, w) in words.enumerated() {
            let edge = i < 3 || i >= words.count - 3
            let afterGreeting = i > 0 && greetings.contains(words[i - 1].lowercased())
            // NaturalLanguage misses some vocatives ("Hallo Anna"); a capitalised word right
            // after a greeting counts too – the two-vote rule filters out "Hallo Leute".
            let isName = people.contains(w.lowercased()) || (afterGreeting && w.first?.isUppercase == true)
            let beforePunct = sentence.range(of: "\(w)[,?!]", options: .regularExpression) != nil
            guard isName && (edge || afterGreeting || beforePunct) else { continue }
            if !found.contains(w) { found.append(w) }
        }
        return found
    }

    /// "I'm Anna", "my name is Anna", "this is Anna", "ich bin Anna", "hier ist Anna", "mein Name ist Anna".
    static func introducedNames(in text: String) -> [String] {
        let patterns = ["(?:i'm|i am|my name is|this is|it's|ich bin|hier ist|hier spricht|mein name ist|ich heiße)\\s+([\\p{Lu}][\\p{L}'-]+)"]
        var out: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) {
                    let name = String(text[r])
                    if !out.contains(name) { out.append(name) }
                }
            }
        }
        // Only keep what also looks like a person's name (avoids "ich bin sicher").
        let people = Set(personalNames(in: text).map { $0.lowercased() })
        return out.filter { people.contains($0.lowercased()) }
    }

    /// Personal names as recognised by NaturalLanguage (works for English and reasonably for German).
    static func personalNames(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                // Joined names ("Anna Schmidt") – vocatives are usually the first name.
                if let first = tokens(String(text[range])).first { names.append(first) }
            }
            return true
        }
        return names
    }
}
