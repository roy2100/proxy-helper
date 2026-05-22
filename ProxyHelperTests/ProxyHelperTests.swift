import Testing
import Foundation
import Observation
@testable import ProxyHelper

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

// MARK: - ConfigManager

@Suite @MainActor struct ConfigManagerTests {
    @Test func scanEmptyPath() {
        #expect(ConfigManager.shared.scan(folderPath: "").isEmpty)
    }

    @Test func scanNonexistentFolder() {
        #expect(ConfigManager.shared.scan(folderPath: "/nonexistent/path/xyz").isEmpty)
    }

    @Test func scanEmptyFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ConfigManager.shared.scan(folderPath: dir.path).isEmpty)
    }

    @Test func scanFindsYamlFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "".write(toFile: dir.appendingPathComponent("home.yaml").path, atomically: true, encoding: .utf8)
        try "".write(toFile: dir.appendingPathComponent("office.yml").path, atomically: true, encoding: .utf8)
        try "".write(toFile: dir.appendingPathComponent("notes.txt").path, atomically: true, encoding: .utf8)

        let results = ConfigManager.shared.scan(folderPath: dir.path)
        #expect(results.count == 2)
        #expect(Set(results.map(\.name)) == ["home", "office"])
    }

    @Test func scanSortedByModifiedDate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = dir.appendingPathComponent("older.yaml")
        let newer = dir.appendingPathComponent("newer.yaml")
        try "".write(to: older, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.01)
        try "".write(to: newer, atomically: true, encoding: .utf8)

        let results = ConfigManager.shared.scan(folderPath: dir.path)
        #expect(results.first?.name == "newer")
        #expect(results.last?.name == "older")
    }
}

// MARK: - ConfigManager.parseAPIConfig

