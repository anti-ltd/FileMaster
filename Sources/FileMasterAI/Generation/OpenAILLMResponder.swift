import Foundation

/// Streams a chat completion from any OpenAI-compatible endpoint, with optional
/// tool-calling support. Works unmodified for OpenAI, Ollama, and llama.cpp (/v1).
enum OpenAILLMResponder {

    /// Stream a response, calling `onText` with cumulative text on each chunk.
    /// If `tools` is non-empty, runs a tool-calling loop: when the model requests
    /// a tool the handler is called, the result is fed back, and generation
    /// continues until the model produces a plain text response.
    static func stream(
        prompt: String,
        systemPrompt: String,
        tools: [HTTPTool] = [],
        config: LLMConfiguration,
        onText: @escaping (String) -> Void
    ) async throws -> String {
        let endpoint = try resolveEndpoint(config)

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": prompt],
        ]

        // Cap iterations to prevent infinite loops if the model misbehaves.
        for _ in 0..<6 {
            let (text, calls, finishReason) = try await streamOnce(
                messages: messages,
                tools: tools,
                endpoint: endpoint,
                config: config,
                onText: onText
            )

            guard finishReason == "tool_calls", !calls.isEmpty else {
                return text
            }

            // Append the assistant turn that requested the tool calls.
            messages.append(assistantToolCallMessage(calls))

            // Execute every requested tool and append its result.
            for call in calls {
                let result: String
                if let tool = tools.first(where: { $0.name == call.name }) {
                    result = await tool.handler(call.arguments)
                } else {
                    result = "Unknown tool: \(call.name)"
                }
                messages.append([
                    "role":         "tool",
                    "tool_call_id": call.id,
                    "content":      result,
                ])
            }
        }

        // Fallback if we somehow exhausted iterations.
        return ""
    }
}

// MARK: - Internal helpers

private extension OpenAILLMResponder {

    struct PendingCall {
        var id:        String = ""
        var name:      String = ""
        var arguments: String = ""
    }

    /// One streaming round-trip. Returns the accumulated text content, any tool
    /// calls the model requested, and the finish reason.
    static func streamOnce(
        messages: [[String: Any]],
        tools: [HTTPTool],
        endpoint: URL,
        config: LLMConfiguration,
        onText: @escaping (String) -> Void
    ) async throws -> (text: String, calls: [PendingCall], finishReason: String?) {
        let request = try buildRequest(messages: messages, tools: tools, endpoint: endpoint, config: config)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        var accumulated  = ""
        var pending      = [Int: PendingCall]()   // tool-call index → accumulator
        var finishReason: String? = nil

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard
                let data   = payload.data(using: .utf8),
                let chunk  = try? JSONDecoder().decode(SSEChunk.self, from: data),
                let choice = chunk.choices.first
            else { continue }

            if let reason = choice.finish_reason { finishReason = reason }

            if let content = choice.delta.content {
                accumulated += content
                onText(accumulated)
            }

            for delta in choice.delta.tool_calls ?? [] {
                let i = delta.index
                if pending[i] == nil { pending[i] = PendingCall() }
                if let id   = delta.id,                     !id.isEmpty   { pending[i]!.id        = id }
                if let name = delta.function?.name,         !name.isEmpty { pending[i]!.name       += name }
                if let args = delta.function?.arguments                   { pending[i]!.arguments  += args }
            }
        }

        let calls = pending.sorted { $0.key < $1.key }.map(\.value)
        return (accumulated, calls, finishReason)
    }

    static func buildRequest(
        messages: [[String: Any]],
        tools: [HTTPTool],
        endpoint: URL,
        config: LLMConfiguration
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model":       config.model,
            "messages":    messages,
            "stream":      true,
            "temperature": 0.4,
            "max_tokens":  800,
        ]
        if !tools.isEmpty {
            body["tools"]       = tools.map(\.openAIDefinition)
            body["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func assistantToolCallMessage(_ calls: [PendingCall]) -> [String: Any] {
        [
            "role":    "assistant",
            "content": NSNull(),
            "tool_calls": calls.map { call -> [String: Any] in
                [
                    "id":   call.id,
                    "type": "function",
                    "function": [
                        "name":      call.name,
                        "arguments": call.arguments,
                    ] as [String: Any],
                ]
            },
        ]
    }

    static func resolveEndpoint(_ config: LLMConfiguration) throws -> URL {
        let base = config.baseURL.hasSuffix("/")
            ? String(config.baseURL.dropLast())
            : config.baseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw URLError(.badURL)
        }
        return url
    }
}

// MARK: - SSE response shape

private struct SSEChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta:         Delta
        let finish_reason: String?

        struct Delta: Decodable {
            let content:    String?
            let tool_calls: [ToolCallDelta]?

            struct ToolCallDelta: Decodable {
                let index:    Int
                let id:       String?
                let function: FunctionDelta?

                struct FunctionDelta: Decodable {
                    let name:      String?
                    let arguments: String?
                }
            }
        }
    }
}
