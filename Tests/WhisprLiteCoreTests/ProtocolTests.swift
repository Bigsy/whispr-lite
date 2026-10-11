import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import WhisprLiteCore

@Suite struct ProtocolTests {
    @Test func fragmentsAndOversizeMalformedOrOldSchema() throws {
        var decoder = BrokerLineDecoder()
        let line = Data("{\"version\":1,\"type\":\"ready\",\"generation\":\"g\",\"request\":\"\",\"session\":\"\"}\n".utf8)
        #expect(try decoder.append(line.prefix(9)).isEmpty)
        #expect(try decoder.append(line.dropFirst(9)).first?.type == .ready)
        try decoder.finish()
        #expect(throws: (any Error).self) { try decoder.append(Data("nope\n".utf8)) }
        var huge = BrokerLineDecoder()
        #expect(throws: AppError.protocolViolation) { try huge.append(Data(repeating: 65, count: 8193)) }
        var unfinished = BrokerLineDecoder(); _ = try unfinished.append(Data("{".utf8))
        #expect(throws: AppError.protocolViolation) { try unfinished.finish() }
        for invalid in [
            "{\"type\":\"ready\",\"generation\":\"g\",\"request\":\"\",\"session\":\"\"}\n",
            "{\"version\":2,\"type\":\"ready\",\"generation\":\"g\",\"request\":\"\",\"session\":\"\"}\n",
            "{\"version\":1,\"type\":\"unknown\",\"generation\":\"g\",\"request\":\"\",\"session\":\"\"}\n",
            "{\"version\":1,\"type\":\"ready\",\"generation\":\"\(String(repeating: "g", count: 65))\",\"request\":\"\",\"session\":\"\"}\n"
        ] {
            var invalidDecoder = BrokerLineDecoder()
            #expect(throws: AppError.protocolViolation) { try invalidDecoder.append(Data(invalid.utf8)) }
        }
    }
}
