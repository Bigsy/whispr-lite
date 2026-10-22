import Foundation

/// Word comparison for early-chunk reuse and synthetic benchmark parity.
public enum WordTokens {
    static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)

    static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    public static func words(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { normalize(String(text[$0])) }
        }
    }
}
