import SwiftUI
import Combine
import FoundationModels
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// アプリが組み立てるプロンプト・定型文の集約。散らばり防止と保守性のため1か所にまとめる。
/// appSystem の KaTeX 記法は WebView の数式描画、ファイル記法は index.html の保存処理と
/// 対になっている「技術契約」なので、編集時は対応機能との整合に注意。
enum Prompts {
    /// 常に適用するアプリ固有のシステム指示（KaTeX 表示・ファイル記法）。
    static let appSystem = """
    数式は KaTeX で表示されます。次のお作法に従ってください。
    - ディスプレイ数式は $$ ... $$ で囲む
    - インライン数式は \\( ... \\) で囲む（$ ... $ は使わない）
    - 数式をコードブロック(```)で囲まない（そのまま文字列として表示されてしまう）

    ファイル・コード・データを作成・保存するよう求められたら、その内容は必ずコードフェンスで囲み、開始フェンスに「言語:ファイル名」を書くこと（例: ```python:main.py / ```csv:data.csv / ```json:config.json）。ファイル名は内容にふさわしい名前と拡張子にする。この「言語:ファイル名」表記は省略してはならない。
    """

    /// Web検索ツールを使うときの振る舞い指示。
    static let webSearch = "Web検索ツールを使用する場合、検索結果のテキストをそのまま出力しないでください。検索結果を参照して内容を理解し、自分の言葉で簡潔に回答してください。"

    /// Web検索ツール（function calling）の説明文。
    static let webSearchToolDescription = "SearXNGを使って最新のWeb情報を検索します。最新情報や時事問題について質問されたときに使用してください。"

    /// 呼び名が設定されているときに注入する、AI向けの呼びかけ指示。
    static func userName(_ name: String) -> String {
        """
        # ユーザーについて
        対話相手の名前は「\(name)」です。次の方針で接してください。
        - 会話の自然な区切りで名前を呼び、親しみのある対話にする
        - 敬称や呼び方（「さん」付け・呼び捨て・あだ名など）は固定せず、会話の雰囲気やこのあとの指示・ユーザーの希望に合わせて選ぶ
        """
    }

    /// セッション開始時の定型あいさつ。名前があれば呼びかける。
    static func greeting(_ name: String?) -> String {
        name.map { "\($0)さん、お手伝いしましょうか？" } ?? "お手伝いしましょうか？"
    }
}

actor SearchResultsCollector {
    var sources: [SearchSource] = []
    func append(_ source: SearchSource) { sources.append(source) }
    func reset() { sources = [] }
}

struct WebSearchTool: Tool {
    let collector: SearchResultsCollector
    let searxngURL: String
    let resultLimit: Int
    let name = "webSearch"
    let description = Prompts.webSearchToolDescription

