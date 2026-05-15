import Foundation
import Darwin

@MainActor
final class KernelManager {
    static let shared = KernelManager()
    private var process: Process?
    private var logPipe: Pipe?
    private var logReadTask: Task<Void, Never>?
    private var restartCount = 0
    private let maxRestarts = 3

    var onUnexpectedStop: (@MainActor (Error?) -> Void)?
    var onLogLine: (@MainActor (String) -> Void)?

    private static let pidKey = "lastMihomoProxyPID"

    static let mihomoHome: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ProxyHelper/mihomo", isDirectory: true)
    }()

    private init() {
        killSavedPID()
    }

    func start(mihomoPath: String, configPath: String) throws {
        restartCount = 0
        try launch(mihomoPath: mihomoPath, configPath: configPath)
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        logReadTask?.cancel()
        logReadTask = nil
        clearSavedPID()
        p.terminate()
        let pid = p.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(2))
            kill(pid, SIGKILL)
        }
    }

    func processIsRoot() -> Bool {
        guard let p = process, p.isRunning else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "uid=", "-p", "\(p.processIdentifier)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let uid = Int(s) {
                return uid == 0
            }
        } catch {}
        return false
    }

    func stopImmediately() {
        guard let p = process else { return }
        process = nil
        logReadTask?.cancel()
        logReadTask = nil
        kill(p.processIdentifier, SIGKILL)
        clearSavedPID()
    }

    private func launch(mihomoPath: String, configPath: String) throws {
        guard !mihomoPath.isEmpty else {
            throw KernelError.binaryNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: mihomoPath) else {
            throw KernelError.binaryNotExecutable(path: mihomoPath)
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw KernelError.configNotFound(path: configPath)
        }

        for (name, port) in ConfigManager.shared.parseRequiredPorts(at: configPath) {
            if isLocalTCPPortInUse(port) {
                throw KernelError.portInUse(name: name, port: port)
            }
        }

        try FileManager.default.createDirectory(at: Self.mihomoHome, withIntermediateDirectories: true)

        // kill 上次保存的 PID（处理 crash 遗留的孤儿进程）
        killSavedPID()

        // 同步终止当前持有的进程
        if let existing = process {
            existing.terminate()
            if existing.isRunning {
                kill(existing.processIdentifier, SIGKILL)
            }
            process = nil
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mihomoPath)
        p.arguments = ["-d", Self.mihomoHome.path, "-f", configPath]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        self.logPipe = pipe

        logReadTask?.cancel()
        let handle = pipe.fileHandleForReading
        logReadTask = Task { @MainActor [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard !Task.isCancelled else { break }
                    self?.onLogLine?(line)
                }
            } catch {}
        }

        p.terminationHandler = { [weak self] proc in
            let terminatedPID = proc.processIdentifier
            let reason = proc.terminationReason
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.process?.processIdentifier == terminatedPID else { return }
                self.process = nil
                self.clearSavedPID()
                self.handleTermination(
                    reason: reason,
                    status: status,
                    mihomoPath: mihomoPath,
                    configPath: configPath
                )
            }
        }

        try p.run()
        self.process = p
        savePID(p.processIdentifier)
    }

    private func handleTermination(
        reason: Process.TerminationReason,
        status: Int32,
        mihomoPath: String,
        configPath: String
    ) {
        // 正常退出（status 0）不重启
        guard !(reason == .exit && status == 0) else { return }
        guard restartCount < maxRestarts else {
            onUnexpectedStop?(nil)
            return
        }
        restartCount += 1
        do {
            try launch(mihomoPath: mihomoPath, configPath: configPath)
        } catch {
            onUnexpectedStop?(error)
        }
    }

    // MARK: - PID 持久化

    private func savePID(_ pid: Int32) {
        UserDefaults.standard.set(Int(pid), forKey: Self.pidKey)
    }

    private func clearSavedPID() {
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
    }

    private func killSavedPID() {
        let pid = UserDefaults.standard.integer(forKey: Self.pidKey)
        guard pid != 0 else { return }
        kill(Int32(pid), SIGKILL)
        clearSavedPID()
    }
}

enum KernelError: LocalizedError {
    case binaryNotFound
    case binaryNotExecutable(path: String)
    case configNotFound(path: String)
    case portInUse(name: String, port: Int)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "未找到 mihomo，请先执行 brew install mihomo"
        case .binaryNotExecutable(let path):
            return "文件不可执行：\(path)"
        case .configNotFound(let path):
            return "配置文件不存在：\(path)"
        case .portInUse(let name, let port):
            return "端口 \(port)（\(name)）已被占用，请关闭占用进程或修改配置端口"
        }
    }
}
