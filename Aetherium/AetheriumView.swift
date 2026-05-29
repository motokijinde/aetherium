import SwiftUI

struct MessageBubble: View {
    let message: Message
    let speakerName: String
    let isLoadingActive: Bool
    var isUser: Bool { message.role == "user" }
    @State private var dotOpacity: [Double] = [1.0, 0.6, 0.6]
    @State private var hoveredStatIndex: Int? = nil
    var body: some View {
        if message.role == "system" {
            HStack(spacing: 8) {
                Rectangle().frame(height: 0.5).foregroundColor(.secondary.opacity(0.3))
                Text(message.content).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).fixedSize()
                Rectangle().frame(height: 0.5).foregroundColor(.secondary.opacity(0.3))
            }
            .padding(.horizontal, 24).padding(.vertical, 4)
        } else {
        HStack(alignment: .bottom, spacing: 10) {
            if !isUser { Image(systemName: "waveform.circle.fill").font(.system(size: 32)).foregroundStyle(Color.green.gradient).padding(.bottom, 2) } else { Spacer() }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "あなた" : speakerName).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    if message.content.isEmpty && isLoadingActive && !isUser {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle().fill(Color.blue).frame(width: 6, height: 6)
                                    .opacity(dotOpacity[index])
                            }
                        }.padding(.horizontal, 14).padding(.vertical, 10).onAppear {
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dotOpacity[0] = 0.3 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dotOpacity[1] = 0.3 }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dotOpacity[2] = 0.3 }
                            }
                        }
                    } else {
                        Text(message.content).padding(.horizontal, 14).padding(.vertical, 10).background(isUser ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.gray.opacity(0.15).gradient)).foregroundColor(isUser ? .white : .primary).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).textSelection(.enabled)
                    }
                    if let sources = message.searchSources, !sources.isEmpty, !isUser {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                Image(systemName: "globe.asia.australia").font(.system(size: 7))
                                Text("Web検索 \(sources.count)件").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundColor(.secondary)
                            ForEach(sources) { source in
                                Link(destination: URL(string: source.url) ?? URL(string: "https://example.com")!) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link").font(.system(size: 7)).foregroundColor(.blue)
                                        Text(source.title).font(.system(size: 8)).lineLimit(1).foregroundColor(.primary)
                                        Spacer(minLength: 0)
                                        Text(URL(string: source.url)?.host ?? "").font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.06))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 4)
                    }
                    if let stats = message.stats, !isUser, !message.content.isEmpty {
                        HStack(spacing: 3) {
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill").font(.system(size: 7))
                                Text(String(format: "%.1f t/s", stats.tokensPerSecond ?? 0)).font(.system(size: 8, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                            .onHover { hovering in
                                hoveredStatIndex = hovering ? 0 : nil
                            }
                            .overlay(alignment: .bottom) {
                                if hoveredStatIndex == 0 {
                                    Text("トークン生成速度")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.8))
                                        .cornerRadius(4)
                                        .offset(y: 28)
                                        .zIndex(1)
                                }
                            }

                            HStack(spacing: 2) {
                                Image(systemName: "tag").font(.system(size: 7))
                                Text(String(format: "%d tokens", stats.completionTokens)).font(.system(size: 8, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                            .onHover { hovering in
                                hoveredStatIndex = hovering ? 1 : nil
                            }
                            .overlay(alignment: .bottom) {
                                if hoveredStatIndex == 1 {
                                    Text("生成トークン数")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.8))
                                        .cornerRadius(4)
                                        .offset(y: 28)
                                        .zIndex(1)
                                }
                            }

                            HStack(spacing: 2) {
                                Image(systemName: "clock").font(.system(size: 7))
                                Text(String(format: "%.1f second", stats.ttft ?? 0)).font(.system(size: 8, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                            .onHover { hovering in
                                hoveredStatIndex = hovering ? 2 : nil
                            }
                            .overlay(alignment: .bottom) {
                                if hoveredStatIndex == 2 {
                                    Text("最初のトークンまでの時間")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.8))
                                        .cornerRadius(4)
                                        .offset(y: 28)
                                        .zIndex(1)
                                }
                            }
                        }
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                    }
                }
            }
            if isUser { Image(systemName: "person.crop.circle.fill").font(.system(size: 32)).foregroundStyle(Color.blue.gradient).padding(.bottom, 2) } else { Spacer() }
        }.padding(.horizontal, 16).padding(.vertical, 8)
        } // end else (non-system message)
    }
}

struct AetheriumView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var inputText = ""
    @State private var rotationAngle: Double = 0

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
                            settingRow(title: "Voice", icon: "mouth", selection: $vm.selectedSpeakerID, options: vm.displaySpeakers, placeholder: "VOICEVOXを起動してください")
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Speed: \(String(format: "%.2f", vm.speechSpeed))x", systemImage: "speedometer").font(.subheadline).bold()
                                Slider(value: $vm.speechSpeed, in: 0.5...2.0)
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

                            if (vm.aiProvider == .ollama && vm.models.isEmpty) || vm.displaySpeakers.isEmpty {
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
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) { ForEach(vm.messages, id: \.id) { msg in let isLastMsg = (msg.id == vm.messages.last?.id); let isLoadingActive = isLastMsg && msg.role == "assistant" && vm.isGenerating; MessageBubble(message: msg, speakerName: vm.currentSpeakerName, isLoadingActive: isLoadingActive) } }.padding(.vertical, 10)
                                Spacer().id("bottom")
                            }
                            .onChange(of: vm.messages.last?.content) { _, _ in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            TextField("メッセージを入力...", text: $inputText).textFieldStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10).background(Capsule().fill(Color.primary.opacity(0.05))).onSubmit {
                                let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !vm.isGenerating && !t.isEmpty {
                                    inputText = ""
                                    vm.sendMessage(t)
                                }
                            }
                            if vm.isGenerating || vm.isAudioPlaying {
                                Button(action: { vm.stopGeneration() }) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(Color.red.gradient)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button(action: {
                                    let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !vm.isGenerating && !t.isEmpty {
                                        inputText = ""
                                        vm.sendMessage(t)
                                    }
                                }) {
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
