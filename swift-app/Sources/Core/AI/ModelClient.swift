// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Wire-shaped chat types (OpenAI-compatible chat completions)

struct ChatMessage: Encodable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(role: String, content: String?, toolCalls: [ToolCall]? = nil,
         toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

struct ToolCall: Equatable, Encodable {
    var id: String
    var name: String
    var argumentsJSON: String

    /// OpenAI wire shape: {"id":…, "type":"function",
    /// "function":{"name":…, "arguments":"…json…"}} — so an assistant
    /// message carrying tool calls can be replayed verbatim.
    private enum CodingKeys: String, CodingKey { case id, type, function }
    private enum FunctionKeys: String, CodingKey { case name, arguments }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode("function", forKey: .type)
        var fn = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try fn.encode(name, forKey: .name)
        try fn.encode(argumentsJSON, forKey: .arguments)
    }
}

struct ToolSpec {
    var name: String
    var description: String
    var parametersJSON: String
}

struct ModelReply {
    var text: String?
    /// Extended-thinking / chain-of-thought the model exposed with the
    /// reply (OpenAI "reasoning_content"/"reasoning", Anthropic thinking
    /// blocks). nil when the model or endpoint doesn't emit it.
    var reasoning: String? = nil
    var toolCalls: [ToolCall]
}

/// One streaming chunk: text and/or reasoning fragments (either may
/// be nil; empty fragments are dropped by the parser).
struct StreamDelta {
    var text: String?
    var reasoning: String?
}

enum ModelError: Error, Equatable {
    case notConfigured
    case http(Int)
    case badResponse
    case transport(String)
}

// MARK: - Model client

protocol ModelClient: AnyObject {
    func complete(messages: [ChatMessage], tools: [ToolSpec],
                   completion: @escaping (Result<ModelReply, ModelError>) -> Void)
    /// Streaming variant: onDelta fires as chunks arrive (any thread);
    /// completion carries the assembled reply. The default falls back
    /// to the buffered call (fakes, non-streaming endpoints).
    func stream(messages: [ChatMessage], tools: [ToolSpec],
                onDelta: @escaping (StreamDelta) -> Void,
                completion: @escaping (Result<ModelReply, ModelError>) -> Void)
}

extension ModelClient {
    func stream(messages: [ChatMessage], tools: [ToolSpec],
                onDelta: @escaping (StreamDelta) -> Void,
                completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        complete(messages: messages, tools: tools, completion: completion)
    }
}

/// One OpenAI-compatible endpoint (`{base}/chat/completions`).
final class OpenAICompatibleClient: ModelClient {
    private let baseUrl: String
    private let apiKey: String
    private let model: String

    /// Wire protocol of the provider endpoint. v1 shapes both request
    /// and response; litellm-style local proxies stay "openai".
    enum APIType: String {
        case openai
        case anthropic
    }

