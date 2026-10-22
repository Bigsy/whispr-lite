import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct DictionaryTests {
    @Test func sharedWordScoringCases() throws {
        struct Case: Decodable { let input: String; let words: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cases = try JSONDecoder().decode([Case].self,
            from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/word-cases.json")))
        for item in cases { #expect(WordTokens.words(item.input) == item.words) }
    }

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
            from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/dictionary-cases.json")))
        for item in cases {
            let corrections = DictionaryCorrections(item.dictionary)
            #expect(corrections.vocabulary == item.vocabulary, "\(item.id) vocabulary")
            #expect(corrections.apply(to: item.input) == item.output, "\(item.id) output")
        }
    }

    @Test func explicitSpellingCorrectsOnlyWholeAliases() {
        let dictionary = DictionaryCorrections("Parakeet\nfabricam => Fabrikam\nmap vee => mapv")
        #expect(dictionary.vocabulary == "Parakeet\nFabrikam\nmapv\nfabricam\nmap vee")
        #expect(dictionary.apply(to: "FABRICAM, fabricam's map vee. The fabric tore; fabricams stayed.")
                == "Fabrikam, Fabrikam's mapv. The fabric tore; fabricams stayed.")
        #expect(dictionary.apply(to: "éfabricam fabricamé _fabricam fabricam_ 2fabricam fabricam2")
                == "éfabricam fabricamé _fabricam fabricam_ 2fabricam fabricam2")
    }

    @Test func literalUnicodeAndOverlappingPhrasesUseOnePass() {
        let dictionary = DictionaryCorrections("c plus plus => C++\nfoo => bar\nbar => baz\nfoo bar => Pair\nresume => résumé\na.b => $value")
        #expect(dictionary.apply(to: "foo bar, foo, bar, c plus plus, resume, a.b, axb 😀")
                == "Pair, bar, baz, C++, résumé, $value, axb 😀")
    }

    @Test func spokenPhraseConverterPreservesChosenCaseAndWordBoundaries() {
        let dictionary = DictionaryCorrections("num pie > NumPy\nfabricam > Fabrikam")
        #expect(dictionary.apply(to: "Num Pie, NUM PIE and Fabricam; num pieces.")
                == "NumPy, NumPy and Fabrikam; num pieces.")
        #expect(dictionary.vocabulary == "NumPy\nFabrikam\nnum pie\nfabricam")
    }

    @Test func plainEntriesEmptyAndConflictingAliasesAreConservative() {
        #expect(DictionaryCorrections("Fabrikam\nGemma").apply(to: "Fabricam") == "Fabricam")
        #expect(DictionaryCorrections("").apply(to: "") == "")
        let dictionary = DictionaryCorrections("alias => First\nALIAS => Second\n => Empty\nbroken =>\na => b => c")
        #expect(dictionary.apply(to: "alias ALIAS broken a") == "alias ALIAS broken a")
    }
}
