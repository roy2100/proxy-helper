import Foundation
import Darwin

/// 测试是否能在本机绑定指定 TCP 端口。
/// 绑定到 0.0.0.0 以捕获任意接口上的占用（包括 127.0.0.1 或具体网卡 IP）。
func isLocalTCPPortInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

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
