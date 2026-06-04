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
    /// トークン削減と小型モデルでの指示追従向上のため英語で記述する。
    /// 応答言語は設定（`ResponseLanguage`）の指示をプロンプト先頭に別途注入する。
    static let appSystem = """
    Mathematics is rendered with KaTeX. Follow these rules.
    - Wrap display math in $$ ... $$
    - Wrap inline math in \\( ... \\) (do not use $ ... $)
    - Do not wrap math in a code block (```), or it will be shown as plain text.

    When asked to create or save a file, code, or data, always wrap the content in a code fence and write "language:filename" on the opening fence (e.g. ```python:main.py / ```csv:data.csv / ```json:config.json). Choose a filename and extension suitable for the content. This "language:filename" notation must never be omitted.
    """

    /// Web検索ツールを使うときの振る舞い指示。
    static let webSearch = "When using the web search tool, do not output the raw search result text. Read and understand the results, then answer concisely in your own words."

    /// RAG検索ツールを使うときの振る舞い指示。
    static let ragSearch = "You have access to a document search tool (ragSearch) over the user's registered local documents (specifications, meeting notes, design docs, etc.). When the user's question may relate to these documents, call ragSearch first and base your answer on the retrieved content. Do not output the raw retrieved text verbatim; read it and answer concisely in your own words."

    /// Web検索ツール（function calling）の説明文。
    static let webSearchToolDescription = "Searches the web for up-to-date information using SearXNG. Use it when asked about current events or the latest information."

    /// RAG検索ツール（function calling）の説明文。Ollama・Apple Intelligence 共通で使う。
    static let ragSearchToolDescription = "登録済みのドキュメント（仕様書・議事録・設計書など）から関連情報を検索する。質問に関連する社内ドキュメントの情報が必要な場合に使用する。"

    /// 呼び名が設定されているときに注入する、AI向けの呼びかけ指示。
    static func userName(_ name: String) -> String {
        """
        # About the user
        The user's name is "\(name)". Follow these guidelines.
        - Address them by name at natural points in the conversation to keep it friendly.
        - Do not fix a single honorific or form of address; choose it based on the mood of the conversation and the user's later instructions or preferences.
        """
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

/// RAG検索ツール（Apple Intelligence 用）。Ollama の executeRAGSearch と同じ検索・整形を行う。
struct RAGSearchTool: Tool {
    let client: RAGClient
    let resultLimit: Int
    let name = "ragSearch"
    let description = Prompts.ragSearchToolDescription

    @Generable
    struct Arguments {
        @Guide(description: "検索するクエリ文字列")
        var query: String
    }

    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: Arguments) async throws -> String {
        do {
            let results = try await client.search(query: arguments.query, limit: resultLimit)
            guard !results.isEmpty else { return "関連するドキュメントが見つかりませんでした" }
            return results.map { r in
                let source = r.tabName.map { "\(r.title) \($0)" } ?? r.title
                return "【\(source)】\n\(r.chunk)"
            }.joined(separator: "\n\n---\n\n")
        } catch {
            return "RAGサーバーへの接続に失敗しました: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var selectedModel: String = "" { didSet { persist(selectedModel, "selectedModel") } }
    @Published var models: [String] = []
    @Published var isGenerating = false
    @Published var isAudioPlaying = false
    @Published var selectedSpeakerID: Int = 3 { didSet { persist(selectedSpeakerID, "selectedSpeakerID") } }
    @Published var displaySpeakers: [(id: Int, name: String)] = []
    @Published var speechSpeed: Double = 1.00 { didSet { persist(speechSpeed, "speechSpeed") } }
    @Published var voiceEnabled: Bool = true { didSet { persist(voiceEnabled, "voiceEnabled") } }
    @Published var isFetching = false
    @Published var aiProvider: AIProvider = .ollama { didSet { persist(aiProvider.rawValue, "aiProvider"); pendingAttachments.removeAll() } }
    @Published var responseLanguage: ResponseLanguage = .japanese { didSet { persist(responseLanguage.rawValue, "responseLanguage") } }
    @Published var appleIntelligenceError: String? = nil
    @Published var webSearchEnabled: Bool = false { didSet { persist(webSearchEnabled, "webSearchEnabled") } }
    @Published var thinkingEnabled: Bool = false { didSet { persist(thinkingEnabled, "thinkingEnabled") } }
    @Published var searxngURL: String = ChatViewModel.defaultSearxngURL { didSet { persist(searxngURL, "searxngURL") } }
    /// Web検索（SearXNG）でAIへ渡す結果の最大件数。
    @Published var webSearchResultCount: Int = 5 { didSet { persist(webSearchResultCount, "webSearchResultCount") } }
    @Published var voicevoxURL: String = ChatViewModel.defaultVoicevoxURL { didSet { persist(voicevoxURL, "voicevoxURL") } }
    @Published var llmServerURL: String = ChatViewModel.defaultLLMServerURL { didSet { persist(llmServerURL, "llmServerURL") } }
    // MARK: RAG（ローカルRAG検索）
    @Published var ragEnabled: Bool = false { didSet { persist(ragEnabled, "ragEnabled") } }
    @Published var ragServerURL: String = ChatViewModel.defaultRAGServerURL {
        didSet {
            persist(ragServerURL, "ragServerURL")
            ragClient = RAGClient(baseURL: ragServerURL)  // URL変更時に再生成（管理画面と共有）
        }
    }
    /// RAG検索でAIへ渡す結果の最大件数。
    @Published var ragResultCount: Int = 3 { didSet { persist(ragResultCount, "ragResultCount") } }
    /// RAGClientのシングルインスタンス（RAGManagerViewとチャットで共有）。
    /// lazy のため ragServerURL 読み込み後に初めてアクセスされたとき正しいURLで生成される。
    private(set) lazy var ragClient = RAGClient(baseURL: ragServerURL)
    // MARK: RAG同期（旧 RAGManagerView の @State から移設）
    // Sheet を閉じてもチャットを続けながら同期を継続できるよう、状態と Task を ViewModel 側に保持する。
    @Published var ragDocuments: [RAGDocument] = []           // 一覧（サーバー登録＋ローカルスキャンのマージ結果）
    @Published var ragLocalTabs: [String: RAGLocalTab] = [:]  // tab_id → ローカルタブ（同期時のテキスト送信に使う）
    @Published var ragIsConnected = false
    @Published var ragIsLoading = false
    @Published var ragTotalDocuments = 0
    @Published var ragIsSyncing = false
    @Published var ragSyncProgress: (current: Int, total: Int)? = nil
    @Published var ragSyncingTabId: String? = nil
    @Published var ragSyncingLabel = ""
    @Published var ragSyncResult: SyncResult? = nil
    private var ragSyncTask: Task<Void, Never>? = nil
    /// 完了トースト（ragSyncResult）を一定時間後に自動で消すための待ちタスク。
    private var ragResultClearTask: Task<Void, Never>? = nil
    /// 監視フォルダ（"rag.watchedFolders" にJSON永続化。キー名は従来方式を維持する）。
    @Published var ragWatchedFolders: [WatchedFolder] = []
    /// 最終同期日時（"rag.lastSyncedAt" にepoch永続化。再起動後のインジケータ復元に使う）。
    @Published var ragLastSyncedAt: Date? = nil
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
    static let defaultRAGServerURL = "http://127.0.0.1:8000"
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

    var activeModelLabel: String {
        aiProvider == .appleIntelligence ? "Apple Intelligence" : selectedModel
    }

    /// Web検索トグルを切り替えられるか。コンテキストが空（開始前 or クリア直後）のときだけ可。
    /// Ollama はツール対応モデルのときのみ。
    var canToggleWebSearch: Bool {
        guard !contextHasExchange else { return false }
        return aiProvider == .appleIntelligence ? true : ollamaToolsSupported
    }

    /// RAGトグルを切り替えられるか。
    /// webSearchEnabledと同様、コンテキストが空のときのみ切替可。
    /// Apple Intelligence は常に可、Ollama はtool対応モデル限定。
    var canToggleRAG: Bool {
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
        if let v = d.string(forKey: "aetherium.responseLanguage"), let l = ResponseLanguage(rawValue: v) { responseLanguage = l }
        if d.object(forKey: "aetherium.webSearchEnabled") != nil { webSearchEnabled = d.bool(forKey: "aetherium.webSearchEnabled") }
        if d.object(forKey: "aetherium.thinkingEnabled") != nil { thinkingEnabled = d.bool(forKey: "aetherium.thinkingEnabled") }
        if let v = d.string(forKey: "aetherium.searxngURL"), !v.isEmpty { searxngURL = v }
        if d.object(forKey: "aetherium.webSearchResultCount") != nil { webSearchResultCount = d.integer(forKey: "aetherium.webSearchResultCount") }
        if d.object(forKey: "aetherium.ragEnabled") != nil { ragEnabled = d.bool(forKey: "aetherium.ragEnabled") }
        if let v = d.string(forKey: "aetherium.ragServerURL"), !v.isEmpty { ragServerURL = v }
        if d.object(forKey: "aetherium.ragResultCount") != nil { ragResultCount = d.integer(forKey: "aetherium.ragResultCount") }
        // RAG同期の永続化（キー名は RAGManagerView 時代の "rag.*" を維持する）。
        if let data = d.data(forKey: "rag.watchedFolders"),
           let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data) { ragWatchedFolders = folders }
        let lastSync = d.double(forKey: "rag.lastSyncedAt")
        if lastSync > 0 { ragLastSyncedAt = Date(timeIntervalSince1970: lastSync) }
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
        var parts: [String] = [responseLanguage.instruction, Prompts.appSystem]
        if let nameInstr = userNameInstruction { parts.append(nameInstr) }
        if let instr = activeCustomInstruction { parts.append(instr) }
        if webSearchEnabled { parts.append(Prompts.webSearch) }
        if ragEnabled { parts.append(Prompts.ragSearch) }
        return parts.joined(separator: "\n\n")
    }

    /// Apple Intelligence セッションに積むツール群（Web検索・RAG の各トグルに応じて構築）。
    private var appleSessionTools: [any Tool] {
        var tools: [any Tool] = []
        if webSearchEnabled {
            tools.append(WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL, resultLimit: webSearchResultCount))
        }
        if ragEnabled {
            tools.append(RAGSearchTool(client: ragClient, resultLimit: ragResultCount))
        }
        return tools
    }

    private func makeSession() -> LanguageModelSession {
        let tools = appleSessionTools
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
        let tools = appleSessionTools
        return tools.isEmpty
            ? LanguageModelSession(transcript: trimmed)
            : LanguageModelSession(tools: tools, transcript: trimmed)
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
        guard let url = URL(string: "\(ollamaNativeBaseURL)/api/show") else { return }
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
        let tools = appleSessionTools
        return tools.isEmpty
            ? LanguageModelSession(transcript: trimmed)
            : LanguageModelSession(tools: tools, transcript: trimmed)
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

    private var ollamaRAGToolSpec: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "ragSearch",
                "description": Prompts.ragSearchToolDescription,
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

    private func executeRAGSearch(query: String) async -> String {
        do {
            let results = try await ragClient.search(query: query, limit: ragResultCount)
            guard !results.isEmpty else { return "関連するドキュメントが見つかりませんでした" }
            return results.map { r in
                let source = r.tabName.map { "\(r.title) \($0)" } ?? r.title
                return "【\(source)】\n\(r.chunk)"
            }.joined(separator: "\n\n---\n\n")
        } catch {
            return "RAGサーバーへの接続に失敗しました: \(error.localizedDescription)"
        }
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
            var systemParts = [self.responseLanguage.instruction, Prompts.appSystem]
            if let nameInstr = self.userNameInstruction { systemParts.append(nameInstr) }
            if let instr = self.activeCustomInstruction { systemParts.append(instr) }
            // RAG ON時は、ツールを確実に使わせるための振る舞い指示を足す（tool descriptionの補強）。
            if self.ragEnabled && self.ollamaToolsSupported { systemParts.append(Prompts.ragSearch) }
            history.insert(["role": "system", "content": systemParts.joined(separator: "\n\n")], at: 0)

            let useWebSearch = self.webSearchEnabled && self.ollamaToolsSupported
            let useRAG       = self.ragEnabled       && self.ollamaToolsSupported
            let useTools     = useWebSearch || useRAG
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
                    var toolSpecs: [[String: Any]] = []
                    if useWebSearch { toolSpecs.append(self.ollamaWebSearchToolSpec) }
                    if useRAG       { toolSpecs.append(self.ollamaRAGToolSpec) }
                    requestBody["tools"] = toolSpecs
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
                        guard let query = tc.arguments["query"] as? String else {
                            history.append(["role": "tool", "content": "ツール不明", "tool_name": tc.name])
                            continue
                        }
                        let result: String
                        switch tc.name {
                        case "webSearch": result = await self.executeWebSearch(query: query)
                        case "ragSearch": result = await self.executeRAGSearch(query: query)
                        default:
                            history.append(["role": "tool", "content": "ツール不明", "tool_name": tc.name])
                            continue
                        }
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
                // 本文が空のまま終わった場合のフォールバック（モデルの空応答・ツール呼び出し失敗など）。
                // ユーザーが停止ボタンで中断したとき（キャンセル）は出さない。
                if !Task.isCancelled, let i = indexForAssistant(),
                   self.messages[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.messages[i].content = "⚠️ 回答が空のまま終了しました。もう一度お試しください（「再思考」ボタンで再生成できます）。"
                }
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
        contextHasExchange = false
        ollamaContextStartIndex = 0
        ollamaContextUsedTokens = 0
        contextUsageRatio = 0.0
        if aiProvider == .appleIntelligence {
            foundationSession = makeSession()
        }
    }

    // MARK: - RAG ドキュメント同期
    // 旧 RAGManagerView の @State 群とロジックを移設したもの。Sheet の寿命より長生きする同期 Task を
    // ViewModel 側で保持し、Sheet を閉じてもチャットを続けながら同期を継続できるようにする。

    /// ツールバー同期インジケータの状態（RAG ON 時のみ View で表示する）。
    enum RAGSyncIndicator {
        case syncing(current: Int, total: Int)  // 🔄 同期中 3/12
        case success(total: Int)                // ✅ 12/12
        case partial(done: Int, total: Int)     // ⚠️ 10/12
        case allFailed                          // ⚠️ 同期失敗
        case lastSynced(Date)                   // 🕐 最終同期 6/04 14:30
    }

    /// 現在の同期状態から導くインジケータ。何も無ければ nil（＝非表示）。
    /// 同期結果はメモリ上のため再起動で揮発する。その場合は lastSyncedAt から「最終同期」を表示する。
    var ragSyncIndicator: RAGSyncIndicator? {
        if ragIsSyncing {
            let p = ragSyncProgress ?? (0, 0)
            return .syncing(current: p.current, total: p.total)
        }
        if let r = ragSyncResult {
            let done = r.added + r.updated + r.deleted
            let total = done + r.errors.count
            if total > 0 {
                if r.errors.isEmpty { return .success(total: total) }
                if done == 0 { return .allFailed }
                return .partial(done: done, total: total)
            }
        }
        if let d = ragLastSyncedAt { return .lastSynced(d) }
        return nil
    }

    private func saveWatchedFolders(_ folders: [WatchedFolder]) {
        ragWatchedFolders = folders
        UserDefaults.standard.set((try? JSONEncoder().encode(folders)) ?? Data(), forKey: "rag.watchedFolders")
    }

    /// 監視フォルダを追加する（フォルダ選択 → security-scoped bookmark 保存 → 再スキャン）。
    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var folders = ragWatchedFolders
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        folders.append(WatchedFolder(path: url.path, bookmark: bookmark))
        saveWatchedFolders(folders)
        Task { await refreshRAG() }
    }

    /// 監視フォルダを外す（パス情報のみ削除。登録済みドキュメントは削除しない）。
    func removeWatchedFolder(_ id: UUID) {
        saveWatchedFolders(ragWatchedFolders.filter { $0.id != id })
        Task { await refreshRAG() }
    }

    /// サーバー登録情報とローカルスキャンを取得・マージして一覧を更新する。
    func refreshRAG() async {
        ragIsLoading = true
        defer { ragIsLoading = false }
        let folders = ragWatchedFolders

        // 接続確認
        var connected = false
        do { connected = try await ragClient.healthCheck() } catch { connected = false }
        ragIsConnected = connected
        guard connected else {
            ragDocuments = []; ragLocalTabs = [:]; ragTotalDocuments = 0
            return
        }

        // サーバー登録情報
        var server: [RAGDocument] = []
        do { server = try await ragClient.listDocuments() } catch { server = [] }
        ragTotalDocuments = server.count

        // ローカルスキャン（main actor外で実行）
        let local = await Task.detached { RAGScanner.scan(folders: folders) }.value

        let (docs, locMap) = Self.mergeRAG(server: server, local: local)
        ragDocuments = docs
        ragLocalTabs = locMap
    }

    /// サーバー登録情報とローカルスキャン結果をマージし、各タブの status を計算する。
    static func mergeRAG(server: [RAGDocument], local: [RAGLocalTab]) -> ([RAGDocument], [String: RAGLocalTab]) {
        let localByTab = Dictionary(local.map { ($0.tabId, $0) }, uniquingKeysWith: { a, _ in a })
        let serverTabIds = Set(server.flatMap { $0.tabs.map(\.id) })

        // file_path ごとにタブを集約。
        struct Group { var title: String; var registeredAt: Date; var tabs: [String: RAGDocumentTab]; var order: [String] }
        var groups: [String: Group] = [:]
        var fileOrder: [String] = []

        func ensure(_ filePath: String, title: String, registeredAt: Date) {
            if groups[filePath] == nil {
                groups[filePath] = Group(title: title, registeredAt: registeredAt, tabs: [:], order: [])
                fileOrder.append(filePath)
            }
        }

        // サーバー登録タブ → synced / modified / missing
        for doc in server {
            ensure(doc.filePath, title: doc.title, registeredAt: doc.registeredAt)
            for tab in doc.tabs {
                var t = tab
                if let loc = localByTab[tab.id] {
                    t.status = (loc.checksum == tab.serverChecksum) ? .synced : .modified
                } else {
                    t.status = .missing
                }
                if groups[doc.filePath]!.tabs[tab.id] == nil { groups[doc.filePath]!.order.append(tab.id) }
                groups[doc.filePath]!.tabs[tab.id] = t
            }
        }

        // ローカルのみ（サーバー未登録）→ new
        for loc in local where !serverTabIds.contains(loc.tabId) {
            ensure(loc.filePath, title: loc.title, registeredAt: Date())
            if groups[loc.filePath]!.tabs[loc.tabId] == nil { groups[loc.filePath]!.order.append(loc.tabId) }
            groups[loc.filePath]!.tabs[loc.tabId] = RAGDocumentTab(
                id: loc.tabId, tabName: loc.tabName, mdPath: loc.mdPath,
                serverChecksum: "", chunkCount: 0, status: .new
            )
        }

        var documents: [RAGDocument] = fileOrder.compactMap { filePath in
            guard let g = groups[filePath] else { return nil }
            let tabs = g.order.compactMap { g.tabs[$0] }
            return RAGDocument(title: g.title, filePath: filePath, registeredAt: g.registeredAt, tabs: tabs)
        }
        documents.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (documents, localByTab)
    }

    /// new/modified/missing なタブをサーバーへ反映する。Sheet を閉じてもバックグラウンドで継続する。
    /// 開いたまま監視フォルダへ追加・変更されたファイルも拾えるよう、対象収集の前に再スキャンする。
    func startRAGSync() {
        guard ragIsConnected, !ragIsSyncing else { return }
        ragResultClearTask?.cancel()  // 前回完了トーストの自動消去待ちを止める
        ragIsSyncing = true
        ragSyncResult = nil
        ragSyncingLabel = ""
        ragSyncProgress = nil

        // @MainActor 由来の Task なので本体も MainActor 上で動く（プロパティへ直接代入できる）。
        ragSyncTask = Task {
            // 開いたまま追加・変更されたファイルを検出するため、対象収集の前に再スキャンする。
            await self.refreshRAG()
            if Task.isCancelled {
                self.ragIsSyncing = false
                self.ragSyncProgress = nil
                self.ragSyncTask = nil
                return
            }

            // 処理対象（new/modified/missing）を順番に収集。元の status を保持する。
            struct Job { let tabId: String; let status: RAGDocumentStatus; let label: String }
            var jobs: [Job] = []
            var syncedCount = 0
            for doc in self.ragDocuments {
                for tab in doc.tabs {
                    switch tab.status {
                    case .new, .modified, .missing:
                        let lbl = tab.tabName.map { "\(doc.title) \($0)" } ?? doc.title
                        jobs.append(Job(tabId: tab.id, status: tab.status, label: lbl))
                    case .synced:
                        syncedCount += 1
                    default:
                        break
                    }
                }
            }
            guard !jobs.isEmpty else {
                self.ragSyncResult = SyncResult(added: 0, updated: 0, deleted: 0, skipped: syncedCount, errors: [])
                self.ragIsSyncing = false
                self.ragSyncTask = nil
                self.scheduleSyncResultClear()
                return
            }

            let folders = self.ragWatchedFolders
            let localSnapshot = self.ragLocalTabs
            self.ragSyncProgress = (0, jobs.count)
            self.markRAGPending(Set(jobs.map(\.tabId)))

            var added = 0, updated = 0, deleted = 0
            var errors: [SyncError] = []

            for (i, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                self.ragSyncingTabId = job.tabId
                self.ragSyncingLabel = job.label
                self.ragSyncProgress = (i, jobs.count)
                do {
                    switch job.status {
                    case .missing:
                        try await self.ragClient.deleteDocuments(tabIds: [job.tabId])
                        deleted += 1
                    case .new, .modified:
                        guard let loc = localSnapshot[job.tabId] else {
                            errors.append(SyncError(id: job.tabId, title: job.label, reason: "ローカル情報が見つかりません"))
                            continue
                        }
                        // テキスト抽出はフォルダのセキュリティスコープ内で同期的に行う。
                        let text = RAGScanner.withFolderAccess(folders) {
                            RAGScanner.extractText(from: URL(fileURLWithPath: loc.mdPath))
                        }
                        guard let text, !text.isEmpty else {
                            errors.append(SyncError(id: job.tabId, title: job.label, reason: "テキストを抽出できませんでした"))
                            continue
                        }
                        _ = try await self.ragClient.registerDocument(
                            tabId: loc.tabId, title: loc.title, tabName: loc.tabName,
                            filePath: loc.filePath, mdPath: loc.mdPath, checksum: loc.checksum,
                            text: text, isUpdate: job.status == .modified
                        )
                        if job.status == .new { added += 1 } else { updated += 1 }
                    default:
                        break
                    }
                } catch {
                    errors.append(SyncError(id: job.tabId, title: job.label,
                                            reason: error.localizedDescription))
                }
            }

            self.ragSyncResult = SyncResult(added: added, updated: updated, deleted: deleted,
                                            skipped: syncedCount, errors: errors)
            let now = Date()
            self.ragLastSyncedAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "rag.lastSyncedAt")
            self.ragSyncingTabId = nil
            self.ragSyncingLabel = ""
            self.ragSyncProgress = nil
            self.ragIsSyncing = false
            self.ragSyncTask = nil
            await self.refreshRAG()
            self.scheduleSyncResultClear()
        }
    }

    /// 同期完了トースト（ragSyncResult）を数秒後に自動で消す。
    /// クリア後は ragSyncIndicator が lastSyncedAt から「🕐 最終同期 日時」へ自然に戻る。
    private func scheduleSyncResultClear() {
        ragResultClearTask?.cancel()
        ragResultClearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.ragSyncResult = nil
        }
    }

    func cancelRAGSync() {
        ragSyncTask?.cancel()
        ragSyncTask = nil
        ragIsSyncing = false
        ragSyncingTabId = nil
        ragSyncingLabel = ""
        ragSyncProgress = nil
        Task { await refreshRAG() }
    }

    /// 指定タブの status を pending にして「待機中」表示にする。
    private func markRAGPending(_ ids: Set<String>) {
        for i in ragDocuments.indices {
            for j in ragDocuments[i].tabs.indices where ids.contains(ragDocuments[i].tabs[j].id) {
                ragDocuments[i].tabs[j].status = .pending
            }
        }
    }
}
