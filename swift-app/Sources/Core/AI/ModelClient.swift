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
    var toolCalls: [ToolCall]
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
        let body = apiType == .anthropic
            ? Self.buildAnthropicBody(model: model, messages: messages, tools: tools)
            : buildRequestBody(messages: messages, tools: tools)
        req.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.transport(error.localizedDescription))); return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.http(http.statusCode))); return
            }
            guard let data,
                  let reply = self.apiType == .anthropic
                      ? Self.parseAnthropic(data: data) : Self.parse(data: data) else {
                completion(.failure(.badResponse)); return
            }
            completion(.success(reply))
        }.resume()
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

    func buildRequestBody(messages: [ChatMessage], tools: [ToolSpec]) -> String {
        struct Body: Encodable {
            var model: String
            var messages: [ChatMessage]
            var tools: [WireTool]
            var tool_choice: String
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
            tool_choice: "auto")
        let encoder = JSONEncoder()
        return String(data: (try? encoder.encode(body)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func parse(data: Data) -> ModelReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        let text = message["content"] as? String
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
        return ModelReply(text: text, toolCalls: calls)
    }

    // MARK: anthropic-messages shaping (pure, test-covered)

    /// Convert our wire-shaped history to the anthropic form: system
    /// prompt becomes a top-level field; assistant tool calls become
    /// tool_use content blocks; tool results become user tool_result
    /// blocks. Uses JSONSerialization dicts end-to-end — the anthropic
    /// shapes nest content blocks too deeply for the Encodable route.
    static func buildAnthropicBody(model: String, messages: [ChatMessage],
                                    tools: [ToolSpec]) -> String {
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
        return String(data: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(),
                      encoding: .utf8) ?? "{}"
    }

    static func parseAnthropic(data: Data) -> ModelReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { return nil }
        var text: String?
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                let t = (text ?? "") + (block["text"] as? String ?? "")
                text = t
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
        return ModelReply(text: text, toolCalls: calls)
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
