import Foundation

enum DashboardURL {
    static func make(apiBaseURL: String, secret: String) -> URL {
        let base = URL(string: apiBaseURL) ?? URL(string: "http://127.0.0.1:9090")!
        let port = base.port ?? 9090

        var queryItems = [
            ("port", String(port)),
            ("http", "1"),
        ]
        if !secret.isEmpty {
            queryItems.append(("secret", secret))
        }

        let query = queryItems
            .map { "\(encodeQueryValue($0.0))=\(encodeQueryValue($0.1))" }
            .joined(separator: "&")

        return URL(string: "https://board.zash.run.place/#/setup?\(query)")!
    }

    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
