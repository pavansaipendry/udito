import Foundation

/// Minimal streaming client for the Claude Messages API. Swift has no official
/// Anthropic SDK, so this speaks the REST/SSE protocol directly:
/// POST /v1/messages with stream=true, then reads text deltas off the
/// server-sent-event stream.
final class ClaudeClient {
    struct RequestError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let model = "claude-opus-4-8"

    private var task: Task<Void, Never>?

    func ask(
        apiKey: String,
        system: String,
        messages: [[String: Any]],
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        cancel()
        task = Task {
            var attempt = 0
            while true {
                var received = false
                do {
                    try await Self.stream(apiKey: apiKey, system: system, messages: messages) {
                        received = true
                        onDelta($0)
                    }
                    if !Task.isCancelled { onComplete(nil) }
                    return
                } catch is CancellationError {
                    return // superseded by a newer question — stay quiet
                } catch {
                    attempt += 1
                    // Transient failures retry silently — but only if nothing
                    // streamed yet, so text is never duplicated.
                    if !received, attempt <= 2, Self.isTransient(error) {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                        if Task.isCancelled { return }
                        continue
                    }
                    if !Task.isCancelled { onComplete(error) }
                    return
                }
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        let message = error.localizedDescription
        return message.contains("Rate limited") || message.contains("overloaded")
            || message.contains("(HTTP 5")
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func stream(
        apiKey: String,
        system: String,
        messages: [[String: Any]],
        onDelta: @escaping (String) -> Void
    ) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Adaptive thinking at low effort: quick answers suited to live meetings.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "low"],
            "system": system,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RequestError("No response from Claude.")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 4000 { break }
            }
            throw RequestError(Self.errorMessage(status: http.statusCode, body: detail))
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            guard let data = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    onDelta(text)
                }
            case "message_delta":
                // A max_tokens stop means the answer was cut mid-thought —
                // say so instead of presenting it as complete.
                if let delta = event["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "max_tokens" {
                    onDelta("\n\n[Answer hit the length limit — ask a follow-up to continue.]")
                }
            case "message_stop":
                return
            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
                throw RequestError("Claude error: \(message)")
            default:
                break
            }
        }
    }

    private static func errorMessage(status: Int, body: String) -> String {
        switch status {
        case 401:
            return "Anthropic rejected the API key — check it via the gear icon."
        case 403:
            return "This Anthropic API key lacks permission for the model."
        case 429:
            return "Rate limited by Anthropic — wait a moment and try again."
        case 529:
            return "Claude is temporarily overloaded — try again shortly."
        default:
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return "Claude error (\(status)): \(message)"
            }
            return "Claude request failed (HTTP \(status))."
        }
    }
}
