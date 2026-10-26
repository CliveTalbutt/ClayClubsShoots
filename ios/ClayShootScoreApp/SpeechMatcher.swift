//
//  SpeechMatcher.swift
//  ClayShootScoreApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import Foundation

/// Loose, "sounds like" word matching for speech recognition. The recogniser often
/// hears "it" for "hit", "mist" for "miss" or "Jon" for "John", so commands and
/// shooter names are matched by similar spelling or similar sound rather than exactly.
nonisolated enum SpeechMatcher {

    /// True when `heard` is the same word as `target`, or close enough in spelling
    /// or sound that the speaker almost certainly meant it.
    static func soundsLike(_ heard: String, _ target: String) -> Bool {
        matchQuality(heard, target) != nil
    }

    /// How closely `heard` matches `target`: 0 is an exact match and larger numbers
    /// are looser matches. Returns nil when the words are not alike at all.
    static func matchQuality(_ heard: String, _ target: String) -> Int? {
        let heard = normalize(heard)
        let target = normalize(target)
        guard !heard.isEmpty, !target.isEmpty else { return nil }

        if heard == target { return 0 }

        // "hits" or "hitting" for "hit", "missed" for "miss".
        if target.count >= 3, heard.hasPrefix(target) { return 1 }

        let distance = editDistance(heard, target)
        if distance <= maxDistance(forLength: target.count) { return distance }

        // Spelled differently but sounds the same, e.g. "pear" and "pair".
        if phoneticKey(heard) == phoneticKey(target) { return max(distance, 1) }

        return nil
    }

    /// True when the words in `sequence` appear consecutively in `words`, with each
    /// word matched by sound rather than exactly.
    static func containsSequence(_ words: [String], soundingLike sequence: [String]) -> Bool {
        guard !sequence.isEmpty, words.count >= sequence.count else { return false }
        for start in 0...(words.count - sequence.count) {
            let window = words[start..<(start + sequence.count)]
            if zip(window, sequence).allSatisfy({ soundsLike($0, $1) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    /// Lowercased letters only, so punctuation and capitalisation never matter.
    private static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }

    /// How many spelling differences are tolerated for a word of the given length.
    /// Short command words stay fairly strict so "hit" and "miss" are not confused.
    private static func maxDistance(forLength length: Int) -> Int {
        switch length {
        case ...4: return 1
        case ...7: return 2
        default: return 3
        }
    }

    /// Classic Levenshtein distance: the number of single-letter edits needed to
    /// turn one word into the other.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,          // deletion
                                 current[j - 1] + 1,       // insertion
                                 previous[j - 1] + cost)   // substitution
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// A Soundex-style code: the first letter followed by a digit for each group of
    /// similar-sounding consonants. Vowels are ignored, so words that sound alike
    /// produce the same key ("john" and "jon", "pair" and "pear", "clive" and "clyve").
    static func phoneticKey(_ word: String) -> String {
        var letters = Array(normalize(word))
        guard !letters.isEmpty else { return "" }

        // Common spellings that start with a different sound than their first letter.
        let prefixes: [(from: String, to: String)] = [
            ("ph", "f"), ("kn", "n"), ("gn", "n"), ("wr", "r"), ("wh", "w"), ("c", "k"), ("q", "k"), ("z", "s")
        ]
        let text = String(letters)
        for (from, to) in prefixes where text.hasPrefix(from) {
            letters = Array(to + text.dropFirst(from.count))
            break
        }

        var key = String(letters[0])
        var lastCode: Character? = code(for: letters[0])

        for letter in letters.dropFirst() {
            let c = code(for: letter)
            // Vowels and h/w/y separate sounds but add nothing themselves.
            if c == nil {
                lastCode = nil
                continue
            }
            if c != lastCode, let c {
                key.append(c)
            }
            lastCode = c
        }
        return key
    }

    private static func code(for letter: Character) -> Character? {
        switch letter {
        case "b", "f", "p", "v": return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t": return "3"
        case "l": return "4"
        case "m", "n": return "5"
        case "r": return "6"
        default: return nil
        }
    }
}
