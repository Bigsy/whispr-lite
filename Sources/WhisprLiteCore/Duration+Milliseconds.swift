public extension Duration {
    var milliseconds: Double {
        let value = components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}
