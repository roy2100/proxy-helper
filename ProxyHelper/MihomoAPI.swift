import Foundation

struct MihomoAPI: Sendable {
    let baseURL: String
    let secret: String

    /// 轮询 `/version` 直到就绪。成功时返回内核版本，超时返回 nil。
    func waitUntilReady(timeout: TimeInterval = 60) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let version = await fetchVersion() { return version }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    func fetchVersion() async -> String? {
        guard let url = URL(string: "\(baseURL)/version") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 2)
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }

    /// 让 mihomo 在不重启内核的情况下重新加载配置。
    /// 当配置不在 mihomo `-d` home 目录下时（如 iCloud Documents），mihomo 会拒绝 path 形式，
    /// 此时必须把 YAML 内容当作 `payload` 直接传入。
    func reloadConfig(path: String, payload: String? = nil) async throws {
        guard let url = URL(string: "\(baseURL)/configs?force=true") else {
            throw MihomoAPIError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: String] = ["path": path]
        if let payload {
            body["payload"] = payload
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
