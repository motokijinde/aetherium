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
    @Published var selectedModel: String = ""
    @Published var models: [String] = []
    @Published var isInSession = false
    @Published var isGenerating = false
    @Published var isAudioPlaying = false
    @Published var selectedSpeakerID: Int = 3
    @Published var displaySpeakers: [(id: Int, name: String)] = []
    @Published var speechSpeed: Double = 1.00
    @Published var isFetching = false
    @Published var aiProvider: AIProvider = .ollama
    @Published var appleIntelligenceError: String? = nil
    @Published var webSearchEnabled: Bool = false
    @Published var searxngURL: String = "http://localhost:8080"
    @Published var contextUsageRatio: Double = 0.0

    private let estimatedContextCharLimit = 8192  // ~4096 tokens * 2 chars/token
    private let searchResultsCollector = SearchResultsCollector()
    private var generatingTask: Task<Void, Never>?
    private var speechQueue: [(text: String, sessionID: UUID)] = []
    private var speechQueueTask: Task<Void, Never>?
    private var currentAudioSessionID: UUID? = nil
    private var streamTask: URLSessionTask?
    private var playbackStateObserver: NSObjectProtocol?
    private var foundationSession: LanguageModelSession?

    var currentSpeakerName: String { displaySpeakers.first(where: { $0.id == selectedSpeakerID })?.name ?? "AI" }

    var activeModelLabel: String {
        aiProvider == .appleIntelligence ? "Apple Intelligence" : selectedModel
    }

    var canStartSession: Bool {
        let voiceReady = !displaySpeakers.isEmpty
        if aiProvider == .appleIntelligence {
            return appleIntelligenceError == nil && voiceReady
        } else {
            return !models.isEmpty && voiceReady
        }
    }

    let llmServerURL = "http://127.0.0.1:11434/v1"
    let voicevoxURL = "http://127.0.0.1:50021"

    init() {
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

    private func segmentCharCount(_ segments: [Transcript.Segment]) -> Int {
        segments.reduce(0) { count, seg in
            if case .text(let ts) = seg { return count + ts.content.count }
            return count
        }
    }

    func updateContextUsage() {
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
    }

    private let webSearchInstructions = "Web検索ツールを使用する場合、検索結果のテキストをそのまま出力しないでください。検索結果を参照して内容を理解し、自分の言葉で簡潔に回答してください。"

    private func makeSession() -> LanguageModelSession {
        webSearchEnabled
            ? LanguageModelSession(tools: [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL)], instructions: webSearchInstructions)
            : LanguageModelSession()
    }

    private func makeTrimmedSession() -> LanguageModelSession {
        guard let current = foundationSession else { return makeSession() }
        let all = Array(current.transcript)
        let instructions = all.filter { if case .instructions = $0 { return true }; return false }
        let exchanges = all.filter { if case .instructions = $0 { return false }; return true }
        let trimmed = Transcript(entries: instructions + exchanges.suffix(4))
        return webSearchEnabled
            ? LanguageModelSession(tools: [WebSearchTool(collector: searchResultsCollector, searxngURL: searxngURL)], transcript: trimmed)
            : LanguageModelSession(transcript: trimmed)
    }

    func clearContext() {
        stopGeneration()
        foundationSession = makeSession()
        messages.append(Message(role: "system", content: "コンテキストをリセットしました"))
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

    func fetchAll() async {
        isFetching = true
        await fetchModels()
        await fetchVVSpeakers()
        isFetching = false
    }

    func fetchModels() async {
        guard let url = URL(string: "\(llmServerURL)/models") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                let fetchedModels = dataArray.compactMap { $0["id"] as? String }
                self.models = fetchedModels
                if self.selectedModel.isEmpty { self.selectedModel = fetchedModels.first ?? "" }
            }
        } catch {
            print("LLM Server not found")
            self.models = []
        }
    }

    func fetchVVSpeakers() async {
        guard let url = URL(string: "\(voicevoxURL)/speakers") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([VVSpeaker].self, from: data)
            self.displaySpeakers = decoded.compactMap { speaker in
                guard let firstStyle = speaker.styles.first else { return nil }
                return (id: firstStyle.id, name: speaker.name)
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
        if aiProvider == .appleIntelligence {
            sendMessageApple(text)
        } else {
            sendMessageOllama(text)
        }
    }

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
            let indexForAssistant: () -> Int? = {
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
                                prompt_tokens: text.count,
                                completion_tokens: charCount,
                                total_tokens: text.count + charCount,
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

    private func sendMessageOllama(_ text: String) {
        stopGeneration()
        isGenerating = true
        let audioSessionID = UUID()
        currentAudioSessionID = audioSessionID
        let assistantID = UUID()
        self.messages.append(Message(role: "user", content: text))
        self.messages.append(Message(id: assistantID, role: "assistant", content: ""))
        let requestMessages = self.messages.dropLast().map { ["role": $0.role, "content": $0.content] }
        let requestModel = self.selectedModel
        generatingTask = Task {
            let requestStartTime = Date()
            var firstTokenTime: Date?
            var localSpeechBuffer = ""
            let indexForAssistant: () -> Int? = {
                return self.messages.firstIndex(where: { $0.id == assistantID })
            }

            guard let url = URL(string: "\(llmServerURL)/chat/completions") else {
                await MainActor.run {
                    self.isGenerating = false
                    self.generatingTask = nil
                    self.currentAudioSessionID = nil
                }
                return
            }
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": requestModel,
                "messages": requestMessages,
                "stream": true,
                "stream_options": ["include_usage": true]
            ])

            do {
                let (stream, _) = try await URLSession.shared.bytes(for: request)
                await MainActor.run {
                    self.streamTask = stream.task
                }
                for try await line in stream.lines {
                    if Task.isCancelled { break }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("data: [DONE]") || trimmed == "data: [DONE]" { break }
                    if line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            if firstTokenTime == nil { firstTokenTime = Date() }
                            await MainActor.run {
                                if let i = indexForAssistant() {
                                    self.messages[i].content += content
                                }
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
                        if let usageDict = json["usage"] as? [String: Int] {
                            let totalDuration = Date().timeIntervalSince(firstTokenTime ?? requestStartTime)
                            let ttftValue = firstTokenTime?.timeIntervalSince(requestStartTime)
                            await MainActor.run {
                                if let i = indexForAssistant() {
                                    self.messages[i].stats = UsageStats(prompt_tokens: usageDict["prompt_tokens"] ?? 0, completion_tokens: usageDict["completion_tokens"] ?? 0, total_tokens: usageDict["total_tokens"] ?? 0, tokensPerSecond: Double(usageDict["completion_tokens"] ?? 0) / max(totalDuration, 0.001), ttft: ttftValue)
                                }
                            }
                        }
                    }
                }
                if !Task.isCancelled && !localSpeechBuffer.isEmpty {
                    await MainActor.run { self.enqueueSpeech(localSpeechBuffer, sessionID: audioSessionID) }
                    localSpeechBuffer = ""
                }
            } catch {
                if (error as NSError).code != NSURLErrorCancelled {
                    print("Stream error: \(error)")
                }
            }
            await MainActor.run {
                self.isGenerating = false
                self.generatingTask = nil
                self.streamTask = nil
            }
        }
    }

    private func enqueueSpeech(_ text: String, sessionID: UUID) {
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
        if aiProvider == .appleIntelligence {
            foundationSession = makeSession()
        }
    }
}
