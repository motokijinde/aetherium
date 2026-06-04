import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 入力欄下のアイコンチップ（検索・思考・音声・添付・画像）の共通UI。
/// ON=青背景、OFF=薄背景、無効=フェードで状態を示す。マウスオーバーで背景を濃くして押せる感を出し、
/// `.help()` が出ない環境向けに NSView の toolTip（`Tooltip`）で説明をホバー表示する。
/// RAG管理ウィンドウの Add ボタンでも同じ見た目・サイズで使うため internal にしている。
struct ChipButton: View {
    let icon: String
    var isOn: Bool = false
    var isEnabled: Bool = true
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)  // アイコンの大小でボタンの縦横がブレないよう固定
                .foregroundStyle(isOn ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(fillColor))
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 && isEnabled }
        .background(Tooltip(help))
    }

    /// ホバー時は不透明度を上げて「押せる」感を出す。
    private var fillColor: Color {
        if isOn { return Color.blue.opacity(hovering ? 0.28 : 0.15) }
        return Color.primary.opacity(hovering ? 0.14 : 0.06)
    }
}

// ⌘V を横取りし、クリップボードに画像があれば添付に回す NSTextView。
// onPasteImage が true を返したら（画像を消費したら）テキスト貼り付けは行わない。
final class PastableTextView: NSTextView {
    var onPasteImage: (() -> Bool)?
    /// 未入力時に薄く表示するプレースホルダ。IME変換中は string にマーク中テキストが入るため自動で隠れる。
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    // isRichText=false だとテキスト型しか受け付けず、画像のみのクリップボードでは
    // Paste メニュー・⌘V が無効化され paste(_:) も呼ばれない。画像型を受理対象に加えて有効化する。
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }
    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        super.paste(sender)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholderString.isEmpty else { return }
        // 実テキストと同じ typingAttributes（フォント・段落スタイル）を使い、色だけ薄くする。
        // 行頭の起点（インセット＋行パディング）に合わせて描くことでベースラインが一致する。
        var attrs = typingAttributes
        attrs[.foregroundColor] = NSColor.placeholderTextColor
        if attrs[.font] == nil { attrs[.font] = font ?? .systemFont(ofSize: NSFont.systemFontSize) }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(x: x, y: textContainerInset.height,
                          width: bounds.width - x, height: bounds.height - textContainerInset.height)
        placeholderString.draw(in: rect, withAttributes: attrs)
    }
}

