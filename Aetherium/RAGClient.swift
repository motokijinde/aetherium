import Foundation
import CryptoKit
import PDFKit

// MARK: - データモデル

/// 管理UI表示用：登録済み／ローカル検出ドキュメント1件。
///
/// xlsx系・単体ファイルともに tabs に必ず1件以上入る統一構造。
/// - xlsx系: 各タブMDが1件ずつ tabs に入る（tabs.count >= 1, tabName != nil）
/// - 単体ファイル: ファイル自体が tabs に1件だけ入る（tabs.count == 1, tabName == nil）
///
/// サーバーから取得した登録情報（GET /documents）とローカルスキャン結果を
/// マージして組み立てる。status は各 tab の status を比較して計算する。
struct RAGDocument: Identifiable, Decodable {
    // id は filePath をキーに管理する（サーバーは返さない）。
    // filePath が同じドキュメントは必ず同じIDになる。
    var id: String { filePath }
    let title: String            // 表示名（file_path の lastPathComponent）
    let filePath: String         // xlsxの絶対パス（単体ファイルはそのファイルのパス）
    let registeredAt: Date       // 最終同期日時（更新のたびに更新される）
    var tabs: [RAGDocumentTab]   // タブ一覧（必ず1件以上。単体ファイルも1件入る）

    /// 親ステータス = 子の最悪値。優先順位: error > missing > modified > new > synced。
    var status: RAGDocumentStatus {
        if tabs.isEmpty { return .synced }
        if tabs.contains(where: { $0.status == .pending })  { return .pending }
        if tabs.contains(where: { $0.status == .error })    { return .error }
        if tabs.contains(where: { $0.status == .missing })  { return .missing }
        if tabs.contains(where: { $0.status == .modified }) { return .modified }
        if tabs.contains(where: { $0.status == .new })      { return .new }
        return .synced
    }

    /// xlsx系（タブを持つ）か単体ファイルか。先頭タブの tabName で判定する。
    var isWorkbook: Bool { tabs.first?.tabName != nil }

    init(title: String, filePath: String, registeredAt: Date, tabs: [RAGDocumentTab]) {
        self.title = title
        self.filePath = filePath
        self.registeredAt = registeredAt
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case title, tabs
        case filePath = "file_path"
        case registeredAt = "registered_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.filePath = try c.decode(String.self, forKey: .filePath)
        let dateStr = try c.decode(String.self, forKey: .registeredAt)
        self.registeredAt = RAGClient.parseISO8601(dateStr) ?? Date()
        self.tabs = try c.decode([RAGDocumentTab].self, forKey: .tabs)
    }
}

/// ドキュメントの各タブ（xlsx系）またはファイル自体（単体ファイル）。
/// 削除・更新の最小単位。tab_id単位でQdrantのchunkを操作する。
struct RAGDocumentTab: Identifiable, Decodable {
    let id: String             // tab_id（SHA-256(mdPath or filePath)から生成）
    let tabName: String?       // タブ名（xlsx系: 例「【テーブル定義】」。単体ファイル: nil）
    let mdPath: String         // タブMDの絶対パス（単体ファイルはそのファイルのパス）
    var serverChecksum: String // サーバーに登録済みのSHA-256（未登録は空文字）
    var chunkCount: Int        // チャンク数
    // status はSwift側で計算（サーバーからは返ってこない）。
    var status: RAGDocumentStatus = .synced

    init(id: String, tabName: String?, mdPath: String,
         serverChecksum: String, chunkCount: Int, status: RAGDocumentStatus = .synced) {
        self.id = id
        self.tabName = tabName
        self.mdPath = mdPath
        self.serverChecksum = serverChecksum
        self.chunkCount = chunkCount
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tabName = "tab_name"
        case mdPath = "md_path"
        case serverChecksum = "checksum"
        case chunkCount = "chunk_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.tabName = try c.decodeIfPresent(String.self, forKey: .tabName)
        self.mdPath = try c.decode(String.self, forKey: .mdPath)
        self.serverChecksum = try c.decode(String.self, forKey: .serverChecksum)
        self.chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        self.status = .synced
    }
}

