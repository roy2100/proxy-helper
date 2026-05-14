import Foundation
import Darwin

@MainActor
final class KernelManager {
    static let shared = KernelManager()
    private var process: Process?
    private var logPipe: Pipe?
    private var restartCount = 0
    private let maxRestarts = 3

    private init() {}

    func start(mihomoPath: String, configPath: String) throws {
        guard !mihomoPath.isEmpty else {
            throw KernelError.binaryNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: mihomoPath) else {
            throw KernelError.binaryNotExecutable(path: mihomoPath)
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw KernelError.configNotFound(path: configPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mihomoPath)
        p.arguments = ["-d", URL(fileURLWithPath: configPath)
                                .deletingLastPathComponent().path]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        self.logPipe = pipe

        // 捕获不跨 actor 边界的值
        p.terminationHandler = { [weak self] proc in
            let reason = proc.terminationReason
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(
                    reason: reason,
                    status: status,
                    mihomoPath: mihomoPath,
                    configPath: configPath
                )
            }
        }

        try p.run()
        self.process = p
        restartCount = 0
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(2))
            kill(pid, SIGKILL)
        }
        process = nil
    }

    private func handleTermination(
        reason: Process.TerminationReason,
        status: Int32,
        mihomoPath: String,
        configPath: String
    ) {
        guard reason == .exit && status != 0 else { return }
        if restartCount < maxRestarts {
            restartCount += 1
            try? start(mihomoPath: mihomoPath, configPath: configPath)
        }
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
