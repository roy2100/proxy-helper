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
