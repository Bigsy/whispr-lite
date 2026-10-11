import Foundation
import Testing
@testable import WhisprLiteCore

@Suite struct ReportStatisticsTests {
    @Test func nearestRankAndMedianUseTheSameDefinitionAsPython() {
        let values = (1...10).map(Double.init)
        #expect(ReportStatistics.median(values) == 5.5)
        #expect(ReportStatistics.nearestRank(values, fraction: 0.9) == 9)
        #expect(ReportStatistics.nearestRank(values, fraction: 0.95) == 10)
        #expect(ReportStatistics.nearestRank([], fraction: 0.9) == nil)
    }

    @Test func reportsNameThePercentileMethod() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONReport.write(["schema": 1], to: file)
        let value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(value["percentile_method"] as? String == "nearest-rank")
    }
}
