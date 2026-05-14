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

// MARK: - AppState

@Suite @MainActor struct AppStateTests {
    @Test func defaultHttpPort() {
        UserDefaults.standard.removeObject(forKey: "httpPort")
        let state = AppState()
        #expect(state.httpPort == 7890)
    }

    @Test func defaultSocksPort() {
        UserDefaults.standard.removeObject(forKey: "socksPort")
        let state = AppState()
        #expect(state.socksPort == 7891)
    }

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
