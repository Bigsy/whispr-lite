enum DemoLabel {
    static let name = "DEMO"
    static func tagged(_ text: String) -> String { "\(name): \(text)" }
}
