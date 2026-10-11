import Foundation

/// A content-free explanation for explicit development and synthetic check commands.
struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
