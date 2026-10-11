import Foundation
import Testing
@testable import WhisprLiteCore

private final class Responses: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: (Int, Data)] = [:]
    private var requests: [String: [Data]] = [:]
    func set(_ url: URL, status: Int = 200, body: Data) { lock.lock(); values[url.absoluteString] = (status, body); lock.unlock() }
    func get(_ url: URL) -> (Int, Data)? { lock.lock(); defer { lock.unlock() }; return values[url.absoluteString] }
    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        var body = request.httpBody ?? Data()
        // URLSession presents POST bodies as streams to a custom URLProtocol.
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < 64 * 1024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard !body.isEmpty else { return }
        lock.lock(); requests[url.absoluteString, default: []].append(body); lock.unlock()
    }
    func bodies(_ url: URL) -> [Data] { lock.lock(); defer { lock.unlock() }; return requests[url.absoluteString] ?? [] }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Responses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.responses.record(request)
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
        let overflow = try JSONSerialization.data(withJSONObject: ["tokens": Array(repeating: 1, count: 3969)])
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: overflow)
        await #expect(throws: AppError.contextLimit) { try await cleanup.clean("hello") }
        // A short transcript needs only its proportional output room beside a large prompt.
        let large = try JSONSerialization.data(withJSONObject: ["tokens": Array(repeating: 1, count: 3585)])
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: large)
        let chat = endpoint.url.appendingPathComponent("v1/chat/completions")
        FixtureProtocol.responses.set(chat, body: Data("{\"choices\":[{\"message\":{\"content\":\"Hello.\"},\"finish_reason\":\"stop\"}]}".utf8))
        #expect(try await cleanup.clean("hello") == "Hello.")
        let last = try #require(FixtureProtocol.responses.bodies(chat).last)
        let sent = try #require(JSONSerialization.jsonObject(with: last) as? [String: Any])
        #expect(sent["max_tokens"] as? Int == 128)
    }
    @Test func preparedFramingSkipsPerDictationTokenizerRoundTrips() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        let tokenizer = endpoint.url.appendingPathComponent("tokenize")
        let chat = endpoint.url.appendingPathComponent("v1/chat/completions")
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("apply-template"), body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        FixtureProtocol.responses.set(tokenizer, body: Data("{\"tokens\":[2,3,4]}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("completion"), body: Data("{\"tokens_predicted\":1,\"truncated\":false}".utf8))
        FixtureProtocol.responses.set(chat, body: Data("{\"choices\":[{\"message\":{\"content\":\"Hello.\"},\"finish_reason\":\"stop\"}]}".utf8))
        try await cleanup.preparePrefix()
        #expect(FixtureProtocol.responses.bodies(tokenizer).count == 2)
        #expect(try await cleanup.clean("hello") == "Hello.")
        #expect(FixtureProtocol.responses.bodies(tokenizer).count == 2)
        // A transcript too long for the byte bound falls back to the exact check.
        #expect(try await cleanup.clean(String(repeating: "x", count: 4000)) == "Hello.")
        #expect(FixtureProtocol.responses.bodies(tokenizer).count == 3)
    }
    @Test func readinessRejectsHealthyServiceWithWrongModel() async throws {
        let (endpoint, http) = try fixture()
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("health"), body: Data("{}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/models"), body: Data("{\"data\":[{\"id\":\"different-model\"}]}".utf8))
        await #expect(throws: AppError.notReady) { try await http.cleanupReadiness(endpoint) }
    }
    @Test func prefixPreparationIncludesBOSAndDiscardsSpeculativeOutput() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        let template = endpoint.url.appendingPathComponent("apply-template")
        let tokenizer = endpoint.url.appendingPathComponent("tokenize")
        let prefill = endpoint.url.appendingPathComponent("completion")
        FixtureProtocol.responses.set(template, body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        FixtureProtocol.responses.set(tokenizer, body: Data("{\"tokens\":[2,3,4]}".utf8))
        FixtureProtocol.responses.set(prefill, body: Data("{\"tokens_predicted\":1,\"truncated\":false,\"content\":\"Discard this\"}".utf8))
        try await cleanup.preparePrefix()
        let tokenBodies = FixtureProtocol.responses.bodies(tokenizer)
        #expect(tokenBodies.count == 2)
        for data in tokenBodies {
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["add_special"] as? Bool == true)
        }
        let data = try #require(FixtureProtocol.responses.bodies(prefill).last)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["prompt"] as? [Int] == [2, 3, 4])
        #expect(body["n_predict"] as? Int == 0)
        #expect(body["cache_prompt"] as? Bool == true)
        #expect(FixtureProtocol.responses.bodies(endpoint.url.appendingPathComponent("v1/chat/completions")).isEmpty)
        FixtureProtocol.responses.set(prefill, body: Data("{\"tokens_predicted\":2,\"truncated\":false}".utf8))
        await #expect(throws: AppError.cleanup) { try await cleanup.preparePrefix() }
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
        await #expect(throws: AppError.notReady) { try await http.health(endpoint) }
        let url = endpoint.url.appendingPathComponent("oversized")
        FixtureProtocol.responses.set(url, body: Data(repeating: 65, count: 100))
        await #expect(throws: HTTPFailure.tooLarge) { try await http.send(URLRequest(url: url), limit: 10) }
    }
    @Test func cleanupStatusFailureKeepsItsOwnDiagnosis() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("apply-template"), body: Data("{\"prompt\":\"Synthetic template\"}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("tokenize"), body: Data("{\"tokens\":[1,2,3]}".utf8))
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/chat/completions"), status: 500, body: Data("{}".utf8))
        await #expect(throws: AppError.cleanup) { try await cleanup.clean("synthetic words") }
        let backend = HTTPASRBackend(endpoint: endpoint, http: http)
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("health"), body: Data("{}".utf8))
        try await backend.prepare()
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent("v1/audio/transcriptions"), status: 500, body: Data("{}".utf8))
        await #expect(throws: AppError.inference) { try await backend.transcribe(PCM16k([0.1])) }
    }
}