enum RAGDocumentStatus: String, Codable {
    case synced   // チェックサム一致・同期済み
    case modified // チェックサム不一致（ファイルが変更されている）
    case missing  // ファイルが存在しない（Qdrantには登録されているがローカルに見つからない）
    case new      // Qdrantに未登録（監視フォルダにあるが未同期）
    case error    // 処理エラー
    case pending  // 同期中・待機中
}

/// 同期結果サマリー（Swift側でカウントして保持）。
struct SyncResult {
    let added: Int
    let updated: Int
    let deleted: Int
    let skipped: Int
    let errors: [SyncError]
}

struct SyncError: Identifiable {
    let id: String       // tab_id or filePath
    let title: String    // ファイル名
    let reason: String   // エラー内容
}

/// RAG検索結果（チャット内で使用）。
struct RAGSearchResult: Decodable {
    let documentId: String
    let title: String       // ファイル名（例: 設計書.xlsx）
    let tabName: String?    // タブ名（xlsx系のみ。単体ファイルはnil）
    let chunk: String       // ヒットしたチャンクのテキスト
    let score: Float        // コサイン類似度スコア

    private enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case title
        case tabName = "tab_name"
        case chunk, score
    }
}

/// 監視フォルダ（AppStorageで永続化）。
/// サンドボックス下でも再起動後にアクセスできるよう、security-scoped bookmark を保持する。
struct WatchedFolder: Identifiable, Codable {
    let id: UUID
    let path: String
    var bookmark: Data?        // security-scoped bookmark（NSOpenPanel選択時に作成）
    var lastSyncedAt: Date?

    init(id: UUID = UUID(), path: String, bookmark: Data? = nil, lastSyncedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.lastSyncedAt = lastSyncedAt
    }
}

/// ローカルスキャンで検出したタブ1件（同期時のテキスト送信に必要な情報を保持）。
struct RAGLocalTab: Identifiable, Sendable {
    var id: String { tabId }
    let tabId: String
    let title: String        // 表示名（xlsx名 or 単体ファイル名）
    let tabName: String?     // xlsx系: タブ名／単体: nil
    let filePath: String     // xlsxの絶対パス（単体はそのファイル）
    let mdPath: String       // タブMD／単体ファイルの絶対パス
    let checksum: String     // ローカルファイルのSHA-256（"sha256:..."形式）
}

// MARK: - RAGClient（HTTPクライアント）

enum RAGClientError: Error, LocalizedError {
    case serverUnreachable
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:    return "RAGサーバーに接続できません"
        case .invalidResponse:      return "サーバーの応答を解釈できません"
        case .serverError(let m):   return m
        }
    }
}

