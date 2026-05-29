import Foundation

enum AIProvider: String, CaseIterable {
    case ollama = "Ollama"
    case appleIntelligence = "Apple Intelligence"
}

struct UsageStats: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    var tokensPerSecond: Double?
    var ttft: Double? // Time To First Token
}

struct SearchSource: Codable, Identifiable {
    var id: UUID
    let title: String
    let url: String

    init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decode(String.self, forKey: .title)
        self.url = try c.decode(String.self, forKey: .url)
    }

    private enum CodingKeys: String, CodingKey { case id, title, url }
}

struct Message: Identifiable, Codable {
    var id: UUID
    let role: String
    var content: String
    var stats: UsageStats?
    var searchSources: [SearchSource]?

    init(id: UUID = UUID(), role: String, content: String, stats: UsageStats? = nil, searchSources: [SearchSource]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.stats = stats
        self.searchSources = searchSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.stats = try c.decodeIfPresent(UsageStats.self, forKey: .stats)
        self.searchSources = try c.decodeIfPresent([SearchSource].self, forKey: .searchSources)
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, stats, searchSources }
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
