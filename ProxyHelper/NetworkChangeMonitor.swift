import Foundation
import Network

@MainActor
final class NetworkChangeMonitor {
    static let shared = NetworkChangeMonitor()

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.proxyhelper.networkmonitor")
    private var lastInterface: String?

    var onChange: (@MainActor () -> Void)?

    private init() {}

    func start() {
        stop()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let interface = path.availableInterfaces.first?.name
            Task { @MainActor in
                guard let self else { return }
                guard self.lastInterface != nil else {
                    // 首次回调记录基线，不触发回调，避免刚启动就重复 enable
                    self.lastInterface = interface ?? ""
                    return
                }
                if interface != self.lastInterface {
                    self.lastInterface = interface
                    self.onChange?()
                }
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        lastInterface = nil
        onChange = nil
    }
}
