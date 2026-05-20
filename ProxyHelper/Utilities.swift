import Foundation
import Darwin
import CoreFoundation

/// 用 connect() 探测本机端口是否有进程在 LISTEN。
/// 比 bind() 更准确：进程退出后 connect() 立即得到 ECONNREFUSED，
/// 不受 TIME_WAIT 或内核回收 socket 的短暂窗口影响。
func isLocalTCPPortInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = CFSwapInt32HostToBig(INADDR_LOOPBACK)

    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

/// 通过 `lsof` 找出监听指定 TCP 端口的进程，找不到时返回 nil。
func processOnLocalTCPPort(_ port: Int) -> (name: String, pid: Int)? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    // lsof 输出首行为表头，第二行起为记录：COMMAND PID USER FD TYPE ...
    let lines = output.split(separator: "\n").map(String.init)
    guard lines.count >= 2 else { return nil }
    let parts = lines[1].split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.count >= 2, let pid = Int(parts[1]) else { return nil }
    return (parts[0], pid)
}
