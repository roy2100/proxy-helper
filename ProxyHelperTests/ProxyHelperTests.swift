import Testing
import Foundation
@testable import ProxyHelper

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
}

// MARK: - DashboardURL

@Suite struct DashboardURLTests {
    @Test func pointsToHomepage() {
        #expect(DashboardURL.homepage.absoluteString == "https://board.zash.run.place/")
    }
}
