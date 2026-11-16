import Foundation

struct ScriptMatcher {
    struct Match { let index: Int; let confidence: Double }
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    /// Retains punctuation, unlike splitting on punctuation characters.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = [], part = ""
        let boundaries: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        for character in text {
            part.append(character)
            if boundaries.contains(character) || part.count >= 64 {
                let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.append(value) }
                part = ""
            }
        }
        let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { result.append(value) }
        return result
    }
    static func score(_ spoken: String, _ target: String) -> Double {
        let target = Array(normalize(target))
        // Score only recent speech. Older matched phrases must not mask an ad-lib.
        let recent = Array(normalize(spoken).suffix(max(10, min(72, target.count + 8))))
        guard recent.count >= 4, target.count >= 4 else { return 0 }
        var row = Array(repeating: 0, count: target.count + 1)
        for char in recent {
            var next = row
            for j in target.indices {
                next[j + 1] = char == target[j] ? row[j] + 1 : max(row[j + 1], next[j])
            }
            row = next
        }
        let matched = row[target.count]
        guard matched >= 4 else { return 0 }
        // Require evidence from the end of the utterance, not just a generic shared prefix.
        let tail = Set(recent.suffix(5))
        guard tail.intersection(Set(target)).count >= 2 else { return 0 }
        return Double(matched) / Double(min(recent.count, target.count))
    }
    static func match(_ spoken: String, lines: [String], current: Int) -> Match? {
        guard !lines.isEmpty else { return nil }
        let current = min(max(current, 0), lines.count - 1)
        let lower = max(0, current - 1), upper = min(lines.count - 1, current + 5)
        let ranked = (lower...upper).map { ($0, score(spoken, lines[$0])) }.sorted {
            $0.1 == $1.1 ? abs($0.0 - current) < abs($1.0 - current) : $0.1 > $1.1
        }
        guard let best = ranked.first, best.1 >= 0.72 else { return nil }
        if ranked.count > 1, best.1 - ranked[1].1 < 0.12 { return nil }
        return Match(index: best.0, confidence: best.1)
    }
    static func locate(_ spoken: String, lines: [String], current: Int) -> Int? { match(spoken, lines: lines, current: current)?.index }
}
