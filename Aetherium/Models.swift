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
    var thinking: String?
    var stats: UsageStats?
    var searchSources: [SearchSource]?
    var attachments: [Attachment]?

    init(id: UUID = UUID(), role: String, content: String, thinking: String? = nil, stats: UsageStats? = nil, searchSources: [SearchSource]? = nil, attachments: [Attachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.stats = stats
        self.searchSources = searchSources
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.stats = try c.decodeIfPresent(UsageStats.self, forKey: .stats)
        self.searchSources = try c.decodeIfPresent([SearchSource].self, forKey: .searchSources)
        self.attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, thinking, stats, searchSources, attachments }
}

/// メッセージに添付されたファイル/画像。
/// - image: payload に base64（data:プレフィックス無し）、mime に "image/jpeg" 等。Ollama の images とサムネ表示の両方に使う。
/// - file:  payload に抽出済みテキスト。送信時に content へ合成する。
struct Attachment: Codable, Identifiable {
    enum Kind: String, Codable { case image, file }
    var id: UUID
    let kind: Kind
    let filename: String
    let payload: String
    let mime: String?

    init(id: UUID = UUID(), kind: Kind, filename: String, payload: String, mime: String? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.payload = payload
        self.mime = mime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.payload = try c.decode(String.self, forKey: .payload)
        self.mime = try c.decodeIfPresent(String.self, forKey: .mime)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, filename, payload, mime }
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