    private let apiType: APIType
    init(baseUrl: String, apiKey: String, model: String, apiType: APIType = .openai) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
        self.apiType = apiType
    }

    /// Empty Base URL or Model = the AI feature is disabled (spec: the
    /// `@ai` trigger must then fall through to the shell — fail-open).
    static var isConfigured: Bool {
        let p = AppPreferences.shared
        return !p.aiBaseUrl.isEmpty && !p.aiModel.isEmpty
    }

    func complete(messages: [ChatMessage], tools: [ToolSpec],
                   completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        perform(messages: messages, tools: tools, allowThinking: true,
                stream: false, onDelta: nil, completion: completion)
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec],
                onDelta: @escaping (StreamDelta) -> Void,
                completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        perform(messages: messages, tools: tools, allowThinking: true,
                stream: true, onDelta: onDelta, completion: completion)
    }

    private func perform(messages: [ChatMessage], tools: [ToolSpec], allowThinking: Bool,
                         stream: Bool, onDelta: ((StreamDelta) -> Void)?,
                         completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        guard !baseUrl.isEmpty, !model.isEmpty else {
            completion(.failure(.notConfigured)); return
        }
        let path = apiType == .anthropic ? "/v1/messages" : "/chat/completions"
        var url: URL
        do {
            var base = baseUrl
            while base.hasSuffix("/") { base.removeLast() }
            guard let parsed = URL(string: base + path) else {
                completion(.failure(.transport("bad base URL"))); return
            }
            url = parsed
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiType == .anthropic {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        }
        if apiType == .anthropic {
            // Extended thinking is surfaced in the card's think block;
            // the budget must sit below max_tokens (8192).
            // ponytail: fixed 1024 budget — make it a setting if it ever
            // needs tuning per model.
            var body = Self.buildAnthropicBody(model: model, messages: messages, tools: tools)
            if allowThinking { body["thinking"] = ["type": "enabled", "budget_tokens": 1024] }
            if stream { body["stream"] = true }
            req.httpBody = Data((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        } else {
            req.httpBody = Data(buildRequestBody(messages: messages, tools: tools,
                                                 stream: stream).utf8)
        }
        if stream {
            streamRequest(req, messages: messages, tools: tools, allowThinking: allowThinking,
                          onDelta: onDelta, completion: completion)
            return
        }
        Self.fallbackDataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.transport(Self.netMessage(error, for: req)))); return
            }
            if let http = response as? HTTPURLResponse {
                // Models without extended thinking reject the thinking
                // param with 400 — retry once without it rather than
                // failing the whole task.
                if http.statusCode == 400 && self.apiType == .anthropic && allowThinking {
                    self.perform(messages: messages, tools: tools, allowThinking: false,
                                 stream: false, onDelta: onDelta, completion: completion)
                    return
                }
                if !(200...299).contains(http.statusCode) {
                    completion(.failure(.http(http.statusCode))); return
                }
            }
            guard let data,
                  let reply = self.apiType == .anthropic
                      ? Self.parseAnthropic(data: data) : Self.parse(data: data) else {
                completion(.failure(.badResponse)); return
            }
            completion(.success(reply))
        }
    }

    // MARK: - Transport (system proxy first, direct fallback)

    /// A PROXY-LESS session: macOS proxies (Clash/Surge/sing-box at
    /// 127.0.0.1) MITM or stall TLS for some API hosts and URLSession
    /// surfaces that as -1200 "A TLS error caused the secure connection
    /// to fail." (the api.z.ai report — curl went direct and was fine).
    private static let directSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]   // empty = no system proxy
        return URLSession(configuration: cfg)
    }()

    /// The system-proxied session first (a user's proxy is usually
    /// intentional); a transport-level failure retries ONCE direct.
    static func fallbackDataTask(with req: URLRequest, attempt: Int = 0,
                                 completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let session: URLSession = attempt == 0 ? .shared : directSession
        session.dataTask(with: req) { data, response, error in
            let ns = (error as NSError?)?.code ?? 0
            if error != nil, attempt == 0,
               ns != NSURLErrorCancelled, ns != NSURLErrorNotConnectedToInternet {
                fallbackDataTask(with: req, attempt: 1, completion: completion)
                return
            }
            completion(data, response, error)
        }.resume()
    }

    /// Transport failures name the host — "transport(...)" alone never
    /// said WHERE the network refused to go.
    static func netMessage(_ error: Error, for req: URLRequest) -> String {
        let host = req.url?.host ?? "?"
        return "\(host): \(error.localizedDescription)"
    }

    /// SSE streaming pass: parses server-sent events incrementally and
    /// assembles the final reply. Deltas fire on a URLSession task
    /// thread; the coordinator owns its own queue hop. A 400 thinking
    /// rejection retries once buffered (rare path — not worth a second
    /// stream pass).
    private func streamRequest(_ req: URLRequest, messages: [ChatMessage], tools: [ToolSpec],
                               allowThinking: Bool, onDelta: ((StreamDelta) -> Void)?,
                               session: URLSession = .shared, directFallback: Bool = true,
                               completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        Task {
            var receivedAny = false   // never double-fire deltas on fallback
            do {
                let (bytes, response) = try await session.bytes(for: req)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 400 && apiType == .anthropic && allowThinking {
                        perform(messages: messages, tools: tools, allowThinking: false,
                                stream: false, onDelta: onDelta, completion: completion)
                        return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        completion(.failure(.http(http.statusCode))); return
                    }
                }
                let parser = SSEChatParser(apiType: apiType)
                for try await line in bytes.lines {
                    receivedAny = true
                    for delta in parser.feed(line + "\n") {
                        onDelta?(delta)
                    }
                }
                guard let reply = parser.reply() else {
                    completion(.failure(.badResponse)); return
                }
                completion(.success(reply))
            } catch {
                // Proxy-stalled first byte (the -1200/-1001 class): one
                // direct retry — but only while NOTHING streamed, or a
                // resumed task would repeat its deltas.
                if directFallback, !receivedAny {
                    streamRequest(req, messages: messages, tools: tools,
                                  allowThinking: allowThinking, onDelta: onDelta,
                                  session: Self.directSession, directFallback: false,
                                  completion: completion)
                    return
                }
                completion(.failure(.transport(Self.netMessage(error, for: req))))
            }
        }
    }

    // MARK: request/response shaping (pure, test-covered)

    struct WireFunction: Encodable {
        var name: String
        var description: String
        var parameters: AnyCodableJSON
    }
    struct WireTool: Encodable {
        var type = "function"
        var function: WireFunction
    }

    func buildRequestBody(messages: [ChatMessage], tools: [ToolSpec],
                          stream: Bool = false) -> String {
        struct Body: Encodable {
            var model: String
            var messages: [ChatMessage]
            var tools: [WireTool]
            var tool_choice: String
            var stream: Bool?
        }
        let body = Body(
            model: model,
            messages: messages,
            tools: tools.map { spec in
                WireTool(function: WireFunction(
                    name: spec.name,
                    description: spec.description,
                    parameters: AnyCodableJSON(jsonString: spec.parametersJSON)
                        ?? AnyCodableJSON([String: Any]())))
            },
            tool_choice: "auto",
            stream: stream ? true : nil)
        let encoder = JSONEncoder()
        return String(data: (try? encoder.encode(body)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func parse(data: Data) -> ModelReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        let text = message["content"] as? String
        // DeepSeek-style "reasoning_content" / OpenRouter "reasoning".
        let reasoning = message["reasoning_content"] as? String
            ?? message["reasoning"] as? String
        var calls: [ToolCall] = []
        if let raw = message["tool_calls"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let fn = c["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                calls.append(ToolCall(id: id, name: name,
                                      argumentsJSON: fn["arguments"] as? String ?? "{}"))
            }
        }
        if text == nil && calls.isEmpty { return nil }
        return ModelReply(text: text, reasoning: reasoning, toolCalls: calls)
    }

    // MARK: anthropic-messages shaping (pure, test-covered)

    /// Convert our wire-shaped history to the anthropic form: system
    /// prompt becomes a top-level field; assistant tool calls become
    /// tool_use content blocks; tool results become user tool_result
    /// blocks. Uses JSONSerialization dicts end-to-end — the anthropic
    /// shapes nest content blocks too deeply for the Encodable route.
    static func buildAnthropicBody(model: String, messages: [ChatMessage],
                                    tools: [ToolSpec]) -> [String: Any] {
        var systemText: [String] = []
        var outMessages: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case "system":
                if let c = m.content { systemText.append(c) }
            case "tool":
                var block: [String: Any] = ["type": "tool_result",
                                            "tool_use_id": m.toolCallId ?? ""]
                if let c = m.content { block["content"] = c }
                outMessages.append(["role": "user", "content": [block]])
            case "assistant":
                var blocks: [[String: Any]] = []
                if let c = m.content, !c.isEmpty { blocks.append(["type": "text", "text": c]) }
                for call in m.toolCalls ?? [] {
                    let input = AnyCodableJSON(jsonString: call.argumentsJSON)
                    var block: [String: Any] = ["type": "tool_use", "id": call.id, "name": call.name]
                    if input != nil {
                        // re-parse through JSONSerialization for the dict path
                        if let parsed = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) {
                            block["input"] = parsed
                        } else { block["input"] = [String: Any]() }
                    } else { block["input"] = [String: Any]() }
                    blocks.append(block)
                }
                if !blocks.isEmpty { outMessages.append(["role": "assistant", "content": blocks]) }
            default:
                outMessages.append(["role": m.role,
                                    "content": [["type": "text", "text": m.content ?? ""]]])
            }
        }
        if outMessages.isEmpty {
            outMessages.append(["role": "user", "content": [["type": "text", "text": ""]]])
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "messages": outMessages,
        ]
        if !systemText.isEmpty { body["system"] = systemText.joined(separator: "\n\n") }
        if !tools.isEmpty {
            body["tools"] = tools.map { spec -> [String: Any] in
                var t: [String: Any] = ["name": spec.name, "description": spec.description]
                t["input_schema"] = AnyCodableJSON(jsonString: spec.parametersJSON)
                    .flatMap { _ in
                        (try? JSONSerialization.jsonObject(with: Data(spec.parametersJSON.utf8)))
                    } as Any? ?? [String: Any]()
                return t
            }
        }
        return body
    }

    static func parseAnthropic(data: Data) -> ModelReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { return nil }
        var text: String?
        var reasoning: String?
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                let t = (text ?? "") + (block["text"] as? String ?? "")
                text = t
            case "thinking":
                let t = (reasoning ?? "") + (block["thinking"] as? String ?? "")
                reasoning = t
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let input = block["input"]
                let jsonData = input.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                calls.append(ToolCall(id: id, name: name,
                                      argumentsJSON: jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"))
            default: break
            }
        }
        if text == nil && calls.isEmpty { return nil }
        if let text, text.isEmpty, calls.isEmpty { return nil }
        return ModelReply(text: text, reasoning: reasoning, toolCalls: calls)
    }
}

