import Foundation

public struct LocalEndpoint: Sendable {
    public let url: URL
    public init(_ value: String) throws {
        guard let url = URL(string: value), url.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw AppError.unsupported }
        self.url = url
    }
}
public final class LocalHTTP: Sendable {
    private let session: URLSession
    public init(session suppliedSession: URLSession? = nil) {
        if let suppliedSession { session = suppliedSession; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest, limit: Int = 256 * 1024) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= limit else { throw AppError.inference }
        var result = Data()
        result.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard result.count < limit else { throw AppError.contextLimit }
            result.append(byte)
        }
        return result
    }
    public func health(_ endpoint: LocalEndpoint) async throws {
        _ = try await withDeadline(.seconds(2), stage: "Health") {
            try await self.send(URLRequest(url: endpoint.url.appendingPathComponent("health")), limit: 16_384)
        }
    }
    public func cleanupReadiness(_ endpoint: LocalEndpoint, model: String = "gemma4-e2b-cleanup:latest") async throws {
        try await health(endpoint)
        try await withDeadline(.seconds(2), stage: "Cleanup model") {
            struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
            let data = try await self.send(URLRequest(url: endpoint.url.appendingPathComponent("v1/models")), limit: 16_384)
            guard try JSONDecoder().decode(Models.self, from: data).data.contains(where: { $0.id == model }) else {
                throw AppError.notReady
            }
        }
    }
}
public enum WAVEncoder {
    public static func encode(_ audio: PCM16k) -> Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + audio.samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(16_000)); word(UInt32(32_000)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(audio.samples.count * 2))
        for sample in audio.samples { word(Int16((max(-1, min(1, sample)) * 32767).rounded())) }
        return data
    }
}
public actor HTTPASRBackend: ASRBackend {
    public nonisolated let capabilities = ASRCapabilities()
    private let endpoint: LocalEndpoint
    private let http: LocalHTTP
    private var state: BackendReadiness = .unloaded
    public init(endpoint: LocalEndpoint, http: LocalHTTP = .init()) { self.endpoint = endpoint; self.http = http }
    public func readiness() -> BackendReadiness { state }
    public func prepare() async throws {
        state = .preparing
        do { try await http.health(endpoint); state = .ready }
        catch { state = .failed; throw error }
    }
    public static func request(audio: PCM16k, endpoint: LocalEndpoint, boundary: String) -> URLRequest {
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nparakeet\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(WAVEncoder.encode(audio)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint.url.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }
    public func transcribe(_ audio: PCM16k) async throws -> ASRResult {
        guard state == .ready else { throw AppError.notReady }
        guard !audio.samples.isEmpty else { return .init(text: "", audioDuration: 0) }
        let data = try await http.send(Self.request(audio: audio, endpoint: endpoint, boundary: UUID().uuidString))
        struct Response: Decodable { let text: String }
        return .init(text: try JSONDecoder().decode(Response.self, from: data).text, audioDuration: audio.duration)
    }
}
public enum CleanupInputFormat: String, Codable, CaseIterable, Sendable { case plain, openWhispr }
public struct CleanupConfiguration: Sendable {
    public var endpoint: LocalEndpoint
    public var model = "gemma4-e2b-cleanup:latest"
    public var prompt: String
    public var dictionary: String
    public var inputFormat: CleanupInputFormat
    public var dictionaryPrefix: String
    public init(endpoint: LocalEndpoint, prompt: String, dictionary: String = "",
                inputFormat: CleanupInputFormat = .plain, dictionaryPrefix: String = "\nCustom dictionary:\n") {
        self.endpoint = endpoint; self.prompt = prompt; self.dictionary = dictionary
        self.inputFormat = inputFormat; self.dictionaryPrefix = dictionaryPrefix
    }
}
public struct HTTPCleanup: TextCleanup {
    public let configuration: CleanupConfiguration
    private let http: LocalHTTP
    private let dictionary: DictionaryCorrections
    public init(_ configuration: CleanupConfiguration, http: LocalHTTP = .init()) {
        self.configuration = configuration; self.http = http
        dictionary = DictionaryCorrections(configuration.dictionary)
    }
    public func request(_ text: String) throws -> URLRequest {
        let system = configuration.prompt + (dictionary.vocabulary.isEmpty ? "" : configuration.dictionaryPrefix + dictionary.vocabulary)
        let user = configuration.inputFormat == .openWhispr ? "<transcript>\n\(text)\n</transcript>\n\nOutput only the cleaned transcript." : text
        // Bound the request allocation; the exact templated token count is checked before inference.
        guard system.utf8.count + user.utf8.count <= 16_384 else { throw AppError.contextLimit }
        let body: [String: Any] = ["model": configuration.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0, "max_tokens": 512, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false]]
        var request = URLRequest(url: configuration.endpoint.url.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    /// Runs only during app preparation, before the hotkey is enabled. The fixed
    /// prefix is useful on a cache miss; repeating it for warm dictations is not.
    public func preparePrefix() async throws {
        let first = try await tokens(for: request("ZZZ synthetic marker"))
        let second = try await tokens(for: request("aaa different marker"))
        let prefix = zip(first, second).prefix { $0.0 == $0.1 }.map { $0.0 }
        guard !prefix.isEmpty, prefix.count + 512 <= 4096 else { throw AppError.contextLimit }
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.endpoint.url.appendingPathComponent("completion"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prefix,
            "n_predict": 0, "temperature": 0, "stream": false, "cache_prompt": true])
        struct Prefill: Decodable { let tokens_predicted: Int; let truncated: Bool }
        let response = try JSONDecoder().decode(Prefill.self, from: await http.send(request))
        // The pinned server samples one token even with n_predict: 0. Discard all
        // response text; preparation must never become a dictation result.
        guard !response.truncated, (0...1).contains(response.tokens_predicted) else { throw AppError.cleanup }
        try Task.checkCancellation()
    }
    private func tokens(for completion: URLRequest) async throws -> [Int] {
        // Avoid guessing tokens from characters: exported prompts/dictionaries can exceed
        // 4096 bytes while fitting comfortably in the 4096-token slot. Use the pinned
        // server's exact chat template and tokenizer, with generation room reserved.
        let body = try JSONSerialization.jsonObject(with: completion.httpBody!) as! [String: Any]
        var template = URLRequest(url: configuration.endpoint.url.appendingPathComponent("apply-template"))
        template.httpMethod = "POST"
        template.setValue("application/json", forHTTPHeaderField: "Content-Type")
        template.httpBody = try JSONSerialization.data(withJSONObject: ["messages": body["messages"]!,
            "chat_template_kwargs": ["enable_thinking": false]])
        struct Template: Decodable { let prompt: String }
        let rendered = try JSONDecoder().decode(Template.self, from: await http.send(template, limit: 128 * 1024))
        var tokens = URLRequest(url: configuration.endpoint.url.appendingPathComponent("tokenize"))
        tokens.httpMethod = "POST"
        tokens.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Chat completion adds BOS. Include it in both the budget and the native
        // prefill token array, or native prefill shares no prefix with chat.
        tokens.httpBody = try JSONSerialization.data(withJSONObject: ["content": rendered.prompt, "add_special": true, "parse_special": true])
        struct Tokens: Decodable { let tokens: [Int] }
        return try JSONDecoder().decode(Tokens.self, from: await http.send(tokens, limit: 128 * 1024)).tokens
    }
    public func clean(_ text: String) async throws -> String {
        let completion = try request(text)
        guard try await tokens(for: completion).count + 512 <= 4096 else { throw AppError.contextLimit }
        try Task.checkCancellation()
        let data = try await http.send(completion)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = result.choices.first, choice.finish_reason == "stop" else { throw AppError.cleanup }
        return dictionary.apply(to: choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
