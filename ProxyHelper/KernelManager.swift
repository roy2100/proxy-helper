import Foundation
import Darwin

@MainActor
final class KernelManager {
    static let shared = KernelManager()
    private var process: Process?
    private var logPipe: Pipe?
    private var restartCount = 0
    private let maxRestarts = 3

    var onUnexpectedStop: (@MainActor () -> Void)?

    private static let pidKey = "lastMihomoProxyPID"

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
        clearSavedPID()
        p.terminate()
        let pid = p.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(2))
            kill(pid, SIGKILL)
        }
    }

    func stopImmediately() {
        guard let p = process else { return }
        process = nil
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
        p.arguments = ["-d", URL(fileURLWithPath: configPath)
                                .deletingLastPathComponent().path]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        self.logPipe = pipe

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
        if restartCount < maxRestarts {
            restartCount += 1
            try? launch(mihomoPath: mihomoPath, configPath: configPath)
        } else {
            onUnexpectedStop?()
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

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "未找到 mihomo，请先执行 brew install mihomo"
        case .binaryNotExecutable(let path):
            return "文件不可执行：\(path)"
        case .configNotFound(let path):
            return "配置文件不存在：\(path)"
        }
    }
}