// MARK: - Any-JSON encoder box (tool parameter schemas arrive as strings)

/// Wraps an already-parsed JSON value so it can ride through JSONEncoder.
struct AnyCodableJSON: Encodable {
    private let value: Any

    init(_ value: Any) { self.value = value }

    init?(jsonString: String) {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) else {
            return nil
        }
        value = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if value is NSNull { try container.encodeNil() }
        else if let b = value as? Bool { try container.encode(b) }
        else if let i = value as? Int { try container.encode(i) }
        else if let d = value as? Double { try container.encode(d) }
        else if let s = value as? String { try container.encode(s) }
        else if let a = value as? [Any] {
            try container.encode(a.map(AnyCodableJSON.init))   // [Encodable] is Encodable
        } else if let o = value as? [String: Any] {
            try container.encode(o.mapValues(AnyCodableJSON.init))
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - SSE chat stream parser (both wire protocols)

/// Incremental server-sent-event parser: feed raw body chunks (line
/// fragments carry over), collect deltas, assemble the final reply.
/// Pure in-memory; test-covered directly.
final class SSEChatParser {
    private let apiType: OpenAICompatibleClient.APIType
    private var buf = ""
    private var text = ""
    private var reasoning = ""
    /// openai: tool_calls delta index → (id, name, args fragments).
    private var openaiCalls: [Int: (id: String, name: String, args: String)] = [:]
    /// anthropic: content block index → kind + accumulated tool state.
    private var anthropicBlocks: [Int: (kind: String, id: String, name: String, json: String)] = [:]

    init(apiType: OpenAICompatibleClient.APIType) {
        self.apiType = apiType
    }

    /// Feed raw body text; returns the deltas it completed.
    func feed(_ chunk: String) -> [StreamDelta] {
        buf += chunk
        var deltas: [StreamDelta] = []
        while let nl = buf.firstIndex(of: "\n") {
            let line = String(buf[buf.startIndex..<nl])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buf.removeSubrange(buf.startIndex..<buf.index(after: nl))
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            deltas += consume(obj)
        }
        return deltas
    }

    /// The assembled reply, or nil when the stream carried nothing.
    func reply() -> ModelReply? {
        var calls: [ToolCall] = []
        if apiType == .anthropic {
            calls = anthropicBlocks.sorted(by: { $0.key < $1.key }).compactMap { _, b in
                b.kind == "tool_use" && !b.id.isEmpty
                    ? ToolCall(id: b.id, name: b.name, argumentsJSON: b.json.isEmpty ? "{}" : b.json)
                    : nil
            }
        } else {
            calls = openaiCalls.sorted(by: { $0.key < $1.key }).map { _, c in
                ToolCall(id: c.id, name: c.name,
                         argumentsJSON: c.args.isEmpty ? "{}" : c.args)
            }
        }
        let t = text.isEmpty ? nil : text
        if t == nil && calls.isEmpty { return nil }
        return ModelReply(text: t, reasoning: reasoning.isEmpty ? nil : reasoning,
                          toolCalls: calls)
    }

    private func consume(_ obj: [String: Any]) -> [StreamDelta] {
        apiType == .anthropic ? consumeAnthropic(obj) : consumeOpenAI(obj)
    }

    private func consumeOpenAI(_ obj: [String: Any]) -> [StreamDelta] {
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return [] }
        var out: [StreamDelta] = []
        if let t = delta["content"] as? String, !t.isEmpty {
            text += t
            out.append(StreamDelta(text: t, reasoning: nil))
        }
        if let r = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String,
           !r.isEmpty {
            reasoning += r
            out.append(StreamDelta(text: nil, reasoning: r))
        }
        if let raw = delta["tool_calls"] as? [[String: Any]] {
            for c in raw {
                let idx = c["index"] as? Int ?? 0
                var slot = openaiCalls[idx] ?? ("", "", "")
                if let id = c["id"] as? String { slot.id = id }
                if let fn = c["function"] as? [String: Any] {
                    if let n = fn["name"] as? String { slot.name = n }
                    if let a = fn["arguments"] as? String { slot.args += a }
                }
                openaiCalls[idx] = slot
            }
        }
        return out
    }

    private func consumeAnthropic(_ obj: [String: Any]) -> [StreamDelta] {
        guard let type = obj["type"] as? String else { return [] }
        let idx = obj["index"] as? Int ?? 0
        switch type {
        case "content_block_start":
            if let block = obj["content_block"] as? [String: Any],
               let kind = block["type"] as? String {
                anthropicBlocks[idx] = (kind,
                                        block["id"] as? String ?? "",
                                        block["name"] as? String ?? "", "")
            }
            return []
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any],
                  let dType = delta["type"] as? String else { return [] }
            switch dType {
            case "text_delta":
                if let t = delta["text"] as? String, !t.isEmpty {
                    text += t
                    return [StreamDelta(text: t, reasoning: nil)]
                }
            case "thinking_delta":
                if let t = delta["thinking"] as? String, !t.isEmpty {
                    reasoning += t
                    return [StreamDelta(text: nil, reasoning: t)]
                }
            case "input_json_delta":
                if var b = anthropicBlocks[idx] {
                    b.json += delta["partial_json"] as? String ?? ""
                    anthropicBlocks[idx] = b
                }
            default: break
            }
            return []
        default:
            return []   // message_start/stop, ping: nothing to do
        }
    }
}
