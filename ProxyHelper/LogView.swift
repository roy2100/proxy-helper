import SwiftUI

struct LogView: View {
    @Environment(AppState.self) var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.logLines.indices, id: \.self) { i in
                        Text(state.logLines[i])
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(logColor(state.logLines[i]))
                    }
                    Color.clear.frame(height: 0).id("end")
                }
                .padding(8)
            }
            .onChange(of: state.logLines.count) {
                proxy.scrollTo("end")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("清除") { state.logLines.removeAll() }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") { return .red }
        if lower.contains("warn") { return .orange }
        return .primary
    }
}
