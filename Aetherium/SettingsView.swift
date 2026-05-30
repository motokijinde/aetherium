import SwiftUI

/// ネイティブの設定ウィンドウ（⌘,）。接続URLと音声まわりを設定・永続化する。
struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("接続", systemImage: "network") }
            voiceTab
                .tabItem { Label("音声", systemImage: "speaker.wave.2") }
        }
        .frame(width: 460, height: 320)
        // AIが生成中は設定変更を防ぐ（メッセージ間の待機中は変更可）。
        .disabled(vm.isGenerating)
        .overlay(alignment: .bottom) {
            if vm.isGenerating {
                Text("生成中は変更できません")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: - 接続（各種URL）

    private var connectionTab: some View {
        Form {
            Section("サーバー") {
                LabeledContent("Ollama API URL") {
                    TextField("", text: $vm.llmServerURL, prompt: Text("http://127.0.0.1:11434/v1"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await vm.fetchModels() } }
                }
                LabeledContent("VOICEVOX API URL") {
                    TextField("", text: $vm.voicevoxURL, prompt: Text("http://127.0.0.1:50021"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await vm.fetchVVSpeakers() } }
                }
                LabeledContent("SearXNG URL") {
                    TextField("", text: $vm.searxngURL, prompt: Text("http://localhost:8080"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Text("URLを変更したら Enter で再取得されます。")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("デフォルトに戻す") { vm.resetServerURLsToDefaults() }
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 音声（VOICEVOX）

    private var voiceTab: some View {
        Form {
            Section("読み上げ音声") {
                if vm.displaySpeakers.isEmpty {
                    HStack {
                        Text("VOICEVOXを起動してください").foregroundColor(.secondary)
                        Spacer()
                        Button("再取得") { Task { await vm.fetchVVSpeakers() } }
                    }
                } else {
                    Picker("話者", selection: $vm.selectedSpeakerID) {
                        ForEach(vm.displaySpeakers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Speed: \(String(format: "%.2f", vm.speechSpeed))x")
                    Slider(value: $vm.speechSpeed, in: 0.5...2.0)
                }
            }
            Text("音声読み上げのオン/オフはチャット画面の入力欄で切り替えます。")
                .font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
