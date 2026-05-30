import SwiftUI
import Combine
import FoundationModels

actor SearchResultsCollector {
    var sources: [SearchSource] = []
    func append(_ source: SearchSource) { sources.append(source) }
    func reset() { sources = [] }
}

struct WebSearchTool: Tool {
    let collector: SearchResultsCollector
    let searxngURL: String
    let name = "webSearch"
    let description = "SearXNGを使って最新のWeb情報を検索します。最新情報や時事問題について質問されたときに使用してください。"

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
            for r in results.prefix(5) {
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
    @Published var aiProvider: AIProvider = .ollama { didSet { persist(aiProvider.rawValue, "aiProvider") } }
    @Published var appleIntelligenceError: String? = nil
    @Published var webSearchEnabled: Bool = false { didSet { persist(webSearchEnabled, "webSearchEnabled") } }
    @Published var thinkingEnabled: Bool = false { didSet { persist(thinkingEnabled, "thinkingEnabled") } }
    @Published var searxngURL: String = ChatViewModel.defaultSearxngURL { didSet { persist(searxngURL, "searxngURL") } }
    @Published var voicevoxURL: String = ChatViewModel.defaultVoicevoxURL { didSet { persist(voicevoxURL, "voicevoxURL") } }
    @Published var llmServerURL: String = ChatViewModel.defaultLLMServerURL { didSet { persist(llmServerURL, "llmServerURL") } }
    @Published var customInstructions: String = "" { didSet { persist(customInstructions, "customInstructions") } }
    @Published var customInstructionsEnabled: Bool = true { didSet { persist(customInstructionsEnabled, "customInstructionsEnabled") } }
    @Published var contextUsageRatio: Double = 0.0
    @Published var ollamaContextSize: Int = 4096 { didSet { persist(ollamaContextSize, "ollamaContextSize") } }
    static let ollamaContextSizeOptions = [2048, 4096, 8192, 16384, 32768, 65536]
    // サーバー接続先のデフォルト値（いずれもIPv4ループバック直指定で統一）。
    static let defaultLLMServerURL = "http://127.0.0.1:11434/v1"
    static let defaultVoicevoxURL = "http://127.0.0.1:50021"
    static let defaultSearxngURL = "http://127.0.0.1:8080"
    @Published var ollamaToolsSupported: Bool = false
    @Published var ollamaThinkingSupported: Bool = false
    @Published var ollamaContextUsedTokens: Int = 0
    /// 現在のコンテキストにやり取りがあるか（Web検索トグルの切替可否に使用）。
    @Published var contextHasExchange: Bool = false
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
        if let v = d.string(forKey: "aetherium.voicevoxURL"), !v.isEmpty { voicevoxURL = v }
        if let v = d.string(forKey: "aetherium.llmServerURL"), !v.isEmpty { llmServerURL = v }
        if let v = d.string(forKey: "aetherium.customInstructions") { customInstructions = v }
        if d.object(forKey: "aetherium.customInstructionsEnabled") != nil { customInstructionsEnabled = d.bool(forKey: "aetherium.customInstructionsEnabled") }
        if d.object(forKey: "aetherium.ollamaContextSize") != nil { ollamaContextSize = d.integer(forKey: "aetherium.ollamaContextSize") }
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

    private let webSearchInstructions = "Web検索ツールを使用する場合、検索結果のテキストをそのまま出力しないでください。検索結果を参照して内容を理解し、自分の言葉で簡潔に回答してください。"

    /// アプリ固有のシステム指示。表示（KaTeX）を壊さないための固定ルールで、常に適用する。
    static let appSystemInstructions = """
    数式は KaTeX で表示されます。次のお作法に従ってください。
    - ディスプレイ数式は $$ ... $$ で囲む
    - インライン数式は \\( ... \\) で囲む（$ ... $ は使わない）
    - 数式をコードブロック(```)で囲まない（そのまま文字列として表示されてしまう）
    """

    /// 有効かつ空でないカスタム指示（無効・空ならnil）。注入・トークン見積もりの共通判定に使う。
    private var activeCustomInstruction: String? {
        guard customInstructionsEnabled else { return nil }
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// アプリのシステム指示・ユーザーのカスタム指示・Web検索用指示を結合した、セッションに渡す最終instructions。
    /// アプリのシステム指示が常に含まれるため必ず非nil。
    private var effectiveInstructions: String? {
        var parts: [String] = [ChatViewModel.appSystemInstructions]
        if let instr = activeCustomInstruction { parts.append(instr) }
        if webSearchEnabled { parts.append(webSearchInstructions) }
        return parts.joined(separator: "\n\n")
    }

    private func makeSession() -> LanguageModelSession {
        let tools = webSearchEnabled
            ? [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL)]
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
            ? LanguageModelSession(tools: [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL)], transcript: trimmed)
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
        totalChars += ChatViewModel.appSystemInstructions.count
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
            }
            // num_ctx の自動取得は行わない：ユーザーがスライダーで選んだ値を尊重する
        } catch { }
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

    // MARK: - Apple Intelligence

    private func sendMessageApple(_ text: String, retryAfterTrim: Bool = false) {
        guard let session = foundationSession else { return }
        stopGeneration()
        isGenerating = true
        let audioSessionID = UUID()
        currentAudioSessionID = audioSessionID
        let assistantID = UUID()
        if !retryAfterTrim { messages.append(Message(role: "user", content: text)) }
        messages.append(Message(id: assistantID, role: "assistant", content: ""))

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
                "description": "SearXNGを使って最新のWeb情報を検索します。最新情報や時事問題について質問されたときに使用してください。",
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
            for r in results.prefix(5) {
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
        isGenerating = true
        let audioSessionID = UUID()
        currentAudioSessionID = audioSessionID
        let assistantID = UUID()
        messages.append(Message(role: "user", content: text))
        messages.append(Message(id: assistantID, role: "assistant", content: ""))

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
            var history: [[String: Any]] = Array(self.messages[self.ollamaContextStartIndex...])
                .dropLast()  // exclude empty assistant placeholder
                .filter { $0.role != "system" }
                .map { ["role": $0.role, "content": $0.content] }

            // アプリのシステム指示（常に）＋ユーザーのカスタム指示 を1つのsystemにまとめて履歴の先頭へ差し込む
            // （画面表示用のお知らせsystemメッセージとは別管理）
            var systemParts = [ChatViewModel.appSystemInstructions]
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
                var requestBody: [String: Any] = [
                    "model": self.selectedModel,
                    "messages": history,
                    "stream": true,
                    "options": ["num_ctx": self.ollamaContextSize]
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
