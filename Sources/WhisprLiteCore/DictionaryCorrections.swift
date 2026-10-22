import Foundation

/// Plain entries remain model vocabulary. Explicit aliases are literal, whole-phrase
/// replacements, compiled once when settings prepare the cleanup adapter. The model sees
/// each alias's written form and, after all written words, its spoken phrase, as OpenWhispr
/// does for snippet triggers: a conversion only fires if cleanup leaves the phrase intact.
public struct DictionaryCorrections: Sendable {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    let vocabulary: String
    private let expression: NSRegularExpression?
    private let replacements: [String: String]

    public init(_ dictionary: String) {
        guard dictionary.contains(">") else {
            vocabulary = dictionary; replacements = [:]; expression = nil
            return
        }
        var words: [String] = []
        var spoken: [String] = []
        var aliases: [String: String] = [:]
        var conflicts = Set<String>()
        for line in dictionary.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: line.contains("=>") ? "=>" : ">")
            guard parts.count == 2 else { words.append(line); continue }
            let alias = parts[0].trimmingCharacters(in: .whitespaces)
            let spelling = parts[1].trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty, !spelling.isEmpty else { words.append(line); continue }
            let key = Self.key(alias)
            if let previous = aliases[key], previous != spelling { conflicts.insert(key) }
            aliases[key] = spelling
            words.append(spelling); spoken.append(alias)
        }
        for key in conflicts { aliases.removeValue(forKey: key) }
        var listed = Set(words.map(Self.key))
        for alias in spoken where aliases[Self.key(alias)] != nil && listed.insert(Self.key(alias)).inserted {
            words.append(alias)
        }
        vocabulary = words.joined(separator: "\n")
        replacements = aliases
        let alternatives = aliases.keys.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        expression = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])",
            options: .caseInsensitive)
    }

    public func apply(to text: String) -> String {
        guard let expression else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let result = NSMutableString(string: text)
        // Replace backwards using original matches: aliases never cascade into other rules.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let spelling = replacements[Self.key(String(text[range]))] else { continue }
            result.replaceCharacters(in: match.range, with: spelling)
        }
        return result as String
    }

    private static func key(_ value: String) -> String {
        value.lowercased(with: posixLocale)
    }
}
