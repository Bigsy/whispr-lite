import Foundation

struct LaunchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LaunchCommand {
    case run(showSettings: Bool)
    case smokeTest
    case permissionStatus

    static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first else { return .run(showSettings: false) }
        guard arguments.count == 1 else {
            throw LaunchFailure(message: "\(command) takes no arguments")
        }
        switch command {
        case "--settings": return .run(showSettings: true)
        case "--smoke-test": return .smokeTest
        case "--permission-status": return .permissionStatus
        default: throw LaunchFailure(message: "Unknown launch option")
        }
    }
}
