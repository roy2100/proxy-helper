import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("mihomo 路径") {
                HStack {
                    TextField("留空则自动检测 Homebrew 路径", text: $state.mihomoPath)
                    Button("选择...") { pickFile(binding: $state.mihomoPath) }
                }
                Text("当前：\(state.effectiveMihomoPath.isEmpty ? "未找到，请先 brew install mihomo" : state.effectiveMihomoPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("配置文件夹") {
                HStack {
                    TextField("存放 .yaml 配置文件的目录", text: $state.configFolderPath)
                    Button("选择...") { pickFolder(binding: $state.configFolderPath) }
                }
                Text("应用会自动扫描该目录下所有 .yaml / .yml 文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !state.configFolderPath.isEmpty {
                    let configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
                    if configs.isEmpty {
                        Text("未找到配置文件").font(.caption).foregroundStyle(.red)
                    } else {
                        ForEach(configs) { c in
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(c.name).font(.caption)
                                Spacer()
                                Text(c.modifiedAt, style: .relative)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500)
        .onAppear {
            if !state.configFolderPath.isEmpty {
                ConfigManager.shared.startWatching(folderPath: state.configFolderPath) {
                    state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
                }
            }
        }
        .onChange(of: state.configFolderPath) {
            state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
            ConfigManager.shared.startWatching(folderPath: state.configFolderPath) {
                state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
            }
        }
    }

    func pickFile(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK {
                binding.wrappedValue = panel.url?.path(percentEncoded: false) ?? ""
            }
        }
    }

    func pickFolder(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择文件夹"
        panel.begin { response in
            if response == .OK {
                binding.wrappedValue = panel.url?.path(percentEncoded: false) ?? ""
            }
        }
    }
}
