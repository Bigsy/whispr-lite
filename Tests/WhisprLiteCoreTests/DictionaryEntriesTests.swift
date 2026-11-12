import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct DictionaryEntriesTests {
    @Test func legacyCommaListsAndMultipleAliasesBecomeSortedEntries() {
        let legacy = "dochler > Doccla, searxng, FHIR, happy fire > hapi fhir\nOpenWhispr, doccla, oth, othc, opentele, unifhir\n  , FHIR, \r\n"
        let list = DictionaryEntries(legacy)
        #expect(list.entries == ["doccla", "dochler > Doccla", "FHIR", "happy fire > hapi fhir",
                                 "opentele", "OpenWhispr", "oth", "othc", "searxng", "unifhir"])
        #expect(DictionaryEntries(list.text) == list)
        #expect(DictionaryCorrections.sorted(legacy) == list.text)
        #expect(DictionaryCorrections(list.text).apply(to: "Dochler uses happy fire.") == "Doccla uses hapi fhir.")
    }

    @Test func commaPunctuationInSingleAliasesAndCaseConflictsSurvive() {
        let original = "hello > Hello, world!\nhello comma world => Hello, World!\nfoo, bar > Foo Bar\nalias > First\nALIAS > Second\nParakeet\nparakeet"
        let list = DictionaryEntries(original)
        #expect(list.entries.count == 7)
        #expect(list.entries.contains("hello > Hello, world!"))
        #expect(list.entries.contains("foo, bar > Foo Bar"))
        #expect(DictionaryEntries(list.text) == list)
        let input = "HELLO and hello comma world. Foo, bar and ALIAS."
        #expect(DictionaryCorrections(list.text).apply(to: input) == DictionaryCorrections(original).apply(to: input))
    }

    @Test @MainActor func addEditRemoveAndReloadMaintainOrderWithoutDuplicates() throws {
        var list = DictionaryEntries("Zulu\nBeta\nAlpha")
        list.add("Gemma, Beta, Apple")
        #expect(list.entries == ["Alpha", "Apple", "Beta", "Gemma", "Zulu"])
        list.replace("Zulu", with: "fabricam > Fabrikam")
        list.remove("Alpha")
        list.add(" , \n ")
        #expect(list.entries == ["Apple", "Beta", "fabricam > Fabrikam", "Gemma"])
        list.replace("Apple", with: "Beta")
        #expect(list.entries == ["Beta", "fabricam > Fabrikam", "Gemma"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-dictionary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(directory: root)
        try store.save(store.preferences, instructions: nil, dictionary: list.text)
        let reloaded = DictionaryEntries(try SettingsStore(directory: root).dictionary())
        #expect(reloaded == list)
        #expect(DictionaryCorrections(reloaded.text).apply(to: "FABRICAM") == "Fabrikam")
    }

    @Test func malformedExistingEntriesArePreservedButNewOnesAreRejected() {
        let broken = "broken >\n> empty\na > b > c"
        #expect(DictionaryEntries(broken).entries.count == 3)
        for input in ["", "  , \n", "broken >", "> empty", "a > b > c", "a => b > c"] {
            #expect(DictionaryEntries.validationMessage(for: input) != nil)
        }
        for input in ["Gemma", "New York", "gemma, FHIR", "num pie => NumPy", "hello > Hello, world!",
                      "dochler > Doccla, FHIR, happy fire > hapi fhir"] {
            #expect(DictionaryEntries.validationMessage(for: input) == nil)
        }
    }
}
