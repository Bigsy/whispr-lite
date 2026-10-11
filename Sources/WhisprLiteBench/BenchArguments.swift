import Foundation

struct BenchFailure: LocalizedError {
    let message: String
    let exitCode: Int32
    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
    var errorDescription: String? { message }
}

struct BenchArguments {
    let mode: String
    let positional: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init(_ values: [String]) throws {
        guard let mode = values.first else {
            throw BenchFailure("Specify a benchmark mode; see DEVELOPMENT.md.", exitCode: 2)
        }
        let count: Int
        let valued: Set<String>
        let switches: Set<String>
        switch mode {
        case "--cleanup-prefill-check", "--dictionary-check", "--candidate-check":
            count = 0; valued = []; switches = []
        case "--vad-trim-prototype":
            count = 4; valued = ["--repetitions", "--vad-threshold"]; switches = ["--allow-model-downloads"]
        case "--streaming-prototype":
            count = 3; valued = ["--repetitions"]; switches = ["--record-partials"]
        case "--streaming-check":
            count = 3; valued = []; switches = []
        case "--parakeet-check":
            count = 3; valued = ["--model", "--repetitions"]; switches = ["--allow-model-downloads"]
        default:
            throw BenchFailure("Unknown benchmark mode; see DEVELOPMENT.md.", exitCode: 2)
        }
        guard values.count >= count + 1 else {
            throw BenchFailure("Missing \(mode) path argument; see DEVELOPMENT.md.", exitCode: 2)
        }
        guard values[1..<(count + 1)].allSatisfy({ !$0.hasPrefix("--") }) else {
            throw BenchFailure("Missing \(mode) path argument; see DEVELOPMENT.md.", exitCode: 2)
        }
        self.mode = mode
        positional = Array(values[1..<(count + 1)])
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = count + 1
        while index < values.count {
            let option = values[index]
            if switches.contains(option), flags.insert(option).inserted {
                index += 1
            } else if valued.contains(option), options[option] == nil,
                      index + 1 < values.count, !values[index + 1].hasPrefix("--") {
                options[option] = values[index + 1]
                index += 2
            } else {
                throw BenchFailure("Unknown, duplicate or incomplete \(mode) option.", exitCode: 2)
            }
        }
        self.options = options
        self.flags = flags
    }

    func path(_ index: Int, directory: Bool = false) -> URL {
        URL(fileURLWithPath: positional[index], isDirectory: directory)
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func string(_ option: String) -> String? { options[option] }

    func int(_ option: String, default fallback: Int) throws -> Int {
        guard let value = options[option] else { return fallback }
        guard let parsed = Int(value) else {
            throw BenchFailure("Invalid integer for \(option)", exitCode: 2)
        }
        return parsed
    }

    func float(_ option: String, default fallback: Float) throws -> Float {
        guard let value = options[option] else { return fallback }
        guard let parsed = Float(value), parsed.isFinite else {
            throw BenchFailure("Invalid number for \(option)", exitCode: 2)
        }
        return parsed
    }
}
