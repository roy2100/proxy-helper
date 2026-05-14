import SwiftUI
import WebKit

struct DashboardView: View {
    @Environment(AppState.self) var state

    private var dashboardURL: URL {
        let cfg = state.apiConfig
        let base = URL(string: cfg.baseURL) ?? URL(string: "http://127.0.0.1:9090")!
        let host = base.host ?? "127.0.0.1"
        let port = base.port ?? 9090

        var components = URLComponents(string: "http://board.zash.run.place/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "hostname", value: host),
            URLQueryItem(name: "port", value: "\(port)"),
        ]
        if !cfg.secret.isEmpty {
            items.append(URLQueryItem(name: "secret", value: cfg.secret))
        }
        components.queryItems = items
        return components.url ?? URL(string: "http://board.zash.run.place/")!
    }

    var body: some View {
        WebViewRepresentable(url: dashboardURL)
            .frame(minWidth: 960, minHeight: 640)
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        webView.load(URLRequest(url: url))
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}
