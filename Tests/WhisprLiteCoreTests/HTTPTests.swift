import Foundation
import Testing
@testable import WhisprLiteCore

private final class Responses: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: (Int, Data)] = [:]
    func set(_ url: URL, status: Int = 200, body: Data) { lock.lock(); values[url.absoluteString] = (status, body); lock.unlock() }
    func get(_ url: URL) -> (Int, Data)? { lock.lock(); defer { lock.unlock() }; return values[url.absoluteString] }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Responses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.responses.get(url),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)]) else {
            client?.urlProtocol(self, didFailWithError: AppError.inference); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite struct HTTPTests {
    func fixture() throws -> (LocalEndpoint, LocalHTTP) {
        let endpoint = try LocalEndpoint("http://127.0.0.1:\(Int.random(in: 20_000...60_000))/\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return (endpoint, LocalHTTP(session: URLSession(configuration: configuration)))
    }
    @Test func realHTTPAdaptersProcessFixtureResponsesAndRejectTruncatedCleanup() async throws {
        let (endpoint, http) = try fixture()
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("health"), body: Data("{}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/audio/transcriptions"), body: Data("{\"text\":\"hello\"}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/chat/completions"), body: Data("{\"choices\":[{\"message\":{\"content\":\"Hello.\"},\"finish_reason\":\"stop\"}]}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("apply-template"), body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: Data("{\"tokens\":[1,2,3]}".utf8))
        let backend = HTTPASRBackend(endpoint: endpoint, http: http)
        try await backend.prepare()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        #expect(try await BatchPipeline(backend: backend, cleanup: cleanup).run(PCM16k([0.1])) == "Hello.")
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/chat/completions"), body: Data("{\"choices\":[{\"message\":{\"content\":\"truncated\"},\"finish_reason\":\"length\"}]}".utf8))
        await #expect(throws: AppError.cleanup) { try await cleanup.clean("hello") }
    }
    @Test func importedFramingAndExactContextBudgetArePreserved() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt", dictionary: "Whispr Lite, Parakeet",
            inputFormat: .openWhispr, dictionaryPrefix: "\n\nSynthetic dictionary: "), http: http)
        let body = try #require(JSONSerialization.jsonObject(with: cleanup.request("hello").httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == "Synthetic prompt\n\nSynthetic dictionary: Whispr Lite, Parakeet")
        #expect(messages[1]["content"] == "<transcript>\nhello\n</transcript>\n\nOutput only the cleaned transcript.")
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("apply-template"), body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        let overflow = try JSONSerialization.data(withJSONObject: ["tokens": Array(repeating: 1, count: 3585)])
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: overflow)
        await #expect(throws: AppError.contextLimit) { try await cleanup.clean("hello") }
    }
    @Test func readinessRejectsHealthyServiceWithWrongModel() async throws {
        let (endpoint, http) = try fixture()
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("health"), body: Data("{}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/models"), body: Data("{\"data\":[{\"id\":\"different-model\"}]}".utf8))
        await #expect(throws: AppError.notReady) { try await http.cleanupReadiness(endpoint) }
    }
    @Test func explicitDictionaryAliasesApplyToCompletedCleanup() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt",
            dictionary: "dochler => Doccla", inputFormat: .openWhispr), http: http)
        let body = try #require(JSONSerialization.jsonObject(with: cleanup.request("dochler").httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == "Synthetic prompt\nCustom dictionary:\nDoccla")
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("apply-template"), body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: Data("{\"tokens\":[1,2,3]}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/chat/completions"), body: Data("{\"choices\":[{\"message\":{\"content\":\" Dochler spoke to the doctor. \"},\"finish_reason\":\"stop\"}]}".utf8))
        #expect(try await cleanup.clean("dochler spoke to the doctor") == "Doccla spoke to the doctor.")
    }
    @Test func unhealthyStatusAndOversizedBodiesFailBeforeDecode() async throws {
        let (endpoint, http) = try fixture()
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("health"), status: 503, body: Data("{}".utf8))
        await #expect(throws: AppError.inference) { try await http.health(endpoint) }
        let url = endpoint.url.appendingPathComponent("oversized")
        FixtureProtocol.responses.set(url, body: Data(repeating: 65, count: 100))
        await #expect(throws: AppError.inference) { try await http.send(URLRequest(url: url), limit: 10) }
    }
}
