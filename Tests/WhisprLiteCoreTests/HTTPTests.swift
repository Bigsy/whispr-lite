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
        let endpoint = try LocalEndpoint("http://127.0.0.1:11435/\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return (endpoint, LocalHTTP(session: URLSession(configuration: configuration)))
    }
    func stub(_ endpoint: LocalEndpoint, _ path: String, status: Int = 200,
              json: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: json)
        FixtureProtocol.responses.set(endpoint.url.appendingPathComponent(path), status: status, body: body)
    }
    func chatReply(_ content: String, finish: String = "stop") -> [String: Any] {
        ["choices": [["message": ["content": content], "finish_reason": finish]]]
    }
    @Test func realHTTPAdaptersProcessFixtureResponsesAndRejectTruncatedCleanup() async throws {
        let (endpoint, http) = try fixture()
        try stub(endpoint, "health", json: [:])
        try stub(endpoint, "v1/audio/transcriptions", json: ["text": "hello"])
        try stub(endpoint, "v1/chat/completions", json: chatReply("Hello."))
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": [1, 2, 3]])
        let backend = HTTPASRBackend(endpoint: endpoint, http: http)
        try await backend.prepare()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        #expect(try await BatchPipeline(backend: backend, cleanup: cleanup).run(PCM16k([0.1])) == "Hello.")
        try stub(endpoint, "v1/chat/completions", json: chatReply("truncated", finish: "length"))
        await #expect(throws: AppError.cleanup) { try await cleanup.clean("hello") }
    }
    @Test func importedFramingAndExactContextBudgetArePreserved() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt", dictionary: "Whispr Lite, Parakeet",
            inputFormat: .openWhispr, dictionaryPrefix: "\n\nSynthetic dictionary: "), http: http)
        let body = try #require(JSONSerialization.jsonObject(with: cleanup.request("hello", maxTokens: 512).httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == "Synthetic prompt\n\nSynthetic dictionary: Whispr Lite, Parakeet")
        #expect(messages[1]["content"] == "<transcript>\nhello\n</transcript>\n\nOutput only the cleaned transcript.")
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": Array(repeating: 1, count: 3969)])
        await #expect(throws: AppError.contextLimit) { try await cleanup.clean("hello") }
        // A short transcript needs only its proportional output room beside a large prompt.
        try stub(endpoint, "tokenize", json: ["tokens": Array(repeating: 1, count: 3585)])
        let chat = endpoint.url.appendingPathComponent("v1/chat/completions")
        try stub(endpoint, "v1/chat/completions", json: chatReply("Hello."))
        #expect(try await cleanup.clean("hello") == "Hello.")
        let last = try #require(FixtureProtocol.responses.bodies(chat).last)
        let sent = try #require(JSONSerialization.jsonObject(with: last) as? [String: Any])
        #expect(sent["max_tokens"] as? Int == 128)
    }
    @Test func preparedFramingSkipsPerDictationTokenizerRoundTrips() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        let tokenizer = endpoint.url.appendingPathComponent("tokenize")
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": [2, 3, 4]])
        try stub(endpoint, "completion", json: ["tokens_predicted": 1, "truncated": false])
        try stub(endpoint, "v1/chat/completions", json: chatReply("Hello."))
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
        try stub(endpoint, "health", json: [:])
        try stub(endpoint, "v1/models", json: ["data": [["id": "different-model"]]])
        var configuration = CleanupConfiguration(endpoint: endpoint, prompt: "Synthetic prompt")
        configuration.model = "expected-model"
        let cleanup = HTTPCleanup(configuration, http: http)
        await #expect(throws: AppError.notReady) { try await cleanup.checkReadiness() }
        configuration.model = "different-model"
        try await HTTPCleanup(configuration, http: http).checkReadiness()
    }
    @Test func prefixPreparationIncludesBOSAndDiscardsSpeculativeOutput() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        let tokenizer = endpoint.url.appendingPathComponent("tokenize")
        let prefill = endpoint.url.appendingPathComponent("completion")
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": [2, 3, 4]])
        try stub(endpoint, "completion", json: ["tokens_predicted": 1, "truncated": false, "content": "Discard this"])
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
        try stub(endpoint, "completion", json: ["tokens_predicted": 2, "truncated": false])
        await #expect(throws: AppError.cleanup) { try await cleanup.preparePrefix() }
    }
    @Test func explicitDictionaryAliasesApplyToCompletedCleanup() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt",
            dictionary: "dochler => Doccla", inputFormat: .openWhispr), http: http)
        let body = try #require(JSONSerialization.jsonObject(with: cleanup.request("dochler", maxTokens: 128).httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == "Synthetic prompt\nCustom dictionary:\nDoccla")
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": [1, 2, 3]])
        try stub(endpoint, "v1/chat/completions", json: chatReply(" Dochler spoke to the doctor. "))
        #expect(try await cleanup.clean("dochler spoke to the doctor") == "Doccla spoke to the doctor.")
    }
    @Test func unhealthyStatusAndOversizedBodiesFailBeforeDecode() async throws {
        let (endpoint, http) = try fixture()
        try stub(endpoint, "health", status: 503, json: [:])
        await #expect(throws: AppError.notReady) { try await http.health(endpoint) }
        let url = endpoint.url.appendingPathComponent("oversized")
        FixtureProtocol.responses.set(url, body: Data(repeating: 65, count: 100))
        await #expect(throws: HTTPFailure.tooLarge) { try await http.send(URLRequest(url: url), limit: 10) }
    }
    @Test func cleanupStatusFailureKeepsItsOwnDiagnosis() async throws {
        let (endpoint, http) = try fixture()
        let cleanup = HTTPCleanup(.init(endpoint: endpoint, prompt: "Synthetic prompt"), http: http)
        try stub(endpoint, "apply-template", json: ["prompt": "Synthetic template"])
        try stub(endpoint, "tokenize", json: ["tokens": [1, 2, 3]])
        try stub(endpoint, "v1/chat/completions", status: 500, json: [:])
        await #expect(throws: AppError.cleanup) { try await cleanup.clean("synthetic words") }
        let backend = HTTPASRBackend(endpoint: endpoint, http: http)
        try stub(endpoint, "health", json: [:])
        try await backend.prepare()
        try stub(endpoint, "v1/audio/transcriptions", status: 500, json: [:])
        await #expect(throws: AppError.inference) { try await backend.transcribe(PCM16k([0.1])) }
    }
}
