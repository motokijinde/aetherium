import SwiftUI
import AppKit

// 複数行入力欄（NSTextView ラッパー）
// Enter で送信、Shift+Enter で改行。改行はそのまま text に保持される。
// 入力内容に応じて高さが 1〜5 行の範囲で自動伸縮し、5行を超えるとスクロールする。
struct MultilineInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var maxLines: Int = 5
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.string = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        recalculateHeight(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // 内容の行数に応じた高さを計算し、1〜maxLines 行でクランプして height に反映する
    func recalculateHeight(_ textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = lm.defaultLineHeight(for: font)
        let inset = textView.textContainerInset.height * 2
        let minH = ceil(lineHeight) + inset
        let maxH = ceil(lineHeight * CGFloat(maxLines)) + inset
        let contentH = ceil(lm.usedRect(for: tc).height) + inset
        let newH = min(max(contentH, minH), maxH)
        if abs(newH - height) > 0.5 {
            DispatchQueue.main.async { height = newH }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInputField
        init(_ parent: MultilineInputField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.recalculateHeight(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftPressed {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}

struct AetheriumView: View {
    @StateObject private var vm = ChatViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var inputText = ""
    @State private var rotationAngle: Double = 0
    @State private var inputHeight: CGFloat = 38

    private func submitInput() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vm.isGenerating && !t.isEmpty {
            inputText = ""
            vm.sendMessage(t)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !vm.isInSession {
                    VStack(spacing: 40) {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles").font(.system(size: 50)).foregroundStyle(Color.blue.gradient)
                            Text("Aetherium").font(.system(size: 40, weight: .black, design: .rounded))
                        }
                        VStack(alignment: .leading, spacing: 25) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("AI Provider", systemImage: "cpu.fill").font(.subheadline).bold()
                                Picker("", selection: $vm.aiProvider) {
                                    ForEach(AIProvider.allCases, id: \.self) { provider in
                                        Text(provider.rawValue).tag(provider)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .onChange(of: vm.aiProvider) { _, newValue in
                                    if newValue == .appleIntelligence {
                                        vm.setupFoundationSession()
                                    } else if !vm.selectedModel.isEmpty {
                                        Task { await vm.fetchModelInfo(for: vm.selectedModel) }
                                    }
                                }
                            }
                            if vm.aiProvider == .ollama {
                                settingRow(title: "Model", icon: "cpu", content: $vm.selectedModel, options: vm.models, placeholder: "LLMを起動してください")
                                    .onChange(of: vm.selectedModel) { _, newModel in
                                        guard !newModel.isEmpty else { return }
                                        Task { await vm.fetchModelInfo(for: newModel) }
                                    }
                                VStack(alignment: .leading, spacing: 8) {
                                    let sizes = ChatViewModel.ollamaContextSizeOptions
                                    Label("Context Size: \(contextSizeLabel(vm.ollamaContextSize))", systemImage: "memorychip").font(.subheadline).bold()
                                    Slider(
                                        value: Binding(
                                            get: { Double(sizes.firstIndex(of: vm.ollamaContextSize) ?? 0) },
                                            set: { vm.ollamaContextSize = sizes[Int($0.rounded())] }
                                        ),
                                        in: 0...Double(sizes.count - 1),
                                        step: 1
                                    )
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    if vm.ollamaToolsSupported {
                                        Toggle(isOn: $vm.webSearchEnabled) {
                                            Label("Web検索 (SearXNG)", systemImage: "magnifyingglass").font(.subheadline).bold()
                                        }
                                        .toggleStyle(.switch)
                                        if vm.webSearchEnabled {
                                            TextField("SearXNG URL", text: $vm.searxngURL)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.caption)
                                        }
                                    } else if !vm.models.isEmpty {
                                        Label("Web検索 (SearXNG)", systemImage: "magnifyingglass").font(.subheadline).bold()
                                        Text("このモデルはツール呼び出し非対応").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Apple Intelligence", systemImage: "apple.intelligence").font(.subheadline).bold()
                                    if let error = vm.appleIntelligenceError {
                                        Text(error).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("オンデバイス AI が利用可能です").font(.caption).foregroundColor(.green)
                                    }
                                    Toggle(isOn: $vm.webSearchEnabled) {
                                        Label("Web検索 (SearXNG)", systemImage: "magnifyingglass")
                                            .font(.caption)
                                    }
                                    .toggleStyle(.switch)
                                    .disabled(vm.appleIntelligenceError != nil)
                                    .onChange(of: vm.webSearchEnabled) { _, _ in
                                        vm.setupFoundationSession()
                                    }
                                    if vm.webSearchEnabled {
                                        TextField("SearXNG URL", text: $vm.searxngURL)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.caption)
                                            .onSubmit { vm.setupFoundationSession() }
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $vm.voiceEnabled) {
                                    Label("音声読み上げ (VOICEVOX)", systemImage: "speaker.wave.2.fill").font(.subheadline).bold()
                                }
                                .toggleStyle(.switch)
                            }
                            if vm.voiceEnabled {
                                settingRow(title: "Voice", icon: "mouth", selection: $vm.selectedSpeakerID, options: vm.displaySpeakers, placeholder: "VOICEVOXを起動してください")
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Speed: \(String(format: "%.2f", vm.speechSpeed))x", systemImage: "speedometer").font(.subheadline).bold()
                                    Slider(value: $vm.speechSpeed, in: 0.5...2.0)
                                }
                            }
                        }.padding(30).background(.thinMaterial).cornerRadius(24).frame(width: 380)

                        VStack(spacing: 12) {
                            Button(action: { withAnimation(.spring()) { vm.isInSession = true } }) {
                                Text("Start Session").font(.headline).frame(width: 220, height: 40)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .clipShape(Capsule())
                            .disabled(!vm.canStartSession)

                            if (vm.aiProvider == .ollama && vm.models.isEmpty) || (vm.voiceEnabled && vm.displaySpeakers.isEmpty) {
                                Button(action: { Task { await vm.fetchAll() } }) {
                                    Label(vm.isFetching ? "接続中..." : "再接続", systemImage: "arrow.clockwise")
                                }
                                .disabled(vm.isFetching)
                                .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await vm.fetchAll() }
                } else {
                    VStack(spacing: 0) {
                        // 会話全体を1個のWebViewで描画し、スクロールはWebView内部に任せる
                        // （メッセージ毎にWebViewを並べる方式の重さ・スクロール相性問題を回避）。
                        ConversationWebView(
                            messages: vm.messages,
                            dark: colorScheme == .dark,
                            isGenerating: vm.isGenerating,
                            speakerName: vm.currentSpeakerName
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack(spacing: 12) {
                            MultilineInputField(text: $inputText, height: $inputHeight, onSubmit: { submitInput() })
                                .frame(height: inputHeight)
                                .padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.05)))
                            if vm.isGenerating || vm.isAudioPlaying {
                                Button(action: { vm.stopGeneration() }) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(Color.red.gradient)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button(action: { submitInput() }) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Color.blue.gradient))
                                }
                                .buttonStyle(.plain)
                                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 12).background(.ultraThinMaterial)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            HStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    ZStack {
                                        Image(systemName: "waveform").foregroundStyle(Color.secondary).opacity((vm.isGenerating || vm.isAudioPlaying) ? 0 : 1)
                                        Image(systemName: "rays").rotationEffect(.degrees(rotationAngle)).foregroundStyle(Color.blue.gradient).opacity((vm.isGenerating || vm.isAudioPlaying) ? 1 : 0).onAppear { rotationAngle = 0; withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { rotationAngle = 360 } }
                                    }.frame(width: 18)
                                    Text(vm.isGenerating ? "Generating..." : (vm.isAudioPlaying ? "Playing..." : "Ready")).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor((vm.isGenerating || vm.isAudioPlaying) ? .primary : .secondary)
                                }
                                .padding(.leading, 8).padding(.trailing, vm.isGenerating ? 8 : 4).padding(.vertical, 4)
                                HStack(spacing: 4) {
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.secondary.opacity(0.15))
                                            .frame(width: 56, height: 4)
                                        Capsule()
                                            .fill(contextIndicatorColor(vm.contextUsageRatio).gradient)
                                            .frame(width: max(0, 56 * vm.contextUsageRatio), height: 4)
                                            .animation(.easeInOut(duration: 0.4), value: vm.contextUsageRatio)
                                    }
                                    Text("\(Int(vm.contextUsageRatio * 100))%")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(contextIndicatorColor(vm.contextUsageRatio))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .animation(.easeInOut(duration: 0.4), value: vm.contextUsageRatio)
                                }
                                .help(vm.aiProvider == .ollama
                                    ? "コンテキスト使用量: \(vm.ollamaContextUsedTokens) / \(vm.ollamaContextSize) tokens (\(Int(vm.contextUsageRatio * 100))%)"
                                    : "推定コンテキスト使用量: \(Int(vm.contextUsageRatio * 100))%（約4096トークン想定）")
                                Divider().frame(height: 16).padding(.horizontal, 2)
                                Button(action: { vm.clearContext() }) {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(vm.isGenerating)
                                .help("コンテキストをクリア（会話履歴はそのまま残ります）")
                                Divider().frame(height: 16).padding(.horizontal, 2)
                                Button(action: { withAnimation { inputText = ""; vm.resetSession() } }) { Text("Exit").fontWeight(.medium).foregroundColor(.red) }.buttonStyle(.bordered).controlSize(.small)
                                Spacer().frame(width: 6)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Aetherium")
            .navigationSubtitle(vm.isInSession ? "Session with \(vm.currentSpeakerName) (\(vm.activeModelLabel))" : "Settings")
        }
        .frame(minWidth: 600, minHeight: 700)
    }

    private func settingRow(title: String, icon: String, content: Binding<String>, options: [String], placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline).bold()
            if options.isEmpty { Text(placeholder).font(.caption).foregroundColor(.red) } else {
                Picker("", selection: content) { ForEach(options, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).labelsHidden()
            }
        }
    }

    private func contextIndicatorColor(_ ratio: Double) -> Color {
        if ratio < 0.6 { return .blue }
        if ratio < 0.8 { return .orange }
        return .red
    }

    private func contextSizeLabel(_ size: Int) -> String {
        let k = size / 1024
        return "\(k)K"
    }



    private func settingRow(title: String, icon: String, selection: Binding<Int>, options: [(id: Int, name: String)], placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline).bold()
            if options.isEmpty { Text(placeholder).font(.caption).foregroundColor(.red) } else {
                Picker("", selection: selection) { ForEach(options, id: \.id) { Text($0.name).tag($0.id) } }.pickerStyle(.menu).labelsHidden()
            }
        }
    }
}
