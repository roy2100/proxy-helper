import Testing
import Foundation
@testable import ProxyHelper

// MARK: - formatBytes

@Suite struct FormatBytesTests {
    @Test func zero() {
        #expect(formatBytes(0) == "0 B")
    }

    @Test func bytes() {
        #expect(formatBytes(512) == "512 B")
    }

    @Test func exactKilobyte() {
        #expect(formatBytes(1024) == "1 KB")
    }

    @Test func fractionalKilobyte() {
        #expect(formatBytes(1536) == "2 KB")
    }

    @Test func exactMegabyte() {
        #expect(formatBytes(1024 * 1024) == "1.0 MB")
    }

    @Test func fractionalMegabyte() {
        #expect(formatBytes(1024 * 1024 + 512 * 1024) == "1.5 MB")
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
