import SwiftUI

// MARK: - Log Data Model

enum LogLevel: String, CaseIterable, Hashable, Sendable {
    case debug, info, warn, error, fatal, unknown

    var displayName: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warn:    return "WARN"
        case .error:   return "ERROR"
        case .fatal:   return "FATAL"
        case .unknown: return "—"
        }
    }

    var textColor: Color {
        switch self {
        case .warn:           return .orange
        case .error, .fatal:  return .red
        default:              return .primary
        }
    }

    var badgeColor: Color {
        switch self {
        case .debug:          return .secondary
        case .info:           return .blue
        case .warn:           return .orange
        case .error, .fatal:  return .red
        case .unknown:        return .secondary
        }
    }

    var rowTint: Color {
        switch self {
        case .warn:          return Color.orange.opacity(0.06)
        case .error, .fatal: return Color.red.opacity(0.08)
        default:             return Color.clear
        }
    }

    // Init from logrus text format level values
    init?(logrusString s: String) {
        switch s.lowercased() {
        case "trace", "debug":   self = .debug
        case "info":             self = .info
        case "warning", "warn":  self = .warn
        case "error":            self = .error
        case "fatal", "panic":   self = .fatal
        default:                 return nil
        }
    }

    // Init from compact prefix: INFO, WARN, ERRO, DEBU, TRAC, FATA
    init?(compactPrefix s: String) {
        switch s {
        case "TRAC", "DEBU": self = .debug
        case "INFO":         self = .info
        case "WARN":         self = .warn
        case "ERRO":         self = .error
        case "FATA", "PANI": self = .fatal
        default:             return nil
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let level: LogLevel
    let timestamp: String  // "HH:mm:ss" or empty
    let message: String
    let raw: String

    static func parse(_ raw: String) -> LogEntry {
        let id = UUID()

        // logrus key=value format: time="..." level=info msg="..."
        if raw.contains("level=") && raw.contains("msg=") {
            let level = extractBare("level", in: raw).flatMap(LogLevel.init(logrusString:)) ?? .unknown
            let ts = extractQuoted("time", in: raw).map(hhmmss) ?? ""
            let msg = extractQuoted("msg", in: raw) ?? raw
            return LogEntry(id: id, level: level, timestamp: ts, message: msg, raw: raw)
        }

        // Compact format: INFO[0001] message
        if raw.count >= 8 {
            let pfx = String(raw.prefix(4))
            if let level = LogLevel(compactPrefix: pfx) {
                let rest = raw.dropFirst(4)
                if rest.first == "[", let close = rest.firstIndex(of: "]") {
                    let msg = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                    return LogEntry(id: id, level: level, timestamp: "", message: msg.isEmpty ? raw : msg, raw: raw)
                }
            }
        }

        return LogEntry(id: id, level: .unknown, timestamp: "", message: raw, raw: raw)
    }

    // Extract an unquoted value: level=info → "info"
    private static func extractBare(_ key: String, in text: String) -> String? {
        let prefix = "\(key)="
        guard let r = text.range(of: prefix) else { return nil }
        let after = text[r.upperBound...]
        let end = after.firstIndex(where: { $0.isWhitespace }) ?? after.endIndex
        return String(after[..<end])
    }

    // Extract a double-quoted value: msg="hello world" → "hello world"
    private static func extractQuoted(_ key: String, in text: String) -> String? {
        let prefix = "\(key)=\""
        guard let r = text.range(of: prefix) else { return nil }
        let after = text[r.upperBound...]
        guard let close = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<close])
    }

    // Extract HH:mm:ss from an ISO8601 timestamp string
    private static func hhmmss(_ iso: String) -> String {
        if let t = iso.firstIndex(of: "T") {
            let start = iso.index(after: t)
            if iso.distance(from: start, to: iso.endIndex) >= 8 {
                return String(iso[start..<iso.index(start, offsetBy: 8)])
            }
        }
        return String(iso.prefix(19))
    }
}

// MARK: - Log Row

private struct LogRowView: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.level.displayName)
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundStyle(entry.level.badgeColor)
                .frame(width: 38, alignment: .leading)

            if !entry.timestamp.isEmpty {
                Text(entry.timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 58, alignment: .leading)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.level.textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(entry.level.rowTint)
    }
}

// MARK: - Log View

struct LogView: View {
    @Environment(AppState.self) var state
    @State private var levelFilter: LogLevel? = nil
    @State private var searchText = ""
    @State private var autoScroll = true

    private var filteredEntries: [LogEntry] {
        state.logEntries.filter { entry in
            if let level = levelFilter, entry.level != level { return false }
            if !searchText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.raw.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag(Optional<LogLevel>.none)
                    Text("DEBUG").tag(Optional<LogLevel>.some(.debug))
                    Text("INFO").tag(Optional<LogLevel>.some(.info))
                    Text("WARN").tag(Optional<LogLevel>.some(.warn))
                    Text("ERROR").tag(Optional<LogLevel>.some(.error))
                }
                .pickerStyle(.segmented)
                .fixedSize()

                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            // Log list
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            LogRowView(entry: entry)
                        }
                        Color.clear.frame(height: 1).id("log-end")
                    }
                }
                .onChange(of: state.logEntries.count) {
                    if autoScroll { scrollProxy.scrollTo("log-end") }
                }
                .onChange(of: autoScroll) { _, on in
                    if on { scrollProxy.scrollTo("log-end") }
                }
            }

            Divider()

            // Status bar
            HStack(spacing: 4) {
                Text("\(state.logEntries.count) 条日志")
                if filteredEntries.count != state.logEntries.count {
                    Text("· 显示 \(filteredEntries.count) 条")
                }
                Spacer()
                Toggle(isOn: $autoScroll) {
                    Label("自动滚动", systemImage: "arrow.down.to.line.compact")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("自动滚动到最新日志")
            }
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(minWidth: 700, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("清除") { state.logEntries.removeAll() }
                    .disabled(state.logEntries.isEmpty)
            }
        }
    }
}