@Suite @MainActor struct ParseAPIConfigTests {
    private func write(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func missingFileReturnsDefaults() {
        let result = ConfigManager.shared.parseAPIConfig(at: "/nonexistent/path.yaml")
        #expect(result.baseURL == "http://127.0.0.1:9090")
        #expect(result.secret == "")
    }

    @Test func missingExternalControllerReturnsPort9090() throws {
        let path = try write("mode: rule\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.baseURL == "http://127.0.0.1:9090")
        #expect(result.secret == "")
    }

    @Test func parsesPortFromExternalController() throws {
        let path = try write("external-controller: 127.0.0.1:9097\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.baseURL == "http://127.0.0.1:9097")
    }

    @Test func parsesSecret() throws {
        let path = try write("external-controller: 0.0.0.0:9090\nsecret: mytoken\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.secret == "mytoken")
    }

    @Test func hostIsAlwaysLocalhostRegardlessOfBindAddress() throws {
        let path = try write("external-controller: 0.0.0.0:7892\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.baseURL == "http://127.0.0.1:7892")
    }

    @Test func emptySecretFieldTreatedAsEmpty() throws {
        let path = try write("external-controller: 127.0.0.1:9090\nsecret: \"\"\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.secret == "")
    }

    @Test func malformedExternalControllerNoPortFallsTo9090() throws {
        let path = try write("external-controller: 127.0.0.1\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = ConfigManager.shared.parseAPIConfig(at: path)
        #expect(result.baseURL == "http://127.0.0.1:9090")
    }
}

// MARK: - ConfigManager.parseProxyPorts

@Suite @MainActor struct ParseProxyPortsTests {
    private func write(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func missingFileReturnsDefaultProxyPorts() {
        let result = ConfigManager.shared.parseProxyPorts(at: "/nonexistent/path.yaml")

        #expect(result.http == 7890)
        #expect(result.socks == 7891)
    }

    @Test func parsesHttpAndSocksPorts() throws {
        let path = try write("port: 8080\nsocks-port: 8081\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 8080)
        #expect(result.socks == 8081)
    }

    @Test func mixedPortOverridesHttpAndSocksPorts() throws {
        let path = try write("port: 8080\nsocks-port: 8081\nmixed-port: 10801\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 10801)
        #expect(result.socks == 10801)
    }

    @Test func onlyPortSetSocksDefaultsTo7891() throws {
        let path = try write("port: 8080\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 8080)
        #expect(result.socks == 7891)
    }

    @Test func onlySocksPortSetHttpDefaultsTo7890() throws {
        let path = try write("socks-port: 8081\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 7890)
        #expect(result.socks == 8081)
    }

    @Test func mixedPortZeroIgnoredFallsToSplitPorts() throws {
        let path = try write("port: 8080\nsocks-port: 8081\nmixed-port: 0\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 8080)
        #expect(result.socks == 8081)
    }

    @Test func mixedPortOutOfRangeIgnored() throws {
        let path = try write("port: 8080\nsocks-port: 8081\nmixed-port: 65536\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 8080)
        #expect(result.socks == 8081)
    }

    @Test func portAsStringParsedCorrectly() throws {
        let path = try write("port: \"8080\"\nsocks-port: \"8081\"\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = ConfigManager.shared.parseProxyPorts(at: path)

        #expect(result.http == 8080)
        #expect(result.socks == 8081)
    }
}

// MARK: - ConfigManager.parseRequiredPorts

@Suite @MainActor struct ParseRequiredPortsTests {
    private func write(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func defaultsWhenMissing() {
        let ports = ConfigManager.shared.parseRequiredPorts(at: "/nonexistent/path.yaml")
        #expect(ports.count == 3)
        #expect(ports[0].port == 9090)
        #expect(ports[0].name == "external-controller")
        #expect(ports[1] == (name: "port", port: 7890))
        #expect(ports[2] == (name: "socks-port", port: 7891))
    }

    @Test func mixedPortCollapsesToOneEntry() throws {
        let path = try write("external-controller: 127.0.0.1:9097\nmixed-port: 10801\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ports = ConfigManager.shared.parseRequiredPorts(at: path)
        #expect(ports.count == 2)
        #expect(ports[0] == (name: "external-controller", port: 9097))
        #expect(ports[1] == (name: "mixed-port", port: 10801))
    }

    @Test func splitHttpAndSocks() throws {
        let path = try write("external-controller: 127.0.0.1:9097\nport: 8080\nsocks-port: 8081\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ports = ConfigManager.shared.parseRequiredPorts(at: path)
        #expect(ports.count == 3)
        #expect(ports[0].port == 9097)
        #expect(ports[1].port == 8080)
        #expect(ports[2].port == 8081)
    }
}

// MARK: - 端口占用检测

@Suite struct PortInUseTests {
    @Test func freePortReturnsFalse() {
        // 临时绑定拿到空闲端口，再关闭，等到释放后检测应为 false
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(probe, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(probe, sockPtr, &len)
            }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        close(probe)

        #expect(isLocalTCPPortInUse(port) == false)
    }

    @Test func occupiedPortReturnsTrue() {
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(holder) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(holder, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(holder, sockPtr, &len)
            }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))

        // connect() 检测需要 socket 处于 LISTEN 状态
        listen(holder, 1)

        #expect(isLocalTCPPortInUse(port) == true)
    }
}

// MARK: - AppState

@Suite @MainActor struct AppStateTests {
    @Test func effectiveMihomoPathFallsBackToHomebrew() {
        UserDefaults.standard.removeObject(forKey: "mihomoPath")
        let state = AppState()
        let path = state.effectiveMihomoPath
        #expect(path.isEmpty || path.contains("mihomo"))
    }

    @Test func activeConfigMatchesPath() {
        let state = AppState()
        let config = ConfigFile(path: "/tmp/test.yaml", name: "test", modifiedAt: .now)
        state.configs = [config]
        state.activeConfigPath = "/tmp/test.yaml"
        #expect(state.activeConfig?.name == "test")
    }

    @Test func activeConfigNilWhenNoMatch() {
        let state = AppState()
        state.configs = []
        state.activeConfigPath = "/tmp/missing.yaml"
        #expect(state.activeConfig == nil)
    }

    @Test func apiConfigReturnsDefaultsWhenPathEmpty() {
        let state = AppState()
        state.activeConfigPath = ""
        #expect(state.apiConfig.baseURL == "http://127.0.0.1:9090")
        #expect(state.apiConfig.secret == "")
    }

    @Test func proxyPortsReturnsDefaultsWhenPathEmpty() {
        let state = AppState()
        state.activeConfigPath = ""
        #expect(state.proxyPorts.http == 7890)
        #expect(state.proxyPorts.socks == 7891)
    }

    @Test func mihomoPathChangesInvalidateEffectivePathObservation() async {
        UserDefaults.standard.removeObject(forKey: "mihomoPath")
        let state = AppState()
        let flag = ChangeFlag()

        _ = withObservationTracking {
            state.effectiveMihomoPath
        } onChange: {
            flag.set()
        }

        state.mihomoPath = "/tmp/custom-mihomo"
        try? await Task.sleep(for: .milliseconds(10))

        #expect(flag.isSet)
        #expect(state.effectiveMihomoPath == "/tmp/custom-mihomo")
        UserDefaults.standard.removeObject(forKey: "mihomoPath")
    }

    @Test func refreshConfigsSelectsFirstConfigWhenActivePathIsMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = dir.appendingPathComponent("default.yaml")
        try "port: 8080\n".write(to: config, atomically: true, encoding: .utf8)

        let state = AppState()
        state.configFolderPath = dir.path
        state.activeConfigPath = "/tmp/missing.yaml"

        state.refreshConfigs()

        #expect(state.configs.map(\.name) == ["default"])
        #expect(state.activeConfigPath == state.configs.first?.path)
    }

    @Test func refreshConfigsClearsActivePathWhenNoConfigsExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = AppState()
        state.configFolderPath = dir.path
        state.activeConfigPath = "/tmp/missing.yaml"

        state.refreshConfigs()

        #expect(state.configs.isEmpty)
        #expect(state.activeConfigPath == "")
    }
}

// MARK: - DashboardURL

@Suite struct DashboardURLTests {
    @Test func pointsToHomepage() {
        #expect(DashboardURL.homepage.absoluteString == "https://board.zash.run.place/")
    }
}

// MARK: - LogLevel

@Suite struct LogLevelTests {

    @Test func logrusStringMappings() {
        #expect(LogLevel(logrusString: "trace")   == .debug)
        #expect(LogLevel(logrusString: "debug")   == .debug)
        #expect(LogLevel(logrusString: "info")    == .info)
        #expect(LogLevel(logrusString: "warning") == .warn)
        #expect(LogLevel(logrusString: "warn")    == .warn)
        #expect(LogLevel(logrusString: "error")   == .error)
        #expect(LogLevel(logrusString: "fatal")   == .fatal)
        #expect(LogLevel(logrusString: "panic")   == .fatal)
    }

    @Test func logrusStringUnknownReturnsNil() {
        #expect(LogLevel(logrusString: "verbose") == nil)
        #expect(LogLevel(logrusString: "")        == nil)
    }

    @Test func logrusStringCaseInsensitive() {
        #expect(LogLevel(logrusString: "INFO")    == .info)
        #expect(LogLevel(logrusString: "WARNING") == .warn)
        #expect(LogLevel(logrusString: "ERROR")   == .error)
    }

    @Test func compactPrefixMappings() {
        #expect(LogLevel(compactPrefix: "TRAC") == .debug)
        #expect(LogLevel(compactPrefix: "DEBU") == .debug)
        #expect(LogLevel(compactPrefix: "INFO") == .info)
        #expect(LogLevel(compactPrefix: "WARN") == .warn)
        #expect(LogLevel(compactPrefix: "ERRO") == .error)
        #expect(LogLevel(compactPrefix: "FATA") == .fatal)
        #expect(LogLevel(compactPrefix: "PANI") == .fatal)
    }

    @Test func compactPrefixUnknownReturnsNil() {
        #expect(LogLevel(compactPrefix: "VERB") == nil)
        #expect(LogLevel(compactPrefix: "info") == nil) // case-sensitive
        #expect(LogLevel(compactPrefix: "")     == nil)
    }
}

// MARK: - LogEntry.parse

@Suite struct LogEntryParseTests {

    // MARK: logrus key=value 格式

    @Test func logrusInfo() {
        let raw = #"time="2024-01-15T10:30:45Z" level=info msg="connected""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .info)
        #expect(e.message == "connected")
        #expect(e.timestamp == "10:30:45")
        #expect(e.raw == raw)
    }

    @Test func logrusWarning() {
        let raw = #"time="2024-01-15T08:00:00Z" level=warning msg="slow connection""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .warn)
        #expect(e.message == "slow connection")
    }

    @Test func logrusError() {
        let raw = #"level=error msg="connection refused""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .error)
        #expect(e.message == "connection refused")
        #expect(e.timestamp == "") // no time field
    }

    @Test func logrusTraceBecomesDebug() {
        let raw = #"level=trace msg="entering function""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .debug)
    }

    @Test func logrusPanicBecomesFatal() {
        let raw = #"level=panic msg="unrecoverable error""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .fatal)
    }

    @Test func logrusUnknownLevelBecomesUnknown() {
        let raw = #"level=verbose msg="verbose log""#
        let e = LogEntry.parse(raw)
        #expect(e.level == .unknown)
    }

    @Test func logrusMessageWithSpaces() {
        let raw = #"level=info msg="hello world from mihomo""#
        let e = LogEntry.parse(raw)
        #expect(e.message == "hello world from mihomo")
    }

    @Test func logrusTimestampExtractedAsHHMMSS() {
        let raw = #"time="2024-06-01T23:59:59.123Z" level=info msg="tick""#
        let e = LogEntry.parse(raw)
        #expect(e.timestamp == "23:59:59")
    }

    // MARK: compact 格式

    @Test func compactInfo() {
        let raw = "INFO[0001] dialer connected"
        let e = LogEntry.parse(raw)
        #expect(e.level == .info)
        #expect(e.message == "dialer connected")
        #expect(e.timestamp == "")
    }

    @Test func compactWarn() {
        let raw = "WARN[0002] slow upstream"
        let e = LogEntry.parse(raw)
        #expect(e.level == .warn)
        #expect(e.message == "slow upstream")
    }

    @Test func compactErro() {
        let raw = "ERRO[0003] dial tcp failed"
        let e = LogEntry.parse(raw)
        #expect(e.level == .error)
        #expect(e.message == "dial tcp failed")
    }

    @Test func compactDebu() {
        let raw = "DEBU[0000] initializing"
        let e = LogEntry.parse(raw)
        #expect(e.level == .debug)
    }

    @Test func compactTrac() {
        let raw = "TRAC[0000] entering parse"
        let e = LogEntry.parse(raw)
        #expect(e.level == .debug)
    }

    @Test func compactFata() {
        let raw = "FATA[0000] kernel crash"
        let e = LogEntry.parse(raw)
        #expect(e.level == .fatal)
    }

    @Test func compactPani() {
        let raw = "PANI[0000] panic occurred"
        let e = LogEntry.parse(raw)
        #expect(e.level == .fatal)
    }

    @Test func compactEmptyMessageUsesRaw() {
        let raw = "INFO[0001]" // 无消息体
        let e = LogEntry.parse(raw)
        #expect(e.level == .info)
        #expect(e.message == raw)
    }

    @Test func compactMessagePreservesInternalSpaces() {
        let raw = "INFO[0042] hello world foo bar"
        let e = LogEntry.parse(raw)
        #expect(e.message == "hello world foo bar")
    }

    // MARK: fallback / unknown 格式

    @Test func unknownFormatUsesRawAsMessage() {
        let raw = "some plain text log line"
        let e = LogEntry.parse(raw)
        #expect(e.level == .unknown)
        #expect(e.message == raw)
        #expect(e.timestamp == "")
    }

    @Test func emptyStringFallback() {
        let e = LogEntry.parse("")
        #expect(e.level == .unknown)
        #expect(e.message == "")
    }

    @Test func compactPrefixWithoutBracketFallsToUnknown() {
        // "INFO" + 空格 而非 "[" → 不匹配 compact 格式
        let raw = "INFO plain text here!!"
        let e = LogEntry.parse(raw)
        #expect(e.level == .unknown)
    }

    // MARK: 通用属性

    @Test func rawAlwaysPreserved() {
        let raw = #"level=info msg="test" extra=field"#
        let e = LogEntry.parse(raw)
        #expect(e.raw == raw)
    }

    @Test func eachEntryHasUniqueID() {
        let e1 = LogEntry.parse("hello")
        let e2 = LogEntry.parse("hello")
        #expect(e1.id != e2.id)
    }
}

// MARK: - MihomoAPIError

@Suite struct MihomoAPIErrorTests {
    @Test func invalidURLDescription() {
        #expect(MihomoAPIError.invalidURL.errorDescription == "无效的 API 地址")
    }

    @Test func badResponseDescription() {
        let err = MihomoAPIError.badResponse(status: 404, body: "not found")
        #expect(err.errorDescription == "API 返回 404：not found")
    }

    @Test func badResponseBodyTruncatedAt200Chars() {
        let body = String(repeating: "x", count: 300)
        let desc = MihomoAPIError.badResponse(status: 500, body: body).errorDescription ?? ""
        #expect(desc.contains("500"))
        // prefix(200) on body → description should be well under 300 extra chars
        #expect(desc.count <= "API 返回 500：".count + 200)
    }

    @Test func badResponseEmptyBody() {
        let err = MihomoAPIError.badResponse(status: 204, body: "")
        #expect(err.errorDescription == "API 返回 204：")
    }
}

// MARK: - ConfigFile

@Suite struct ConfigFileTests {
    @Test func equalityByPath() {
        let a = ConfigFile(path: "/tmp/test.yaml", name: "test",  modifiedAt: .now)
        let b = ConfigFile(path: "/tmp/test.yaml", name: "other", modifiedAt: .distantPast)
        #expect(a == b)
    }

    @Test func inequalityOnDifferentPath() {
        let a = ConfigFile(path: "/tmp/a.yaml", name: "same", modifiedAt: .now)
        let b = ConfigFile(path: "/tmp/b.yaml", name: "same", modifiedAt: .now)
        #expect(a != b)
    }

    @Test func deduplicatesInSet() {
        let a = ConfigFile(path: "/tmp/test.yaml", name: "a", modifiedAt: .now)
        let b = ConfigFile(path: "/tmp/test.yaml", name: "b", modifiedAt: .now)
        let s: Set<ConfigFile> = [a, b]
        #expect(s.count == 1)
    }

    @Test func differentPathsDistinctInSet() {
        let a = ConfigFile(path: "/tmp/a.yaml", name: "x", modifiedAt: .now)
        let b = ConfigFile(path: "/tmp/b.yaml", name: "x", modifiedAt: .now)
        let s: Set<ConfigFile> = [a, b]
        #expect(s.count == 2)
    }
}

// MARK: - ConfigManager (补充)

extension ConfigManagerTests {
    @Test func scanFindsUppercaseYAMLExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "".write(toFile: dir.appendingPathComponent("config.YAML").path, atomically: true, encoding: .utf8)

        let results = ConfigManager.shared.scan(folderPath: dir.path)
        #expect(results.count == 1)
        #expect(results.first?.name == "config")
    }
}

// MARK: - AppState (补充)

extension AppStateTests {
    @Test func apiConfigReadsFromActiveFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "external-controller: 0.0.0.0:9099\nsecret: tok\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        state.activeConfigPath = url.path
        #expect(state.apiConfig.baseURL == "http://127.0.0.1:9099")
        #expect(state.apiConfig.secret == "tok")
    }

    @Test func proxyPortsReadsFromActiveFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "mixed-port: 7777\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        state.activeConfigPath = url.path
        #expect(state.proxyPorts.http == 7777)
        #expect(state.proxyPorts.socks == 7777)
    }
}
