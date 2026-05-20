import Foundation
import Darwin

/// 测试是否能在本机绑定指定 TCP 端口。
/// 绑定到 0.0.0.0 以捕获任意接口上的占用（包括 127.0.0.1 或具体网卡 IP）。
func isLocalTCPPortInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    // SO_REUSEADDR 让探测行为与 mihomo 绑定时一致：
    // TIME_WAIT 不算占用，只有真正有进程 LISTEN 才返回 true。
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian

    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result != 0
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
