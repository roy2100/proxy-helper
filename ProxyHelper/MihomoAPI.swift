import Foundation

struct MihomoAPI: Sendable {
    let baseURL: String
    let secret: String

    func waitUntilReady(timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await checkHealth() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/version") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 2)
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    func patchConfigs(_ body: [String: Any]) async throws {
        guard let url = URL(string: "\(baseURL)/configs") else {
            throw MihomoAPIError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MihomoAPIError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw MihomoAPIError.badResponse(status: http.statusCode, body: bodyText)
        }
    }

    func trafficStream() -> AsyncStream<(upload: Int64, download: Int64)> {
        AsyncStream { continuation in
            guard let url = URL(string: baseURL.replacingOccurrences(of: "http", with: "ws") + "/traffic") else {
                continuation.finish()
                return
            }
            var req = URLRequest(url: url)
            if !secret.isEmpty {
                req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            let task = URLSession.shared.webSocketTask(with: req)
            task.resume()

            let monitorTask = Task {
                while !Task.isCancelled {
                    guard let msg = try? await task.receive() else { break }
                    if case .string(let text) = msg,
                       let data = text.data(using: .utf8),
                       let json = try? JSONDecoder().decode(TrafficData.self, from: data) {
                        continuation.yield((json.up, json.down))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                monitorTask.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

private struct TrafficData: Decodable {
    let up: Int64
    let down: Int64
}

enum MihomoAPIError: LocalizedError {
    case invalidURL
    case badResponse(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .badResponse(let status, let body):
            let snippet = body.prefix(200)
            return "API 返回 \(status)：\(snippet)"
        }
    }
}