actor RAGClient {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    private var trimmedBase: String {
        var s = baseURL
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // 接続確認（Qdrant・Ollama両方の疎通確認をサーバーが行う）。
    func healthCheck() async throws -> Bool {
        guard let url = URL(string: "\(trimmedBase)/health") else { throw RAGClientError.invalidResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (json["status"] as? String) == "ok"
        } catch {
            throw RAGClientError.serverUnreachable
        }
    }

    // ドキュメント管理（サーバーの登録情報を返す。statusはSwift側で計算）。
    func listDocuments() async throws -> [RAGDocument] {
        guard let url = URL(string: "\(trimmedBase)/documents") else { throw RAGClientError.invalidResponse }
        let (data, resp) = try await get(url)
        try Self.ensureOK(resp, data)
        struct ListResponse: Decodable { let documents: [RAGDocument] }
        do {
            return try JSONDecoder().decode(ListResponse.self, from: data).documents
        } catch {
            throw RAGClientError.invalidResponse
        }
    }

    // ドキュメント登録（1タブ1リクエスト。Swift側がテキストを抽出して送る）。
    // isUpdate=true のとき、サーバーは registered_at を既存の値から引き継ぐ。
    func registerDocument(
        tabId: String,
        title: String,
        tabName: String?,
        filePath: String,
        mdPath: String,
        checksum: String,
        text: String,
        isUpdate: Bool
    ) async throws -> Int {
        guard let url = URL(string: "\(trimmedBase)/documents") else { throw RAGClientError.invalidResponse }
        let body: [String: Any] = [
            "tab_id": tabId,
            "title": title,
            "tab_name": tabName as Any? ?? NSNull(),
            "file_path": filePath,
            "md_path": mdPath,
            "checksum": checksum,
            "text": text,
            "is_update": isUpdate
        ]
        let (data, resp) = try await send(url, method: "POST", body: body)
        try Self.ensureOK(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["chunk_count"] as? Int else {
            throw RAGClientError.invalidResponse
        }
        return count
    }

    // 削除（tab_id複数指定で一括削除。削除したtab数を返す）。
    @discardableResult
    func deleteDocuments(tabIds: [String]) async throws -> Int {
        guard let url = URL(string: "\(trimmedBase)/documents") else { throw RAGClientError.invalidResponse }
        let (data, resp) = try await send(url, method: "DELETE", body: ["tab_ids": tabIds])
        try Self.ensureOK(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deleted = json["deleted"] as? Int else {
            throw RAGClientError.invalidResponse
        }
        return deleted
    }

    // チャット用検索。
    func search(query: String, limit: Int) async throws -> [RAGSearchResult] {
        guard let url = URL(string: "\(trimmedBase)/search") else { throw RAGClientError.invalidResponse }
        let (data, resp) = try await send(url, method: "POST", body: ["query": query, "limit": limit])
        try Self.ensureOK(resp, data)
        struct SearchResponse: Decodable { let results: [RAGSearchResult] }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            throw RAGClientError.invalidResponse
        }
    }

    // MARK: - HTTP ヘルパー

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        do { return try await URLSession.shared.data(for: req) }
        catch { throw RAGClientError.serverUnreachable }
    }

    private func send(_ url: URL, method: String, body: [String: Any]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120  // Embedding待ちがあるため長めに取る
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do { return try await URLSession.shared.data(for: req) }
        catch { throw RAGClientError.serverUnreachable }
    }

    /// HTTPステータスが200系か確認し、それ以外はサーバーのエラーメッセージを添えて投げる。
    private static func ensureOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw RAGClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                throw RAGClientError.serverError(detail)
            }
            throw RAGClientError.serverError("HTTP \(http.statusCode)")
        }
    }

    /// ISO8601文字列をパースする（小数秒あり/なし両対応）。
    static func parseISO8601(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

// MARK: - ローカルスキャン・チェックサム・テキスト抽出

/// 監視フォルダのスキャン、SHA-256計算、tab_id生成、テキスト抽出をまとめる。
/// ファイルI/Oを行うため main actor 外で実行できるよう nonisolated にする。
enum RAGScanner {

    /// pathのSHA-256をとって先頭32文字をUUID形式（8-4-4-4-12）に変換する。
    /// 同じパスからは常に同じtab_idが生成され、同期ロジックの一貫性が保たれる。
    nonisolated static func makeTabId(path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        let s = String(hex.prefix(32))
        let parts = [
            s.prefix(8),
            s.dropFirst(8).prefix(4),
            s.dropFirst(12).prefix(4),
            s.dropFirst(16).prefix(4),
            s.dropFirst(20).prefix(12)
        ]
        return parts.map(String.init).joined(separator: "-")
    }

    /// ファイル本体のSHA-256を "sha256:<hex>" 形式で返す。
    nonisolated static func checksum(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// md/txt はエンコーディング自動判定で読む。pdf は PDFKit で抽出する。
    nonisolated static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), let s = doc.string, !s.isEmpty else { return nil }
            return s
        }
        // UTF-8 / UTF-8 BOM / UTF-16 などは usedEncoding で自動判定。
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc), !s.isEmpty { return s }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // 日本語ファイルの保険として Shift_JIS / CP932 も試す。
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        for e in [String.Encoding.utf8, .shiftJIS, cp932, .japaneseEUC] {
            if let s = String(data: data, encoding: e), !s.isEmpty { return s }
        }
        return nil
    }

    /// 監視フォルダ群をスキャンしてローカルタブ一覧を返す。
    ///
    /// 対応ルール:
    /// - `名前.xlsx` + 同名フォルダ `名前/` 内の `名前_【*】.md` → xlsx系（各MDが1タブ）
    /// - `*.md` / `*.txt` / `*.pdf` 単体 → 単体ファイル（1タブ）
    /// - 同名フォルダの無い `*.xlsx` 単体・xlsxの無いフォルダ単体 → 無視
    nonisolated static func scan(folders: [WatchedFolder]) -> [RAGLocalTab] {
        var tabs: [RAGLocalTab] = []
        let fm = FileManager.default
        for folder in folders {
            guard let url = resolveURL(folder) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            guard let entries = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            // フォルダ名 → URL の辞書（xlsx の同名フォルダ照合用）。
            var dirByName: [String: URL] = [:]
            var files: [URL] = []
            for e in entries {
                let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { dirByName[e.lastPathComponent] = e } else { files.append(e) }
            }

            for file in files {
                let ext = file.pathExtension.lowercased()
                if ext == "xlsx" {
                    // 同名フォルダがあれば xlsx系として各MDをタブにする。無ければ無視。
                    let base = file.deletingPathExtension().lastPathComponent
                    guard let dir = dirByName[base] else { continue }
                    let mds = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? []
                    for md in mds where md.pathExtension.lowercased() == "md" {
                        guard let sum = checksum(of: md) else { continue }
                        tabs.append(RAGLocalTab(
                            tabId: makeTabId(path: md.path),
                            title: file.lastPathComponent,
                            tabName: tabName(mdFile: md, xlsxBase: base),
                            filePath: file.path,
                            mdPath: md.path,
                            checksum: sum
                        ))
                    }
                } else if ["md", "txt", "pdf"].contains(ext) {
                    guard let sum = checksum(of: file) else { continue }
                    tabs.append(RAGLocalTab(
                        tabId: makeTabId(path: file.path),
                        title: file.lastPathComponent,
                        tabName: nil,
                        filePath: file.path,
                        mdPath: file.path,
                        checksum: sum
                    ))
                }
            }
        }
        return tabs
    }

    /// `名前_【タブ名】.md` から `【タブ名】` を取り出す。前提に合わなければファイル名（拡張子なし）を返す。
    nonisolated private static func tabName(mdFile: URL, xlsxBase: String) -> String {
        let mdBase = mdFile.deletingPathExtension().lastPathComponent
        let prefix = xlsxBase + "_"
        return mdBase.hasPrefix(prefix) ? String(mdBase.dropFirst(prefix.count)) : mdBase
    }

    /// 監視フォルダ群のセキュリティスコープを開いた状態でクロージャを実行する。
    /// 同期時のテキスト抽出など、フォルダ配下のファイルを同期的に読むときに使う。
    nonisolated static func withFolderAccess<T>(_ folders: [WatchedFolder], _ body: () -> T) -> T {
        let urls = folders.compactMap { resolveURL($0) }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        return body()
    }

    /// WatchedFolder からアクセス可能なURLを復元する（bookmark優先、無ければパス）。
    nonisolated static func resolveURL(_ folder: WatchedFolder) -> URL? {
        if let data = folder.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: folder.path)
    }
}
