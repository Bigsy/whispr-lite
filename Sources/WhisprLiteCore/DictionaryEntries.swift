import Foundation

/// The editable dictionary, kept sorted in memory and saved as one entry per line.
/// Exact duplicates are redundant; case variants and conflicting aliases are preserved.
public struct DictionaryEntries: Equatable, Sendable {
    public private(set) var entries: [String]
    public var text: String { entries.joined(separator: "\n") }

    public init(_ text: String) {
        entries = Self.ordered(Self.parse(text))
    }

    public mutating func add(_ text: String) {
        entries = Self.ordered(entries + Self.parse(text))
    }

    public mutating func replace(_ entry: String, with text: String) {
        guard entries.contains(entry) else { return }
        entries = Self.ordered(entries.filter { $0 != entry } + Self.parse(text))
    }

    public mutating func remove(_ entry: String) {
        entries.removeAll { $0 == entry }
    }

    /// Existing malformed entries remain visible so they can be repaired or removed.
    /// New aliases must have a spoken phrase and a written form.
    public static func validationMessage(for text: String) -> String? {
        let entries = parse(text)
        guard !entries.isEmpty else { return "Enter a word or phrase." }
        for entry in entries where entry.contains(">") {
            let parts = entry.components(separatedBy: entry.contains("=>") ? "=>" : ">")
            if entry.filter({ $0 == ">" }).count != 1 || parts.count != 2 || parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "For a correction, enter spoken phrase > Written phrase."
            }
        }
        return nil
    }

    private static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { line -> [String] in
            let arrows = line.filter { $0 == ">" }.count
            // A single alias may intentionally contain commas in either phrase.
            // Legacy lines with several aliases, as well as plain vocabulary lists,
            // can be separated on commas. Keep ambiguous malformed lines intact.
            let parts = line.components(separatedBy: ",")
            let split = arrows == 0 || (arrows > 1 && parts.allSatisfy { part in
                part.filter { $0 == ">" }.count <= 1
            })
            return split ? parts : [line]
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    private static func ordered(_ entries: [String]) -> [String] {
        Set(entries).sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }
}