// 複数行入力欄（NSTextView ラッパー）
// Enter で送信、Shift+Enter で改行。改行はそのまま text に保持される。
// 入力内容に応じて高さが 1〜5 行の範囲で自動伸縮し、5行を超えるとスクロールする。
struct MultilineInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String = ""
    var maxLines: Int = 5
    var onSubmit: () -> Void
    /// クリップボード画像を消費したら true（テキスト貼り付けを抑止する）。
    var onPasteImage: () -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = PastableTextView()
        textView.onPasteImage = onPasteImage
        textView.placeholderString = placeholder
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
        // NSTextView.scrollableTextView() 相当の伸縮設定（高さ自動計算と相性を合わせる）。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // 縦は無制限にしないと usedRect が頭打ちになり、複数行の高さ計算が崩れる。
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PastableTextView else { return }
        textView.placeholderString = placeholder
        // IME変換中（マーク中テキストあり）は string を触らない。会話中はストリーミングで
        // 頻繁に updateNSView が走るため、ここで上書きすると変換中の文字が消えて入力不能になる。
        // それ以外で内容がズレているときだけ同期（送信後のクリア等の外部変更を反映）。
        if !textView.hasMarkedText() && textView.string != text {
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
    @EnvironmentObject var vm: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var inputText = ""
    @State private var rotationAngle: Double = 0
    @State private var inputHeight: CGFloat = 38
    // PDF出力用に live な会話 WebView を保持するブリッジ。
    @State private var exporter = ConversationExporter()
    // RAGドキュメント管理ウィンドウを開くための環境アクション（📚 Menu と同期インジケータが入口）。
    @Environment(\.openWindow) private var openWindow
    // エンプティステートの Provider セグメントの実測幅。モデル行を同じ幅に揃えるのに使う。
    @State private var providerPickerWidth: CGFloat = 0
    // ツールバーの同期インジケータ（RAG管理への入口）のホバー状態。
    @State private var syncIndicatorHovering = false

    private func submitInput() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本文が空でも添付があれば送れる。
        if !vm.isGenerating && (!t.isEmpty || !vm.pendingAttachments.isEmpty) {
            inputText = ""
            vm.sendMessage(t)
        }
    }

    /// 送信ボタン・Enter を無効化すべきか（本文も添付も無いとき）。
    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.pendingAttachments.isEmpty
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { vm.addImageAttachment(url) }
    }

    private func pickFiles() {
        // 拡張子では絞らず全ファイル選択可にし、テキストとして読めるかは取り込み時に判定する。
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { vm.addFileAttachments(panel.urls) }
    }

    /// 会話ログのデフォルトファイル名（会話ログ_yyyyMMdd_HHmm）。
    private func exportFileName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "会話ログ_\(f.string(from: Date())).\(ext)"
    }

    /// 表示中の会話を Markdown で保存する。
    private func saveMarkdown() {
        let md = ConversationMarkdown.build(messages: vm.messages, speakerName: vm.currentSpeakerName,
                                            modelName: vm.activeModelLabel, userName: vm.displayUserName)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFileName(ext: "md")
        if let t = UTType(filenameExtension: "md") { panel.allowedContentTypes = [t] }
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 表示中の会話を PDF（見た目そのまま）で保存する。
    private func savePDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFileName(ext: "pdf")
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url {
            exporter.exportPDF(to: url) { _ in }
        }
    }

    /// ⌘V 時にクリップボードの画像を添付に回す。画像が無ければ false（通常テキスト貼り付けへ）。
    private func handlePasteImage() -> Bool {
        let pb = NSPasteboard.general
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let d = data else { return false }
        return vm.pasteImage(d)
    }

    /// 添付ボタン用の単発アクションチップ（既存トグルOFFと同系の見た目）。
    /// 生成中も「次の送信の準備」として押せるよう、常時有効。
    private func actionChip(icon: String, help: String, action: @escaping () -> Void) -> some View {
        ChipButton(icon: icon, help: help, action: action)
    }

    /// 入力欄の上に並ぶ添付プレビュー（×で個別削除）。
    @ViewBuilder
    private func attachmentPreview(_ att: Attachment) -> some View {
        HStack(spacing: 6) {
            if att.kind == .image, let data = Data(base64Encoded: att.payload), let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.text.fill").font(.system(size: 14)).foregroundStyle(Color.secondary)
            }
            Text(att.filename).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 130)
            Button(action: { vm.removeAttachment(att.id) }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.secondary)
            }.buttonStyle(.plain).help("添付を外す")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    /// 入力欄下の機能トグル（検索・思考・音声）の共通チップUI。
    private func toggleChip(icon: String, isOn: Bool, isEnabled: Bool,
                            help: String, action: @escaping () -> Void) -> some View {
        ChipButton(icon: icon, isOn: isOn, isEnabled: isEnabled, help: help, action: action)
    }

    /// 🔍 トグルのツールチップ（無効理由を説明）。
    private var webSearchHelp: String {
        if vm.contextHasExchange { return "会話中は変更できません。コンテキストをクリアすると変更できます" }
        if vm.aiProvider == .ollama && !vm.ollamaToolsSupported { return "このモデルはツール呼び出し非対応です" }
        return vm.webSearchEnabled ? "Web検索 (SearXNG): ON" : "Web検索 (SearXNG): OFF"
    }

    /// 📚 RAGトグルのツールチップ（無効理由を説明）。
    private var ragHelp: String {
        if vm.contextHasExchange { return "会話中は変更できません。コンテキストをクリアすると変更できます" }
        return vm.ragEnabled ? "RAG検索: ON" : "RAG検索: OFF"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 会話全体を1個のWebViewで描画し、スクロールはWebView内部に任せる
                // （メッセージ毎にWebViewを並べる方式の重さ・スクロール相性問題を回避）。
                ConversationWebView(
                    messages: vm.messages,
                    dark: colorScheme == .dark,
                    isGenerating: vm.isGenerating,
                    speakerName: vm.currentSpeakerName,
                    modelName: vm.activeModelLabel,
                    userName: vm.displayUserName,
                    revision: vm.chatRevision,
                    exporter: exporter,
                    onRegenerate: { vm.regenerate(messageID: $0) },
                    onSelectVariant: { vm.selectVariant(messageID: $0, dir: $1) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 最初の発言前は会話が空なので、エンプティステートを重ねて表示する
                // （ConversationWebView は背景透過なので overlay で重ねられる）。
                .overlay {
                    if vm.messages.isEmpty { emptyState }
                }
                inputArea
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    primaryToolbar
                }
            }
            .navigationTitle("Aetherium")
            .navigationSubtitle(vm.contextHasExchange
                ? "Session with \(vm.currentSpeakerName) (\(vm.activeModelLabel))"
                : vm.activeModelLabel)
            .task {
                await vm.fetchAll()
                // 起動時にApple Intelligenceが復元されていたらセッションを初期化する。
                if vm.aiProvider == .appleIntelligence { vm.setupFoundationSession() }
            }
        }
        .alert("添付エラー", isPresented: Binding(
            get: { vm.attachmentError != nil },
            set: { if !$0 { vm.attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.attachmentError = nil }
        } message: {
            Text(vm.attachmentError ?? "")
        }
        .frame(minWidth: 600, minHeight: 700)
    }

    // MARK: - エンプティステート

    /// 最初の発言前にチャット領域中央へ重ねるロゴ＋一文＋プロバイダ／モデル選択。
    /// プロバイダ・モデルは開始前に一度選べばよいため、ここ（発言したら消える空状態）に置く。
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 50)).foregroundStyle(Color.blue.gradient)
            Text("Aetherium").font(.system(size: 40, weight: .black, design: .rounded))
            Text("メッセージを入力して会話を始めましょう")
                .font(.subheadline).foregroundColor(.secondary)
            providerModelSelection
                .fixedSize(horizontal: true, vertical: false)  // カードを中身（＝セグメント幅）にフィットさせる
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - プロバイダ／モデル選択（エンプティステート内）

    @ViewBuilder
    private var providerModelSelection: some View {
        VStack(spacing: 14) {
            Picker("", selection: $vm.aiProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()  // セグメントは伸びないので自然な幅にし、これをカード幅の基準にする
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { providerPickerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in providerPickerWidth = w }
            })
            .onChange(of: vm.aiProvider) { _, newValue in
                if newValue == .appleIntelligence {
                    vm.setupFoundationSession()
                } else if !vm.selectedModel.isEmpty {
                    Task { await vm.fetchModelInfo(for: vm.selectedModel) }
                }
            }
            if vm.aiProvider == .ollama {
                if vm.models.isEmpty {
                    VStack(spacing: 8) {
                        Text("LLMを起動してください").font(.caption).foregroundColor(.red)
                        Button(action: { Task { await vm.fetchAll() } }) {
                            Label(vm.isFetching ? "Connecting…" : "Reconnect", systemImage: "arrow.clockwise")
                        }
                        .disabled(vm.isFetching).font(.subheadline)
                    }
                } else {
                    HStack(spacing: 8) {
                        Picker("", selection: $vm.selectedModel) {
                            ForEach(vm.models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: vm.selectedModel) { _, newModel in
                            guard !newModel.isEmpty else { return }
                            Task { await vm.fetchModelInfo(for: newModel) }
                        }
                        // チャットの入力欄チップと同じ：マウスオーバーで背景が変わり、日本語ヘルプも出る。
                        ChipButton(icon: "arrow.clockwise", isEnabled: !vm.isFetching,
                                   help: "モデルを再取得") { Task { await vm.fetchModels() } }
                    }
                    // セグメントの実測幅に合わせて、再読み込みボタン込みの行幅をピッタリ揃える。
                    .frame(width: providerPickerWidth > 0 ? providerPickerWidth : nil)
                }
            } else {
                if let error = vm.appleIntelligenceError {
                    Text(error).font(.caption).foregroundColor(.red)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("オンデバイス AI が利用可能です").font(.caption).foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - 入力欄

    private var inputArea: some View {
        VStack(spacing: 8) {
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.pendingAttachments) { att in
                            attachmentPreview(att)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            MultilineInputField(text: $inputText, height: $inputHeight,
                                placeholder: "メッセージを入力…",
                                onSubmit: { submitInput() },
                                onPasteImage: { handlePasteImage() })
                .frame(height: inputHeight)
            HStack(spacing: 8) {
                // 🌐 Web検索トグル（コンテキストが空のときだけ切替可）
                toggleChip(icon: "globe",
                           isOn: vm.webSearchEnabled, isEnabled: vm.canToggleWebSearch,
                           help: webSearchHelp) {
                    vm.webSearchEnabled.toggle()
                    if vm.aiProvider == .appleIntelligence { vm.setupFoundationSession() }
                }
                // 📚 RAGトグル（Web検索と全く同じ：タップでON/OFF）。
                // Apple Intelligence は常に、Ollama はtool対応モデルのとき表示。
                // RAG管理画面へはツールバーの同期インジケータから開く。
                if vm.aiProvider == .appleIntelligence || (vm.aiProvider == .ollama && vm.ollamaToolsSupported) {
                    toggleChip(icon: "books.vertical",
                               isOn: vm.ragEnabled, isEnabled: vm.canToggleRAG,
                               help: ragHelp) {
                        vm.ragEnabled.toggle()
                        if vm.aiProvider == .appleIntelligence { vm.setupFoundationSession() }
                    }
                }
                // 💡 思考モードトグル（Ollamaで対応モデルのときだけ表示・常時切替可）
                if vm.aiProvider == .ollama && vm.ollamaThinkingSupported {
                    toggleChip(icon: vm.thinkingEnabled ? "lightbulb.fill" : "lightbulb",
                               isOn: vm.thinkingEnabled, isEnabled: true,
                               help: vm.thinkingEnabled ? "思考モード: ON" : "思考モード: OFF") {
                        vm.thinkingEnabled.toggle()
                    }
                }
                // 🔊 音声読み上げトグル（常時切替可）
                toggleChip(icon: vm.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                           isOn: vm.voiceEnabled, isEnabled: true,
                           help: vm.voiceEnabled ? "音声読み上げ: ON" : "音声読み上げ: OFF") {
                    vm.voiceEnabled.toggle()
                }
                // 添付はOllama経路のみ対応（Apple Intelligenceは対象外）。
                if vm.aiProvider == .ollama {
                    // 📎 ファイル添付（pdf/txt/md・常時／生成中も準備として可）。
                    actionChip(icon: "paperclip", help: "ファイルを添付 (pdf/txt/md)") { pickFiles() }
                    // 🖼️ 画像添付（Vision対応モデルのときだけ表示／生成中も準備として可）。
                    if vm.ollamaVisionSupported {
                        actionChip(icon: "photo", help: "画像を添付 (png/jpg)") { pickImage() }
                    }
                }
                Spacer()
                if vm.isGenerating || vm.isAudioPlaying {
                    Button(action: { vm.stopGeneration() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.red.gradient)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { submitInput() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSubmit ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.gray))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - ツールバー（右）

    @ViewBuilder
    private var primaryToolbar: some View {
        HStack(spacing: 8) {
            // RAG検索のON/OFFに関わらず常に表示（クリックで RAG ドキュメント管理を開く）。
            // 検索で使わなくても登録はできるし、管理画面を開く入口を常に残しておく。未同期時はデフォルト表示。
            Button(action: { openWindow(id: "rag-manager") }) {
                Group {
                    if let indicator = vm.ragSyncIndicator {
                        syncIndicatorText(indicator)
                    } else {
                        Text("📚 ドキュメント")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(syncIndicatorHovering ? Color.primary.opacity(0.12) : Color.clear))
            }
            .buttonStyle(.plain)
            .onHover { syncIndicatorHovering = $0 }
            .help("RAGドキュメント管理を開きます")
            Divider().frame(height: 16).padding(.horizontal, 2)
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "waveform").foregroundStyle(Color.secondary).opacity((vm.isGenerating || vm.isAudioPlaying) ? 0 : 1)
                    Image(systemName: "rays").rotationEffect(.degrees(rotationAngle)).foregroundStyle(Color.blue.gradient).opacity((vm.isGenerating || vm.isAudioPlaying) ? 1 : 0).onAppear { rotationAngle = 0; withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { rotationAngle = 360 } }
                }.frame(width: 18)
                Text(vm.isGenerating ? "Generating..." : (vm.isAudioPlaying ? "Playing..." : "Ready")).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor((vm.isGenerating || vm.isAudioPlaying) ? .primary : .secondary)
            }
            .padding(.trailing, vm.isGenerating ? 8 : 4).padding(.vertical, 4)
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
            Menu {
                Button("Markdown (.md)") { saveMarkdown() }
                Button("PDF (.pdf)") { savePDF() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(vm.isGenerating || !vm.messages.contains { $0.role == "user" })
            .help("会話ログを保存（Markdown / PDF）")
            Divider().frame(height: 16).padding(.horizontal, 2)
            // New Chat：会話を全消し＋プロバイダ再選択を解禁（確認ダイアログ無し・即実行）。
            Button(action: { inputText = ""; vm.resetSession() }) {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("会話を消して新規チャットを始めます")
        }
        .padding(.leading, 14).padding(.trailing, 10)  // 左14・右10で統一
    }

    /// 同期インジケータの表示文（ステータス＝日本語。絵文字で状態を示す）。
    private func syncIndicatorText(_ indicator: ChatViewModel.RAGSyncIndicator) -> Text {
        switch indicator {
        case .syncing(let c, let t): return Text("🔄 同期中 \(c)/\(t)")
        case .success(let t):        return Text("✅ \(t)/\(t)")
        case .partial(let done, let t): return Text("⚠️ \(done)/\(t)")
        case .allFailed:             return Text("⚠️ 同期失敗")
        case .lastSynced(let d):     return Text("🕐 最終同期 \(syncIndicatorTime(d))")
        }
    }

    private func syncIndicatorTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/dd HH:mm"
        return f.string(from: d)
    }

    private func contextIndicatorColor(_ ratio: Double) -> Color {
        if ratio < 0.6 { return .blue }
        if ratio < 0.8 { return .orange }
        return .red
    }

}
