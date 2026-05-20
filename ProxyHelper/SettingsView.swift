import SwiftUI

private struct FixedLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
                .frame(width: 120, alignment: .leading)
            configuration.content
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape.fill") {
                GeneralPane()
            }
        }
        .frame(width: 620, height: 300)
    }
}

private struct GeneralPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                LabeledContent("路径") {
                    HStack {
                        TextField("留空则自动检测 Homebrew 路径", text: $state.mihomoPath)
                            .lineLimit(1)
                        Button("选择…") { pickFile() }
                    }
                }
                LabeledContent("当前") {
                    Text(
                        state.effectiveMihomoPath.isEmpty
                            ? "未找到，请先 brew install mihomo"
                            : state.effectiveMihomoPath
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(state.effectiveMihomoPath)
                }
            } header: {
                Label("mihomo 路径", systemImage: "cpu")
            }

            Section {
                LabeledContent("目录") {
                    HStack {
                        TextField("存放 .yaml 配置文件的目录", text: $state.configFolderPath)
                            .lineLimit(1)
                        Button("选择…") { pickFolder() }
                    }
                }
                Text("自动扫描目录下所有 .yaml / .yml 文件；更改后需重启应用生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("配置文件夹", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
        .labeledContentStyle(FixedLabelStyle())
        .onAppear {
            guard !state.configFolderPath.isEmpty else { return }
            ConfigManager.shared.startWatching(folderPath: state.configFolderPath) {
                state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
            }
        }
        .onChange(of: state.configFolderPath) { _, newValue in
            state.configs = ConfigManager.shared.scan(folderPath: newValue)
            ConfigManager.shared.startWatching(folderPath: newValue) {
                state.configs = ConfigManager.shared.scan(folderPath: newValue)
            }
        }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK {
                state.mihomoPath = panel.url?.path(percentEncoded: false) ?? ""
            }
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择文件夹"
        panel.begin { response in
            if response == .OK {
                state.configFolderPath = panel.url?.path(percentEncoded: false) ?? ""
            }
        }
    }
}
