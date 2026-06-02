import SwiftUI
import AppKit

/// SwiftUIの .help() がツールチップを出さないことがあるため、
/// 下地の NSView に toolTip を直接設定して確実にホバー表示させる。
struct Tooltip: NSViewRepresentable {
    let text: String
    init(_ text: String) { self.text = text }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.toolTip = text
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = text }
}

/// ネイティブの設定ウィンドウ（⌘,）。接続URLと音声まわりを設定・永続化する。
struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("接続", systemImage: "network") }
            instructionsTab
                .tabItem { Label("指示", systemImage: "person.text.rectangle") }
            // 生成パラメータはOllama固有のため、Ollama利用時のみ表示する。
            if vm.aiProvider == .ollama {
                generationTab
                    .tabItem { Label("生成", systemImage: "slider.horizontal.3") }
            }
            voiceTab
                .tabItem { Label("音声", systemImage: "speaker.wave.2") }
        }
        .frame(width: 460, height: 360)
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
                LabeledContent("Web検索の取得件数") {
                    Stepper("\(vm.webSearchResultCount) 件", value: $vm.webSearchResultCount, in: 1...10)
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

    // MARK: - 指示（カスタム指示）

    private var instructionsTab: some View {
        Form {
            Section {
                TextField("あなたの名前", text: $vm.userName, prompt: Text("未設定（「あなた」と表示）"))
            } header: {
                Text("あなたの呼び名")
            } footer: {
                Text("設定すると、チャットでの表示名になり、AI もこの名前で呼びかけます。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                Toggle("指示を有効にする", isOn: $vm.customInstructionsEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AIへの指示")
                    TextEditor(text: $vm.customInstructions)
                        .font(.body)
                        .frame(minHeight: 160)
                        .opacity(vm.customInstructionsEnabled ? 1 : 0.4)
                        .disabled(!vm.customInstructionsEnabled)
                        .overlay(alignment: .topLeading) {
                            if vm.customInstructions.isEmpty {
                                Text("例：一人称は「あーし」で、常に明るく元気にギャル語で接してください。")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            } header: {
                Text("AIは、ここに書いた内容を毎回の会話で念頭に置いて応答します。")
            } footer: {
                Text("Apple Intelligence では、変更は次のコンテキストのリセット以降に反映されます。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 生成（Ollama生成パラメータ）

    private var generationTab: some View {
        Form {
            Section {
                doubleRow("Temperature", "ばらつきの大きさ。低いほど安定、高いほど多様。\n範囲: 0.0〜2.0 ／ 既定: 0.8",
                          \.temperature, default: 0.8)
                doubleRow("Top P", "上位の累積確率で候補を絞る。\n範囲: 0.0〜1.0 ／ 既定: 0.9",
                          \.topP, default: 0.9)
                intRow("Top K", "上位いくつの候補から選ぶか。\n範囲: 0〜100 ／ 既定: 40",
                       \.topK, default: 40)
                doubleRow("Min P", "最有力候補に対する相対しきい値で候補を足切り。\n範囲: 0.0〜1.0 ／ 既定: 0.05",
                          \.minP, default: 0.05)
                doubleRow("Repeat Penalty", "繰り返しへのペナルティ。高いほど反復を抑える。\n範囲: 0.9〜1.5 ／ 既定: 1.1",
                          \.repeatPenalty, default: 1.1)
                intRow("Seed", "乱数の種。固定すると同じ入力で毎回ほぼ同じ応答になる。\n範囲: 任意の整数 ／ 既定: ランダム",
                       \.seed, default: 0)
            } header: {
                Text("出力のばらつき・品質")
            }
            Section {
                intRow("Num Predict", "生成する最大トークン数。-1で無制限。\n範囲: -1 または 1以上 ／ 既定: -1（無制限）",
                       \.numPredict, default: -1)
                stringRow("Stop", "指定した文字列が出たら生成を停止する（停止シーケンス）。\n例: 「###」など ／ 既定: なし",
                          \.stop, default: "")
            } header: {
                Text("長さ・停止コントロール")
            }
            Section {
                intRow("Num GPU", "GPUに載せるモデル層の数。0でCPUのみ。\n範囲: 0以上 ／ 既定: 自動",
                       \.numGpu, default: 0)
                intRow("Num Thread", "生成に使うCPUスレッド数。\n範囲: 1以上 ／ 既定: 自動（物理コア数）",
                       \.numThread, default: 4)
                intRow("Num Batch", "一度に処理するバッチサイズ。大きいほど速い場合があるがメモリを消費。\n範囲: 1以上 ／ 既定: 512",
                       \.numBatch, default: 512)
            } header: {
                Text("リソース・速度まわり")
            } footer: {
                Text("チェックを入れた項目だけが適用されます（外すと未指定＝Ollamaの既定値）。各項目の ⓘ にカーソルを合わせると、設定値の範囲と説明が表示されます。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 生成パラメータ1行（小数）。チェックOFF=未指定（Ollama既定）、ON=値を編集して送信。
    private func doubleRow(_ name: String, _ info: String,
                           _ kp: WritableKeyPath<OllamaOptions, Double?>, default def: Double) -> some View {
        let enabled = vm.ollamaOptions[keyPath: kp] != nil
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.ollamaOptions[keyPath: kp] != nil },
                set: { on in vm.ollamaOptions[keyPath: kp] = on ? def : nil }
            )) { Text(name) }
            .toggleStyle(.checkbox)
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                .overlay(Tooltip(info))
            Spacer()
            TextField("", value: Binding(
                get: { vm.ollamaOptions[keyPath: kp] ?? def },
                set: { vm.ollamaOptions[keyPath: kp] = $0 }
            ), format: .number)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .frame(width: 70).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
    }

    /// 生成パラメータ1行（整数）。
    private func intRow(_ name: String, _ info: String,
                        _ kp: WritableKeyPath<OllamaOptions, Int?>, default def: Int) -> some View {
        let enabled = vm.ollamaOptions[keyPath: kp] != nil
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.ollamaOptions[keyPath: kp] != nil },
                set: { on in vm.ollamaOptions[keyPath: kp] = on ? def : nil }
            )) { Text(name) }
            .toggleStyle(.checkbox)
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                .overlay(Tooltip(info))
            Spacer()
            TextField("", value: Binding(
                get: { vm.ollamaOptions[keyPath: kp] ?? def },
                set: { vm.ollamaOptions[keyPath: kp] = $0 }
            ), format: .number)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .frame(width: 70).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
    }

    /// 生成パラメータ1行（文字列）。
    private func stringRow(_ name: String, _ info: String,
                          _ kp: WritableKeyPath<OllamaOptions, String?>, default def: String) -> some View {
        let enabled = vm.ollamaOptions[keyPath: kp] != nil
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { vm.ollamaOptions[keyPath: kp] != nil },
                set: { on in vm.ollamaOptions[keyPath: kp] = on ? def : nil }
            )) { Text(name) }
            .toggleStyle(.checkbox)
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                .overlay(Tooltip(info))
            Spacer()
            TextField("", text: Binding(
                get: { vm.ollamaOptions[keyPath: kp] ?? def },
                set: { vm.ollamaOptions[keyPath: kp] = $0 }
            ))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .frame(width: 120).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
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
