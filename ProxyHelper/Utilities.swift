import Foundation

func formatBytes(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1024
    let mb = kb / 1024
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    if kb >= 1 { return String(format: "%.0f KB", kb) }
    return "\(bytes) B"
}
