// Isolated on-device Foundation Models bridge for the aggregate cleanup benchmark.
// JSON lines remain in pipes; this process never writes prompts or responses to disk.
import Foundation
import FoundationModels

@main struct AppleCleanupBenchmark {
    static func main() async {
        guard SystemLanguageModel.default.isAvailable else {
            write(["error": "model_unavailable"])
            return
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let instructions = request["instructions"] as? String,
                  let transcript = request["transcript"] as? String,
                  let limit = request["limit"] as? Int else {
                write(["error": "invalid_request"])
                continue
            }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(sampling: .greedy, temperature: 0,
                                                maximumResponseTokens: limit)
                let start = ContinuousClock.now
                let response = try await session.respond(to: transcript, options: options)
                let duration = start.duration(to: .now).components
                let milliseconds = Double(duration.seconds) * 1000
                    + Double(duration.attoseconds) / 1_000_000_000_000_000
                write(["content": response.content, "elapsed_ms": milliseconds])
            } catch {
                write(["error": "generation_failed"])
            }
        }
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
