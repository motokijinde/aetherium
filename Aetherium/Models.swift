import Foundation

enum AIProvider: String, CaseIterable {
    case ollama = "Ollama"
    case appleIntelligence = "Apple Intelligence"
}

struct UsageStats: Codable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    var tokensPerSecond: Double?
    var ttft: Double? // Time To First Token
}

struct SearchSource: Codable, Identifiable {
    var id = UUID()
    let title: String
    let url: String
}

struct Message: Identifiable, Codable {
    var id = UUID()
    let role: String
    var content: String
    var stats: UsageStats?
    var searchSources: [SearchSource]?
}

struct VVStyle: Codable, Hashable {
    let id: Int
    let name: String
}

struct VVSpeaker: Codable, Identifiable {
    var id: String { speaker_uuid }
    let name: String
    let speaker_uuid: String
    let styles: [VVStyle]
}
