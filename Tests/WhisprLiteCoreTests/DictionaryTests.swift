import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct DictionaryTests {
    @Test func sharedPythonAndSwiftCases() throws {
        struct Case: Decodable {
            let id: String
            let dictionary: String
            let vocabulary: String
            let input: String
            let output: String
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cases = try JSONDecoder().decode([Case].self,
            from: Data(contentsOf: root.appendingPathComponent("bench/dictionary-cases.json")))
        for item in cases {
            let corrections = DictionaryCorrections(item.dictionary)
            #expect(corrections.vocabulary == item.vocabulary, "\(item.id) vocabulary")
            #expect(corrections.apply(to: item.input) == item.output, "\(item.id) output")
        }
    }

    @Test func explicitSpellingCorrectsOnlyWholeAliases() {
        let dictionary = DictionaryCorrections("Parakeet\ndochler => Doccla\nmap vee => mapv")
        #expect(dictionary.vocabulary == "Parakeet\nDoccla\nmapv")
        #expect(dictionary.apply(to: "DOCHLER, dochler's map vee. The doctor called; dochlers stayed.")
                == "Doccla, Doccla's mapv. The doctor called; dochlers stayed.")
        #expect(dictionary.apply(to: "édochler dochleré _dochler dochler_ 2dochler dochler2")
                == "édochler dochleré _dochler dochler_ 2dochler dochler2")
    }

    @Test func literalUnicodeAndOverlappingPhrasesUseOnePass() {
        let dictionary = DictionaryCorrections("c plus plus => C++\nfoo => bar\nbar => baz\nfoo bar => Pair\nresume => résumé\na.b => $value")
        #expect(dictionary.apply(to: "foo bar, foo, bar, c plus plus, resume, a.b, axb 😀")
                == "Pair, bar, baz, C++, résumé, $value, axb 😀")
    }

    @Test func spokenPhraseConverterPreservesChosenCaseAndWordBoundaries() {
        let dictionary = DictionaryCorrections("happy fire > hapi fhir\ndochler > Doccla")
        #expect(dictionary.apply(to: "Happy Fire, HAPPY FIRE and Dochler; happy fireworks.")
                == "hapi fhir, hapi fhir and Doccla; happy fireworks.")
        #expect(dictionary.vocabulary == "hapi fhir\nDoccla")
    }

    @Test func plainEntriesEmptyAndConflictingAliasesAreConservative() {
        #expect(DictionaryCorrections("Doccla\nGemma").apply(to: "Dochler") == "Dochler")
        #expect(DictionaryCorrections("").apply(to: "") == "")
        let dictionary = DictionaryCorrections("alias => First\nALIAS => Second\n => Empty\nbroken =>\na => b => c")
        #expect(dictionary.apply(to: "alias ALIAS broken a") == "alias ALIAS broken a")
    }
}