    @Generable
    struct Arguments {
        @Guide(description: "検索するクエリ文字列")
        var query: String
    }

    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: Arguments) async throws -> String {
        let encoded = arguments.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(searxngURL)/search?q=\(encoded)&format=json") else {
            return "検索できませんでした"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return "検索結果を解析できませんでした"
            }
            var summaries: [String] = []
            for r in results.prefix(resultLimit) {
                guard let title = r["title"] as? String else { continue }
                let content = r["content"] as? String ?? ""
                let resultURL = r["url"] as? String ?? ""
                await collector.append(SearchSource(title: title, url: resultURL))
                summaries.append("\(title)\n\(content)\n\(resultURL)")
            }
            return summaries.isEmpty ? "検索結果が見つかりませんでした" : summaries.joined(separator: "\n\n---\n\n")
        } catch {
            return "SearXNGへの接続に失敗しました: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var selectedModel: String = "" { didSet { persist(selectedModel, "selectedModel") } }
    @Published var models: [String] = []
    @Published var isInSession = false
    @Published var isGenerating = false
    @Published var isAudioPlaying = false
    @Published var selectedSpeakerID: Int = 3 { didSet { persist(selectedSpeakerID, "selectedSpeakerID") } }
    @Published var displaySpeakers: [(id: Int, name: String)] = []
    @Published var speechSpeed: Double = 1.00 { didSet { persist(speechSpeed, "speechSpeed") } }
    @Published var voiceEnabled: Bool = true { didSet { persist(voiceEnabled, "voiceEnabled") } }
    @Published var isFetching = false
    @Published var aiProvider: AIProvider = .ollama { didSet { persist(aiProvider.rawValue, "aiProvider"); pendingAttachments.removeAll() } }
    @Published var appleIntelligenceError: String? = nil
    @Published var webSearchEnabled: Bool = false { didSet { persist(webSearchEnabled, "webSearchEnabled") } }
    @Published var thinkingEnabled: Bool = false { didSet { persist(thinkingEnabled, "thinkingEnabled") } }
    @Published var searxngURL: String = ChatViewModel.defaultSearxngURL { didSet { persist(searxngURL, "searxngURL") } }
    /// Web検索（SearXNG）でAIへ渡す結果の最大件数。
    @Published var webSearchResultCount: Int = 5 { didSet { persist(webSearchResultCount, "webSearchResultCount") } }
    @Published var voicevoxURL: String = ChatViewModel.defaultVoicevoxURL { didSet { persist(voicevoxURL, "voicevoxURL") } }
    @Published var llmServerURL: String = ChatViewModel.defaultLLMServerURL { didSet { persist(llmServerURL, "llmServerURL") } }
    @Published var customInstructions: String = "" { didSet { persist(customInstructions, "customInstructions") } }
    @Published var customInstructionsEnabled: Bool = true { didSet { persist(customInstructionsEnabled, "customInstructionsEnabled") } }
    /// ユーザーの呼び名。空のときは表示・指示ともに使わず既定（「あなた」）にフォールバックする。
    @Published var userName: String = "" { didSet { persist(userName, "userName") } }
    @Published var contextUsageRatio: Double = 0.0
    @Published var ollamaContextSize: Int = 4096 { didSet { persist(ollamaContextSize, "ollamaContextSize") } }
    /// Ollamaの生成パラメータ（temperature/seed等）。未指定の項目はリクエストに含めずOllama既定に任せる。
    @Published var ollamaOptions = OllamaOptions() {
        didSet {
            guard settingsLoaded else { return }
            if let data = try? JSONEncoder().encode(ollamaOptions) {
                UserDefaults.standard.set(data, forKey: "aetherium.ollamaOptions")
            }
        }
    }
    static let ollamaContextSizeOptions = [2048, 4096, 8192, 16384, 32768, 65536]
    // サーバー接続先のデフォルト値（いずれもIPv4ループバック直指定で統一）。
    static let defaultLLMServerURL = "http://127.0.0.1:11434/v1"
    static let defaultVoicevoxURL = "http://127.0.0.1:50021"
    static let defaultSearxngURL = "http://127.0.0.1:8080"
    @Published var ollamaToolsSupported: Bool = false
    @Published var ollamaThinkingSupported: Bool = false
    @Published var ollamaVisionSupported: Bool = false
    @Published var ollamaContextUsedTokens: Int = 0
    /// 次に送信するメッセージへ添付する画像/ファイル（送信時にクリア）。
    @Published var pendingAttachments: [Attachment] = []
    /// 添付の取り込み失敗を伝えるメッセージ（表示後にnilへ戻す）。
    @Published var attachmentError: String? = nil
    /// 現在のコンテキストにやり取りがあるか（Web検索トグルの切替可否に使用）。
    @Published var contextHasExchange: Bool = false
    // 末尾以外のメッセージ（過去の版切替など）を変更したとき、WebViewへ全再描画を促すためのトークン。
    @Published var chatRevision: Int = 0
    private let estimatedContextCharLimit = 8192  // ~4096 tokens * 2 chars/token
    private let searchResultsCollector = SearchResultsCollector()
    private var ollamaContextStartIndex: Int = 0
    private var generatingTask: Task<Void, Never>?
    private var speechQueue: [(text: String, sessionID: UUID)] = []
    private var speechQueueTask: Task<Void, Never>?
    private var currentAudioSessionID: UUID? = nil
    private var streamTask: URLSessionTask?
    private nonisolated(unsafe) var playbackStateObserver: NSObjectProtocol?
    private var foundationSession: LanguageModelSession?
    /// 設定の読み込みが終わるまで didSet での保存を抑止するフラグ。
    private var settingsLoaded = false

    var currentSpeakerName: String { displaySpeakers.first(where: { $0.id == selectedSpeakerID })?.name ?? "AI" }

    /// 設定された呼び名（前後空白を除去）。未設定なら nil。
    var trimmedUserName: String? {
        let t = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    /// 吹き出しラベル等の表示用呼び名。未設定なら「あなた」。
    var displayUserName: String { trimmedUserName ?? "あなた" }

    /// セッションを開始する。会話がまだ空なら、AIの定型あいさつを最初に表示する。
    func startSession() {
        // Apple Intelligence は最新のカスタム指示を焼き込むためセッションを作り直す
        // （開始前は会話ゼロなので作り直しても何も失わない）。
        if aiProvider == .appleIntelligence { setupFoundationSession() }
        if messages.isEmpty {
            let greeting = Prompts.greeting(trimmedUserName)
            messages.append(Message(role: "assistant", content: greeting))
        }
        isInSession = true
    }

    var activeModelLabel: String {
        aiProvider == .appleIntelligence ? "Apple Intelligence" : selectedModel
    }

    var canStartSession: Bool {
        // VOICEVOX は開始条件に含めない（未起動でも開始でき、音声は使うときだけ動く）。
        if aiProvider == .appleIntelligence {
            return appleIntelligenceError == nil
        } else {
            return !models.isEmpty
        }
    }

    /// Web検索トグルを切り替えられるか。コンテキストが空（開始前 or クリア直後）のときだけ可。
    /// Ollama はツール対応モデルのときのみ。
    var canToggleWebSearch: Bool {
        guard !contextHasExchange else { return false }
        return aiProvider == .appleIntelligence ? true : ollamaToolsSupported
    }

    init() {
        loadPersistedSettings()
        settingsLoaded = true
        playbackStateObserver = NotificationCenter.default.addObserver(
            forName: .playerManagerPlaybackStateChanged,
            object: PlayerManager.shared,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let playing = note.userInfo?["isPlaying"] as? Bool
            else { return }
            Task { @MainActor in
                self.isAudioPlaying = playing
            }
        }
    }

    deinit {
        if let observer = playbackStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 設定の永続化

    private func persist<T>(_ value: T, _ key: String) {
        guard settingsLoaded else { return }  // 読み込み中の didSet は無視
        UserDefaults.standard.set(value, forKey: "aetherium.\(key)")
    }

    private func loadPersistedSettings() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "aetherium.selectedModel") { selectedModel = v }
        if d.object(forKey: "aetherium.selectedSpeakerID") != nil { selectedSpeakerID = d.integer(forKey: "aetherium.selectedSpeakerID") }
        if d.object(forKey: "aetherium.speechSpeed") != nil { speechSpeed = d.double(forKey: "aetherium.speechSpeed") }
        if d.object(forKey: "aetherium.voiceEnabled") != nil { voiceEnabled = d.bool(forKey: "aetherium.voiceEnabled") }
        if let v = d.string(forKey: "aetherium.aiProvider"), let p = AIProvider(rawValue: v) { aiProvider = p }
        if d.object(forKey: "aetherium.webSearchEnabled") != nil { webSearchEnabled = d.bool(forKey: "aetherium.webSearchEnabled") }
        if d.object(forKey: "aetherium.thinkingEnabled") != nil { thinkingEnabled = d.bool(forKey: "aetherium.thinkingEnabled") }
        if let v = d.string(forKey: "aetherium.searxngURL"), !v.isEmpty { searxngURL = v }
        if d.object(forKey: "aetherium.webSearchResultCount") != nil { webSearchResultCount = d.integer(forKey: "aetherium.webSearchResultCount") }
        if let v = d.string(forKey: "aetherium.voicevoxURL"), !v.isEmpty { voicevoxURL = v }
        if let v = d.string(forKey: "aetherium.llmServerURL"), !v.isEmpty { llmServerURL = v }
        if let v = d.string(forKey: "aetherium.userName") { userName = v }
        if let v = d.string(forKey: "aetherium.customInstructions") { customInstructions = v }
        if d.object(forKey: "aetherium.customInstructionsEnabled") != nil { customInstructionsEnabled = d.bool(forKey: "aetherium.customInstructionsEnabled") }
        if d.object(forKey: "aetherium.ollamaContextSize") != nil { ollamaContextSize = d.integer(forKey: "aetherium.ollamaContextSize") }
        if let data = d.data(forKey: "aetherium.ollamaOptions"),
           let opts = try? JSONDecoder().decode(OllamaOptions.self, from: data) { ollamaOptions = opts }
    }

    // MARK: - Context usage tracking

    private func segmentCharCount(_ segments: [Transcript.Segment]) -> Int {
        segments.reduce(0) { count, seg in
            if case .text(let ts) = seg { return count + ts.content.count }
            return count
        }
    }

    func updateContextUsage() {
        if aiProvider == .appleIntelligence {
            guard let session = foundationSession else { contextUsageRatio = 0.0; return }
            let totalChars: Int = session.transcript.reduce(0) { total, entry in
                switch entry {
                case .prompt(let p):       return total + segmentCharCount(p.segments)
                case .response(let r):     return total + segmentCharCount(r.segments)
                case .instructions(let i): return total + segmentCharCount(i.segments)
                case .toolOutput(let to):  return total + segmentCharCount(to.segments)
                case .toolCalls: return total
                @unknown default:          return total
                }
            }
            contextUsageRatio = min(1.0, Double(totalChars) / Double(estimatedContextCharLimit))
        } else {
            guard ollamaContextSize > 0 else { contextUsageRatio = 0.0; return }
            contextUsageRatio = min(1.0, Double(ollamaContextUsedTokens) / Double(ollamaContextSize))
        }
    }

    // MARK: - Session management

    /// 呼び名が設定されているときに注入する、AI向けの呼びかけ指示（未設定ならnil）。
    private var userNameInstruction: String? {
        trimmedUserName.map { Prompts.userName($0) }
    }

    /// 有効かつ空でないカスタム指示（無効・空ならnil）。注入・トークン見積もりの共通判定に使う。
    private var activeCustomInstruction: String? {
        guard customInstructionsEnabled else { return nil }
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// アプリのシステム指示・ユーザーのカスタム指示・Web検索用指示を結合した、セッションに渡す最終instructions。
    /// アプリのシステム指示が常に含まれるため必ず非nil。
    private var effectiveInstructions: String? {
        var parts: [String] = [Prompts.appSystem]
        if let nameInstr = userNameInstruction { parts.append(nameInstr) }
        if let instr = activeCustomInstruction { parts.append(instr) }
        if webSearchEnabled { parts.append(Prompts.webSearch) }
        return parts.joined(separator: "\n\n")
    }

    private func makeSession() -> LanguageModelSession {
        let tools = webSearchEnabled
            ? [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL, resultLimit: webSearchResultCount)]
            : []
        switch (tools.isEmpty, effectiveInstructions) {
        case (false, let instr?): return LanguageModelSession(tools: tools, instructions: instr)
        case (false, nil):        return LanguageModelSession(tools: tools)
        case (true, let instr?):  return LanguageModelSession(instructions: instr)
        case (true, nil):         return LanguageModelSession()
        }
    }

    private func makeTrimmedSession() -> LanguageModelSession {
        guard let current = foundationSession else { return makeSession() }
        let all = Array(current.transcript)
        let instructions = all.filter { if case .instructions = $0 { return true }; return false }
        var exchanges = all.filter { if case .instructions = $0 { return false }; return true }
        // 文脈超過で失敗した末尾のプロンプトを除外（リトライ時に同じ text が再投入されるため重複防止）
        if let last = exchanges.last, case .prompt = last {
            exchanges.removeLast()
        }
        let trimmed = Transcript(entries: instructions + exchanges.suffix(4))
        return webSearchEnabled
            ? LanguageModelSession(tools: [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL, resultLimit: webSearchResultCount)], transcript: trimmed)
            : LanguageModelSession(transcript: trimmed)
    }

    func clearContext() {
        stopGeneration()
        contextHasExchange = false  // クリア直後はWeb検索トグルを再び切替可能にする
        if aiProvider == .appleIntelligence {
            foundationSession = makeSession()
        } else {
            ollamaContextStartIndex = messages.count
            ollamaContextUsedTokens = 0
        }
        messages.append(Message(role: "system", content: "コンテキストをリセットしました"))
        updateContextUsage()
    }

    private func trimHistoryToFit() {
        // トリガー: 前ターンのAPI報告トークン数が80%を超えた場合のみ実行
        // （文字数推定ではなく実際のトークン数を使うことでバー表示と一致させる）
        guard ollamaContextUsedTokens >= ollamaContextSize * 4 / 5 else { return }

        let newUserIdx = messages.count - 2  // 末尾はplaceholder、その手前が今回のユーザーメッセージ
        let trimmable = messages.indices.filter {
            $0 >= ollamaContextStartIndex && $0 < newUserIdx && messages[$0].role != "system"
        }
        guard !trimmable.isEmpty else { return }

        // 削る量: コンテキスト使用率が約35%になるまで古い順に削る
        // 50%だとトリム直後の再評価＋応答で100%を超えうるため、余裕を持って削る
        // 文字数 ≈ トークン数 × 2 と仮定 → 目標文字数 = ollamaContextSize × 0.35 × 2 = × 0.7
        let targetChars = ollamaContextSize * 7 / 10
        var totalChars = trimmable.reduce(messages[newUserIdx].content.count) {
            $0 + messages[$1].content.count
        }
        // システム指示・カスタム指示は毎回先頭に注入されトリム対象外なので、固定オーバーヘッドとして見積もりに加算する
        totalChars += Prompts.appSystem.count
        if let instr = activeCustomInstruction { totalChars += instr.count }
        var newStart = ollamaContextStartIndex
        for idx in trimmable {
            guard totalChars > targetChars else { break }
            totalChars -= messages[idx].content.count
            newStart = idx + 1
        }
        // 文字数推定で削り切れなくても最低1件は削る
        if newStart == ollamaContextStartIndex {
            newStart = trimmable[0] + 1
        }

        ollamaContextStartIndex = newStart
        ollamaContextUsedTokens = 0
        messages.insert(Message(role: "system", content: "コンテキストが上限に達したため古い会話を整理しました"), at: newUserIdx)
        updateContextUsage()
    }

    func setupFoundationSession() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            foundationSession = makeSession()
            appleIntelligenceError = nil
        case .unavailable(let reason):
            foundationSession = nil
            switch reason {
            case .deviceNotEligible:
                appleIntelligenceError = "このデバイスは Apple Intelligence に対応していません（Apple Silicon が必要です）"
            case .appleIntelligenceNotEnabled:
                appleIntelligenceError = "Apple Intelligence が有効になっていません。\nシステム設定 → Apple Intelligence & Siri から有効にしてください。"
            case .modelNotReady:
                appleIntelligenceError = "モデルの準備中です。しばらく待ってから再起動してください。"
            @unknown default:
                appleIntelligenceError = "Apple Intelligence を利用できません。"
            }
        }
    }

    // MARK: - Ollama model info

    func fetchModelInfo(for model: String) async {
        ollamaToolsSupported = false
        ollamaThinkingSupported = false
        ollamaVisionSupported = false
        guard let url = URL(string: "http://127.0.0.1:11434/api/show") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let caps = json["capabilities"] as? [String] {
                ollamaToolsSupported = caps.contains("tools")
                ollamaThinkingSupported = caps.contains("thinking")
                ollamaVisionSupported = caps.contains("vision")
            }
            // num_ctx の自動取得は行わない：ユーザーがスライダーで選んだ値を尊重する
        } catch { }
    }

    // MARK: - Attachments

    /// 画像を取り込む（1枚のみ・既存画像は置き換え）。長辺がしきい値を超える場合だけ縮小する。
    func addImageAttachment(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let (base64, mime) = Self.encodeImage(data: data, source: src) else {
            attachmentError = "画像を読み込めませんでした: \(url.lastPathComponent)"
            return
        }
        setImageAttachment(base64: base64, mime: mime, filename: url.lastPathComponent)
    }

    /// クリップボードから貼り付けた画像（PNG Data）を添付する。
    /// Vision対応なら取り込んで true、非対応・失敗なら通知して false（呼び出し側はテキスト貼付へフォールバック）。
    func pasteImage(_ data: Data) -> Bool {
        guard aiProvider == .ollama, ollamaVisionSupported else {
            attachmentError = "このモデルは画像を扱えません（Vision非対応のモデルです）"
            return false
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let (base64, mime) = Self.encodeImage(data: data, source: src) else {
            attachmentError = "貼り付けた画像を読み込めませんでした"
            return false
        }
        setImageAttachment(base64: base64, mime: mime, filename: "貼り付け画像.png")
        return true
    }

    /// 画像添付を1枚に保つ（既存画像を置き換える）共通処理。
    private func setImageAttachment(base64: String, mime: String, filename: String) {
        pendingAttachments.removeAll { $0.kind == .image }
        pendingAttachments.append(Attachment(kind: .image, filename: filename, payload: base64, mime: mime))
    }

    /// ファイルを取り込む（複数可・同名は重複スルー）。テキストとして読めないもの・大きすぎるものは弾く。
    func addFileAttachments(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            if pendingAttachments.contains(where: { $0.kind == .file && $0.filename == name }) { continue }
            switch Self.extractText(from: url) {
            case .text(let t):
                pendingAttachments.append(Attachment(kind: .file, filename: name, payload: t))
            case .tooLarge:
                attachmentError = "ファイルが大きすぎます（約1MBまで）: \(name)"
            case .unreadable:
                attachmentError = "テキストとして読み込めないファイルです: \(name)"
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// 画像を base64 と MIME に変換する。長辺がしきい値以下なら原寸のまま（無劣化）、超える場合のみ長辺を縮小して JPEG 化する。
    private static let imageMaxSide = 1568
    private static func encodeImage(data: Data, source src: CGImageSource) -> (String, String)? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // しきい値以下は原寸そのまま（無駄な再エンコードで劣化させない）
        if w > 0, h > 0, max(w, h) <= imageMaxSide {
            let mime = (CGImageSourceGetType(src) as String?).flatMap { UTType($0)?.preferredMIMEType } ?? "image/jpeg"
            return (data.base64EncodedString(), mime)
        }
        // 大きい画像は長辺を縮小して JPEG 化
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return (data.base64EncodedString(), "image/jpeg")
        }
        let rep = NSBitmapImageRep(cgImage: thumb)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return (data.base64EncodedString(), "image/jpeg")
        }
        return (jpeg.base64EncodedString(), "image/jpeg")
    }

    /// ファイル取り込みの判定結果。
    private enum ExtractResult {
        case text(String)
        case tooLarge
        case unreadable
    }

    /// 1ファイルあたりの上限（コンテキスト暴走の安全弁）。
    private static let maxFileBytes = 1_000_000

    /// pdfはPDFKitで抽出、それ以外は拡張子を問わず「テキストとして読めるか」で判定する。
    /// エンコーディングは自動判定（BOM等でUTF-16等も）→UTF-8の順。読めなければバイナリ扱いで弾く。
    private static func extractText(from url: URL) -> ExtractResult {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let s = doc.string, !s.isEmpty else { return .unreadable }
            return s.utf8.count > maxFileBytes ? .tooLarge : .text(s)
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if data.count > maxFileBytes { return .tooLarge }
        if data.isEmpty { return .unreadable }
        // エンコーディング自動判定（BOM等でUTF-16なども推定）。
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc), !s.isEmpty {
            return .text(s)
        }
        // フォールバック：UTF-8として読めるか。
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return .text(s)
        }
        return .unreadable  // どのエンコーディングでも読めない＝バイナリ
    }

    // MARK: - Fetch

    func fetchAll() async {
        isFetching = true
        await fetchModels()
        await fetchVVSpeakers()
        isFetching = false
    }

    /// サーバー接続先URLをすべてデフォルトに戻して再取得する。
    func resetServerURLsToDefaults() {
        llmServerURL = Self.defaultLLMServerURL
        voicevoxURL = Self.defaultVoicevoxURL
        searxngURL = Self.defaultSearxngURL
        Task { await fetchAll() }
    }

    func fetchModels() async {
        guard let url = URL(string: "\(llmServerURL)/models") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                let fetchedModels = dataArray.compactMap { $0["id"] as? String }
                self.models = fetchedModels
                // 記憶したモデルが現在の一覧に無ければ先頭にフォールバック（設定変更でモデルが消えた場合の対策）。
                if !fetchedModels.contains(self.selectedModel) {
                    self.selectedModel = fetchedModels.first ?? ""
                }
            }
        } catch {
            print("LLM Server not found")
            self.models = []
        }
        if !selectedModel.isEmpty {
            await fetchModelInfo(for: selectedModel)
        }
    }

    func fetchVVSpeakers() async {
        guard let url = URL(string: "\(voicevoxURL)/speakers") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([VVSpeaker].self, from: data)
            self.displaySpeakers = decoded.flatMap { speaker in
                speaker.styles.map { style in
                    (id: style.id, name: "\(speaker.name) (\(style.name))")
                }
            }.sorted { $0.name < $1.name }
            if let first = self.displaySpeakers.first,
               !self.displaySpeakers.contains(where: { $0.id == self.selectedSpeakerID }) {
                self.selectedSpeakerID = first.id
            }
        } catch {
            print("VOICEVOX not found")
            self.displaySpeakers = []
        }
    }

    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        generatingTask?.cancel()
        speechQueueTask?.cancel()
        speechQueueTask = nil
        speechQueue.removeAll()
        PlayerManager.shared.stopAll()
        currentAudioSessionID = nil
        generatingTask = nil
        isGenerating = false
    }

    func sendMessage(_ text: String) {
        contextHasExchange = true  // 会話が始まったらWeb検索トグルを固定する
        if aiProvider == .appleIntelligence {
            sendMessageApple(text)
        } else {
            sendMessageOllama(text)
        }
    }

    // MARK: - Regenerate / Variants

    private func variantSnapshot(_ m: Message) -> MessageVariant {
        MessageVariant(content: m.content, thinking: m.thinking, stats: m.stats, searchSources: m.searchSources)
    }

    /// 生成完了時に、現在の表示中フィールドをアクティブな版へ確定保存する（版nav有り時のみ）。
    private func finalizeVariant(assistantID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == assistantID }),
              messages[i].variants != nil,
              let a = messages[i].activeVariant else { return }
        messages[i].variants![a] = variantSnapshot(messages[i])
    }

    /// 最後のAI回答を再思考する。古い回答は版として保持し、新しい版を生成・表示する。
    func regenerate(messageID: UUID) {
        guard !isGenerating else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == "assistant", idx > 0 else { return }
        stopGeneration()

        // 初回再思考時は現在の回答を版0として退避。以降は現在の表示版を上書き保存する。
        if messages[idx].variants == nil {
            messages[idx].variants = [variantSnapshot(messages[idx])]
            messages[idx].activeVariant = 0
        } else if let a = messages[idx].activeVariant {
            messages[idx].variants![a] = variantSnapshot(messages[idx])
        }
        // 新しい空の版を追加してアクティブにし、表示フィールドをクリア（生成で埋める）。
        messages[idx].variants!.append(MessageVariant(content: "", thinking: nil, stats: nil, searchSources: nil))
        messages[idx].activeVariant = messages[idx].variants!.count - 1
        messages[idx].content = ""
        messages[idx].thinking = nil
        messages[idx].stats = nil
        messages[idx].searchSources = nil

        if aiProvider == .appleIntelligence {
            guard foundationSession != nil else { return }
            let userText = messages[idx - 1].content
            // Apple のセッションは内部に履歴を保持するため、末尾の応答を外したセッションへ作り直して再プロンプトする。
            let session = makeRegenSession()
            foundationSession = session
            runAppleGeneration(text: userText, assistantID: messageID, session: session, retryAfterTrim: true)
        } else {
            // Ollama は毎回 messages から履歴を再構築するため、空にした placeholder で再実行するだけでよい。
            runOllamaGeneration(assistantID: messageID)
        }
    }

    /// 版を切り替える（dir: -1=前 / +1=次）。表示中フィールドを該当版へ差し替える。
    func selectVariant(messageID: UUID, dir: Int) {
        guard !isGenerating else { return }
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              let variants = messages[i].variants, variants.count > 1 else { return }
        let cur = messages[i].activeVariant ?? (variants.count - 1)
        let next = max(0, min(variants.count - 1, cur + dir))
        guard next != cur else { return }
        // 離脱前に現在の表示内容を現版へ保存（途中キャンセル分などの取りこぼし防止）。
        messages[i].variants![cur] = variantSnapshot(messages[i])
        let v = messages[i].variants![next]
        messages[i].activeVariant = next
        messages[i].content = v.content
        messages[i].thinking = v.thinking
        messages[i].stats = v.stats
        messages[i].searchSources = v.searchSources
        // 末尾以外の版切替は末尾シグネチャが変わらず再描画されないため、全再描画を促す。
        if i != messages.count - 1 { chatRevision += 1 }
    }

    /// 末尾の応答（と直前のプロンプト）をトランスクリプトから外したセッションを作る（Apple用・再思考のため）。
    private func makeRegenSession() -> LanguageModelSession {
        guard let current = foundationSession else { return makeSession() }
        var entries = Array(current.transcript)
        if let last = entries.last, case .response = last { entries.removeLast() }
        if let last = entries.last, case .prompt = last { entries.removeLast() }
        let trimmed = Transcript(entries: entries)
        return webSearchEnabled
            ? LanguageModelSession(tools: [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL, resultLimit: webSearchResultCount)], transcript: trimmed)
            : LanguageModelSession(transcript: trimmed)
    }

    // MARK: - Apple Intelligence

    private func sendMessageApple(_ text: String, retryAfterTrim: Bool = false) {
        guard let session = foundationSession else { return }
        stopGeneration()
        let assistantID = UUID()
        if !retryAfterTrim { messages.append(Message(role: "user", content: text)) }
        messages.append(Message(id: assistantID, role: "assistant", content: ""))
        runAppleGeneration(text: text, assistantID: assistantID, session: session, retryAfterTrim: retryAfterTrim)
    }

    private func runAppleGeneration(text: String, assistantID: UUID, session: LanguageModelSession, retryAfterTrim: Bool) {
        isGenerating = true
        let audioSessionID = UUID()
        currentAudioSessionID = audioSessionID

        generatingTask = Task {
            await searchResultsCollector.reset()
            var shouldRetryText: String? = nil
            var previousContent = ""
            var localSpeechBuffer = ""
            let requestStartTime = Date()
            var firstTokenTime: Date? = nil
            let indexForAssistant: @MainActor () -> Int? = {
                self.messages.firstIndex(where: { $0.id == assistantID })
            }

            do {
                let stream = session.streamResponse(to: text)
                for try await partial in stream {
                    if Task.isCancelled { break }
                    let fullContent = partial.content
                    let delta = String(fullContent.dropFirst(previousContent.count))
                    if firstTokenTime == nil && !delta.isEmpty { firstTokenTime = Date() }
                    previousContent = fullContent

                    await MainActor.run {
                        if let i = indexForAssistant() {
                            self.messages[i].content = fullContent
                        }
                    }

                    localSpeechBuffer += delta
                    if delta.contains(where: { "。！？\n".contains($0) }) {
                        let sentence = localSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !sentence.isEmpty && !Task.isCancelled {
                            await MainActor.run { self.enqueueSpeech(sentence, sessionID: audioSessionID) }
                        }
                        localSpeechBuffer = ""
                    }
                }
                if !Task.isCancelled && !localSpeechBuffer.isEmpty {
                    await MainActor.run { self.enqueueSpeech(localSpeechBuffer, sessionID: audioSessionID) }
                }
                // 文字数ベースの近似stats（FoundationModelsはトークン数非公開）
                if !Task.isCancelled {
                    let charCount = previousContent.count
                    let genDuration = Date().timeIntervalSince(firstTokenTime ?? requestStartTime)
                    let ttft = firstTokenTime?.timeIntervalSince(requestStartTime)
                    await MainActor.run {
                        if let i = indexForAssistant() {
                            self.messages[i].stats = UsageStats(
                                promptTokens: text.count,
                                completionTokens: charCount,
                                totalTokens: text.count + charCount,
                                tokensPerSecond: Double(charCount) / max(genDuration, 0.001),
                                ttft: ttft
                            )
                        }
                    }
                }
                if !Task.isCancelled {
                    let sources = await searchResultsCollector.sources
                    if !sources.isEmpty {
                        await MainActor.run {
                            if let i = indexForAssistant() {
                                self.messages[i].searchSources = sources
                            }
                        }
                    }
                }
            } catch {
                let nsErr = error as NSError
                guard nsErr.code != NSURLErrorCancelled && !Task.isCancelled else { return }
                var detail: String? = nil
                if let genErr = error as? LanguageModelSession.GenerationError {
                    switch genErr {
                    case .exceededContextWindowSize where !retryAfterTrim:
                        let trimmedSess = self.makeTrimmedSession()
                        await MainActor.run {
                            if let i = indexForAssistant() { self.messages.remove(at: i) }
                            self.messages.append(Message(role: "system", content: "コンテキストが上限に達したため古い会話を整理して再試行します"))
                            self.foundationSession = trimmedSess
                        }
                        shouldRetryText = text
                    case .guardrailViolation:          detail = "コンテンツポリシー違反 (guardrailViolation)"
                    case .exceededContextWindowSize:   detail = "コンテキスト上限超過（整理後も超過）"
                    case .assetsUnavailable:           detail = "モデルアセット未準備 (assetsUnavailable)"
                    case .decodingFailure:             detail = "デコード失敗 (decodingFailure)"
                    case .rateLimited:                 detail = "レートリミット (rateLimited)"
                    case .concurrentRequests:          detail = "同時リクエスト超過 (concurrentRequests)"
                    case .unsupportedGuide:            detail = "未対応ガイド (unsupportedGuide)"
                    case .unsupportedLanguageOrLocale: detail = "未対応言語 (unsupportedLanguageOrLocale)"
                    case .refusal:                     detail = "応答拒否 (refusal)"
                    @unknown default:                  detail = "不明なエラー (code: \(nsErr.code))"
                    }
                } else if let toolErr = error as? LanguageModelSession.ToolCallError {
                    detail = "ツール呼び出しエラー: \(toolErr.underlyingError.localizedDescription)"
                } else {
                    detail = "code: \(nsErr.code) — \(error.localizedDescription)"
                }
                if let d = detail {
                    print("[Apple Intelligence Error] \(d)")
                    await MainActor.run {
                        if let i = indexForAssistant() {
                            self.messages[i].content = "⚠️ エラー: \(d)"
                        }
                    }
                }
            }

            await MainActor.run {
                self.finalizeVariant(assistantID: assistantID)
                self.isGenerating = false
                self.generatingTask = nil
                self.updateContextUsage()
            }
            if let retryText = shouldRetryText {
                await MainActor.run { self.sendMessageApple(retryText, retryAfterTrim: true) }
            }
        }
    }

    // MARK: - Ollama

    /// llmServerURL（OpenAI互換: .../v1）から末尾の /v1 を外したネイティブAPIのベースURL。
    /// 思考モード(think)はネイティブ /api/chat でしか動かないため、こちらを使う。
    private var ollamaNativeBaseURL: String {
        var s = llmServerURL
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var ollamaWebSearchToolSpec: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "webSearch",
                "description": Prompts.webSearchToolDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "検索するクエリ文字列"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    private func executeWebSearch(query: String) async -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(searxngURL)/search?q=\(encoded)&format=json") else {
            return "検索できませんでした"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return "検索結果を解析できませんでした"
            }
            var summaries: [String] = []
            for r in results.prefix(self.webSearchResultCount) {
                guard let title = r["title"] as? String else { continue }
                let content = r["content"] as? String ?? ""
                let resultURL = r["url"] as? String ?? ""
                await searchResultsCollector.append(SearchSource(title: title, url: resultURL))
                summaries.append("\(title)\n\(content)\n\(resultURL)")
            }
            return summaries.isEmpty ? "検索結果が見つかりませんでした" : summaries.joined(separator: "\n\n---\n\n")
        } catch {
            return "SearXNGへの接続に失敗しました: \(error.localizedDescription)"
        }
    }

    private func sendMessageOllama(_ text: String) {
        stopGeneration()
        let assistantID = UUID()
        let atts = pendingAttachments
        pendingAttachments = []
        messages.append(Message(role: "user", content: text, attachments: atts.isEmpty ? nil : atts))
        messages.append(Message(id: assistantID, role: "assistant", content: ""))
        runOllamaGeneration(assistantID: assistantID)
    }

    private func runOllamaGeneration(assistantID: UUID) {
        isGenerating = true
        let audioSessionID = UUID()
        currentAudioSessionID = audioSessionID

        generatingTask = Task {
            await searchResultsCollector.reset()
            var localSpeechBuffer = ""
            let requestStartTime = Date()
            var firstTokenTime: Date?

            let indexForAssistant: @MainActor () -> Int? = {
                self.messages.firstIndex(where: { $0.id == assistantID })
            }

            // リクエスト前にトークン推定でトリム（Ollamaへ送る前に収める）
            trimHistoryToFit()

            // Build history from context window, excluding visual system messages
            let historyMessages = Array(self.messages[self.ollamaContextStartIndex...])
                .dropLast()  // exclude empty assistant placeholder
                .filter { $0.role != "system" }
            let lastHistoryIdx = historyMessages.count - 1
            var history: [[String: Any]] = historyMessages.enumerated().map { (i, m) -> [String: Any] in
                var content = m.content
                // 添付ファイルの抽出テキストは content の先頭へ合成する（テキストは軽いので全ターン残す）。
                let fileTexts = (m.attachments ?? []).filter { $0.kind == .file }
                    .map { "[添付ファイル: \($0.filename)]\n\($0.payload)" }
                if !fileTexts.isEmpty {
                    content = fileTexts.joined(separator: "\n\n") + "\n\n" + content
                }
                var dict: [String: Any] = ["role": m.role, "content": content]
                // 画像は重いので最新ターン（＝今回のユーザー入力）のみ images で送る。
                if i == lastHistoryIdx {
                    let images = (m.attachments ?? []).filter { $0.kind == .image }.map { $0.payload }
                    if !images.isEmpty { dict["images"] = images }
                }
                return dict
            }

            // アプリのシステム指示（常に）＋ユーザーのカスタム指示 を1つのsystemにまとめて履歴の先頭へ差し込む
            // （画面表示用のお知らせsystemメッセージとは別管理）
            var systemParts = [Prompts.appSystem]
            if let nameInstr = self.userNameInstruction { systemParts.append(nameInstr) }
            if let instr = self.activeCustomInstruction { systemParts.append(instr) }
            history.insert(["role": "system", "content": systemParts.joined(separator: "\n\n")], at: 0)

            let useTools = self.webSearchEnabled && self.ollamaToolsSupported
            var toolRoundCount = 0
            // KVキャッシュヒット時: prompt_tokens = 新規評価分のみ（小さい） → 累積で補う
            // トリム直後:          prompt_tokens = 履歴全体の再評価（大きい・正確） → 実測値で上書き
            // max(累積+completion, prompt+completion) で両方を正しく処理する
            var roundTotalTokens: Int = 0      // prompt + completion の合計（全ラウンド分）
            var roundCompletionTokens: Int = 0 // completion のみ（全ラウンド分）

            mainLoop: repeat {
                // ラウンド毎の計測（tokensPerSecond をそのラウンドの実速度で出すため）
                let roundStartTime = Date()
                var roundFirstTokenTime: Date? = nil
                // 指定された生成パラメータだけを options に載せる（未指定はOllama既定に任せる）。
                var options: [String: Any] = ["num_ctx": self.ollamaContextSize]
                let o = self.ollamaOptions
                if let v = o.temperature { options["temperature"] = v }
                if let v = o.seed { options["seed"] = v }
                if let v = o.topP { options["top_p"] = v }
                if let v = o.topK { options["top_k"] = v }
                if let v = o.repeatPenalty { options["repeat_penalty"] = v }
                if let v = o.minP { options["min_p"] = v }
                if let v = o.numPredict { options["num_predict"] = v }
                if let v = o.stop, !v.isEmpty { options["stop"] = [v] }  // Ollamaのstopは配列で受ける
                if let v = o.numGpu { options["num_gpu"] = v }
                if let v = o.numThread { options["num_thread"] = v }
                if let v = o.numBatch { options["num_batch"] = v }
                var requestBody: [String: Any] = [
                    "model": self.selectedModel,
                    "messages": history,
                    "stream": true,
                    "options": options
                ]
                if useTools {
                    requestBody["tools"] = [self.ollamaWebSearchToolSpec]
                }
                // 思考モード: 対応モデルのときのみ think を明示送信（未指定だと既定で有効化されるため、OFFも明示する）
                if self.ollamaThinkingSupported {
                    requestBody["think"] = self.thinkingEnabled
                }

                guard let url = URL(string: "\(self.ollamaNativeBaseURL)/api/chat") else { break }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

                // ネイティブ /api/chat のツール呼び出しは id/index 無し・引数はオブジェクトで丸ごと届く
                var accumulatedToolCalls: [(name: String, arguments: [String: Any])] = []

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    // Check HTTP status before streaming
                    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let errorMsg: String
                        if let json = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
                           let err = json["error"] as? String {
                            errorMsg = err
                        } else {
                            errorMsg = "HTTP \(httpResp.statusCode)"
                        }
                        print("[Ollama Error] \(errorMsg)")
                        await MainActor.run {
                            if let i = indexForAssistant() {
                                self.messages[i].content = "⚠️ エラー: \(errorMsg)"
                            }
                        }
                        break mainLoop
                    }

                    await MainActor.run { self.streamTask = bytes.task }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        // ネイティブ /api/chat は行区切りJSON（1行=1オブジェクト）。SSEの "data: " 接頭辞は無い。
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let message = json["message"] as? [String: Any] {
                            // 思考デルタ（content とは別フィールドに溜める。音声読み上げ対象にはしない）
                            if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                                await MainActor.run {
                                    if let i = indexForAssistant() {
                                        self.messages[i].thinking = (self.messages[i].thinking ?? "") + thinking
                                    }
                                }
                            }
                            // 本文デルタ
                            if let content = message["content"] as? String, !content.isEmpty {
                                if firstTokenTime == nil { firstTokenTime = Date() }
                                if roundFirstTokenTime == nil { roundFirstTokenTime = Date() }
                                await MainActor.run {
                                    if let i = indexForAssistant() { self.messages[i].content += content }
                                }
                                localSpeechBuffer += content
                                if content.contains(where: { "。！？\n".contains($0) }) {
                                    let sentence = localSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !sentence.isEmpty && !Task.isCancelled {
                                        await MainActor.run { self.enqueueSpeech(sentence, sessionID: audioSessionID) }
                                    }
                                    localSpeechBuffer = ""
                                }
                            }
                            // ツール呼び出し（丸ごと届く・断片化しない）
                            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                                for tc in toolCalls {
                                    if let fn = tc["function"] as? [String: Any],
                                       let name = fn["name"] as? String {
                                        let args = fn["arguments"] as? [String: Any] ?? [:]
                                        accumulatedToolCalls.append((name: name, arguments: args))
                                    }
                                }
                            }
                        }

                        // 最終チャンク（done:true）にトークン数が入る
                        if (json["done"] as? Bool) == true {
                            let promptTokens = json["prompt_eval_count"] as? Int ?? 0
                            let completionTokens = json["eval_count"] as? Int ?? 0
                            let totalTokens = promptTokens + completionTokens
                            // tokensPerSecond は当該ラウンド内の生成時間で算出（ツールラウンドを跨ぐと不正確になるため）
                            let roundDuration = Date().timeIntervalSince(roundFirstTokenTime ?? roundStartTime)
                            // TTFT はユーザーが押してから最初の可視トークンまで（全ラウンド通算）
                            let ttft = firstTokenTime?.timeIntervalSince(requestStartTime)
                            roundTotalTokens += totalTokens
                            roundCompletionTokens += completionTokens
                            await MainActor.run {
                                if let i = indexForAssistant() {
                                    self.messages[i].stats = UsageStats(
                                        promptTokens: promptTokens,
                                        completionTokens: completionTokens,
                                        totalTokens: totalTokens,
                                        tokensPerSecond: Double(completionTokens) / max(roundDuration, 0.001),
                                        ttft: ttft
                                    )
                                }
                            }
                        }
                    }

                    // Flush any remaining buffered speech for this round
                    if !Task.isCancelled && !localSpeechBuffer.isEmpty {
                        await MainActor.run { self.enqueueSpeech(localSpeechBuffer, sessionID: audioSessionID) }
                        localSpeechBuffer = ""
                    }

                } catch {
                    let nsErr = error as NSError
                    guard nsErr.code != NSURLErrorCancelled && !Task.isCancelled else { break mainLoop }
                    let detail = "code: \(nsErr.code) — \(error.localizedDescription)"
                    print("[Ollama Error] \(detail)")
                    await MainActor.run {
                        if let i = indexForAssistant(), self.messages[i].content.isEmpty {
                            self.messages[i].content = "⚠️ エラー: \(detail)"
                        }
                    }
                    break mainLoop
                }

                // If model requested tool calls, execute them and loop
                if !accumulatedToolCalls.isEmpty && toolRoundCount < 3 {
                    let currentContent = await MainActor.run {
                        indexForAssistant().map { self.messages[$0].content } ?? ""
                    }
                    var assistantHistoryMsg: [String: Any] = ["role": "assistant", "content": currentContent]
                    assistantHistoryMsg["tool_calls"] = accumulatedToolCalls.map { tc -> [String: Any] in
                        ["function": ["name": tc.name, "arguments": tc.arguments] as [String: Any]]
                    }
                    history.append(assistantHistoryMsg)

                    // content は途中の中途半端な本文を消して最終回答に差し替えるためクリアする。
                    // thinking はクリアしない（検索を決めた理由＋検索後の思考をラウンドまたぎで残す）。
                    await MainActor.run {
                        if let i = indexForAssistant() { self.messages[i].content = "" }
                    }

                    for tc in accumulatedToolCalls {
                        guard tc.name == "webSearch", let query = tc.arguments["query"] as? String else {
                            history.append(["role": "tool", "content": "ツール不明", "tool_name": tc.name])
                            continue
                        }
                        let result = await self.executeWebSearch(query: query)
                        history.append(["role": "tool", "content": result, "tool_name": tc.name])
                    }

                    toolRoundCount += 1
                } else {
                    break mainLoop
                }
            } while true

            // Attach search sources to assistant message
            let sources = await searchResultsCollector.sources
            await MainActor.run {
                if !sources.isEmpty, let i = indexForAssistant() {
                    self.messages[i].searchSources = sources
                }
                self.finalizeVariant(assistantID: assistantID)
                // KVキャッシュヒット時は累積+completion、再評価時は実測値(roundTotalTokens)、どちらか大きい方
                self.ollamaContextUsedTokens = max(
                    self.ollamaContextUsedTokens + roundCompletionTokens,
                    roundTotalTokens
                )
                self.updateContextUsage()
                self.isGenerating = false
                self.generatingTask = nil
                self.streamTask = nil
            }
        }
    }

    // MARK: - Speech

    private func enqueueSpeech(_ text: String, sessionID: UUID) {
        guard voiceEnabled else { return }
        speechQueue.append((text: text, sessionID: sessionID))
        if speechQueueTask == nil {
            speechQueueTask = Task { await processSpeechQueue() }
        }
    }

    private func processSpeechQueue() async {
        while !Task.isCancelled {
            if speechQueue.isEmpty {
                speechQueueTask = nil
                return
            }
            let item = speechQueue.removeFirst()
            if currentAudioSessionID == item.sessionID {
                await synthesizeSpeech(text: item.text, sessionID: item.sessionID)
            }
        }
    }

    private func synthesizeSpeech(text: String, sessionID: UUID) async {
        guard !Task.isCancelled else { return }
        let cleanText = text.replacingOccurrences(of: "[^\\p{L}\\p{N}。！？、]", with: "", options: .regularExpression)
        guard !cleanText.isEmpty else { return }
        let encoded = cleanText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let speaker = self.selectedSpeakerID
        let speed = self.speechSpeed
        guard let qUrl = URL(string: "\(self.voicevoxURL)/audio_query?text=\(encoded)&speaker=\(speaker)") else { return }
        do {
            try Task.checkCancellation()
            var qReq = URLRequest(url: qUrl); qReq.httpMethod = "POST"
            let (qData, _) = try await URLSession.shared.data(for: qReq)
            try Task.checkCancellation()
            var queryJson = try JSONSerialization.jsonObject(with: qData) as? [String: Any]
            queryJson?["speedScale"] = speed
            let modifiedQData = try JSONSerialization.data(withJSONObject: queryJson as Any)
            try Task.checkCancellation()
            guard let sURL = URL(string: "\(self.voicevoxURL)/synthesis?speaker=\(speaker)") else { return }
            var sReq = URLRequest(url: sURL); sReq.httpMethod = "POST"
            sReq.httpBody = modifiedQData
            sReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (aData, _) = try await URLSession.shared.data(for: sReq)
            try Task.checkCancellation()
            if self.currentAudioSessionID == sessionID {
                PlayerManager.shared.enqueue(data: aData, sessionID: sessionID)
            }
        } catch is CancellationError {
            // Task cancelled; no-op
        } catch {
            if (error as NSError).code != NSURLErrorCancelled { print("Speech error: \(error)") }
        }
    }

    func resetSession() {
        stopGeneration()
        messages = []
        pendingAttachments = []
        isInSession = false
        contextHasExchange = false
        ollamaContextStartIndex = 0
        ollamaContextUsedTokens = 0
        contextUsageRatio = 0.0
        if aiProvider == .appleIntelligence {
            foundationSession = makeSession()
        }
    }
}
