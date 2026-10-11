import Foundation
import WhisprLiteCore

struct RunOptions {
    let showSettings: Bool
    let showBenchmarkWindow: Bool
}
struct BatchFlowArguments {
    let cache: URL
    let corpus: URL
    let privateDirectory: URL
    let endpoint: LocalEndpoint
    let output: URL
}

enum LaunchCommand {
    case run(RunOptions)
    case uiPreview(URL)
    case smokeTest
    case permissionStatus
    case batchFlow(BatchFlowArguments)
    case asrCheck(cache: URL, model: ParakeetModel)
    case captureFlow([String])
    case readinessReport(URL)

    static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first else {
            return .run(.init(showSettings: false, showBenchmarkWindow: false))
        }
        let values = Array(arguments.dropFirst())
        switch command {
        case "--settings", "--benchmark-window":
            let allowed: Set<String> = ["--settings", "--benchmark-window"]
            guard arguments.count == Set(arguments).count, arguments.allSatisfy(allowed.contains) else {
                throw CheckFailure("Unknown or repeated run option")
            }
            return .run(.init(showSettings: arguments.contains("--settings"),
                              showBenchmarkWindow: arguments.contains("--benchmark-window")))
        case "--ui-preview":
            guard values.count == 1, !values[0].hasPrefix("--") else {
                throw CheckFailure("--ui-preview requires an output directory")
            }
            return .uiPreview(URL(fileURLWithPath: values[0], isDirectory: true))
        case "--smoke-test":
            guard values.isEmpty else { throw CheckFailure("--smoke-test takes no arguments") }
            return .smokeTest
        case "--permission-status":
            guard values.isEmpty else { throw CheckFailure("--permission-status takes no arguments") }
            return .permissionStatus
        case "--batch-flow-check":
            guard values.count == 5, values.allSatisfy({ !$0.hasPrefix("--") }) else {
                throw CheckFailure("--batch-flow-check requires five arguments")
            }
            guard let endpoint = try? LocalEndpoint(values[3]) else {
                throw CheckFailure("--batch-flow-check requires a local HTTP cleanup address")
            }
            return .batchFlow(.init(
                cache: URL(fileURLWithPath: values[0], isDirectory: true),
                corpus: URL(fileURLWithPath: values[1], isDirectory: true),
                privateDirectory: URL(fileURLWithPath: values[2], isDirectory: true),
                endpoint: endpoint,
                output: URL(fileURLWithPath: values[4])))
        case "--asr-check":
            guard (1...2).contains(values.count), !values[0].hasPrefix("--") else {
                throw CheckFailure("--asr-check requires a model cache path and optional model")
            }
            let model: ParakeetModel
            if values.count == 2 {
                guard let selected = ParakeetModel(rawValue: values[1]) else {
                    throw CheckFailure("Unknown speech model")
                }
                model = selected
            } else { model = .unified }
            return .asrCheck(cache: URL(fileURLWithPath: values[0], isDirectory: true), model: model)
        case "--capture-flow-check":
            guard values.count == 6, values.allSatisfy({ !$0.hasPrefix("--") }),
                  let repetitions = Int(values[5]), (1...31).contains(repetitions) else {
                throw CheckFailure("--capture-flow-check requires WAV SOX DEVICE WORDS OUTPUT and 1...31 repetitions")
            }
            return .captureFlow(values)
        case "--readiness-report":
            guard values.count == 1, !values[0].hasPrefix("--") else {
                throw CheckFailure("--readiness-report requires an output path")
            }
            return .readinessReport(URL(fileURLWithPath: values[0]))
        default:
            throw CheckFailure("Unknown launch option")
        }
    }
}
