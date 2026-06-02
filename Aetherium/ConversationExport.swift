import Foundation
import WebKit

/// 会話ログを Markdown 文字列に整形する。本文に加えて思考・統計・検索ソース・添付・時刻も含める。
/// 表示中の内容（active variant）をそのまま書き出す。
enum ConversationMarkdown {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    static func build(messages: [Message], speakerName: String, modelName: String, userName: String) -> String {
        var out = "# 会話ログ\n\n"
        out += "- 話者: \(speakerName)\n"
        out += "- モデル: \(modelName)\n"
        out += "- 出力日時: \(dateFormatter.string(from: Date()))\n\n---\n\n"

        for m in messages {
            switch m.role {
            case "user":
                out += "## 🧑 \(userName) — \(dateFormatter.string(from: m.date))\n\n"
                out += m.content + "\n\n"
                if let atts = m.attachments, !atts.isEmpty {
                    out += "添付: " + atts.map { "`\($0.filename)`" }.joined(separator: ", ") + "\n\n"
                }
            case "assistant":
                out += "## 🤖 \(speakerName) — \(dateFormatter.string(from: m.date))\n\n"
                if let t = m.thinking, !t.isEmpty {
                    out += "<details><summary>💭 思考</summary>\n\n\(t)\n\n</details>\n\n"
                }
                out += m.content + "\n\n"
                if let sources = m.searchSources, !sources.isEmpty {
                    out += "**🔍 検索ソース**\n\n"
                    for s in sources { out += "- [\(s.title)](\(s.url))\n" }
                    out += "\n"
                }
                if let st = m.stats {
                    var parts = ["\(st.totalTokens) tokens（prompt \(st.promptTokens) / completion \(st.completionTokens)）"]
                    if let tps = st.tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
                    if let ttft = st.ttft { parts.append(String(format: "TTFT %.2fs", ttft)) }
                    out += "> 📊 " + parts.joined(separator: " ・ ") + "\n\n"
                }
            default: // system（コンテキストリセット等の控えめ表記）
                out += "> ℹ️ \(m.content)\n\n"
            }
            out += "---\n\n"
        }
        return out
    }
}

/// 表示中の会話 WebView から PDF を書き出すためのブリッジ。
/// `ConversationWebView` が makeNSView 時に live な WKWebView を登録し、
/// ツールバーの保存ボタンからこのオブジェクト経由で PDF 化する。
final class ConversationExporter {
    weak var webView: WKWebView?

    /// 表示中の会話を PDF にして指定 URL へ書き出す。
    /// 出力前に body へ `exporting` クラスを付け、操作ボタンを隠し背景を不透明化する。
    /// 思考・検索ソースの折りたたみは画面の開閉状態のまま出力する（強制展開しない）。
    func exportPDF(to url: URL, completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.evaluateJavaScript("document.body.classList.add('exporting')") { _, _ in
            // クラス付与によるレイアウト反映を1フレーム待ってからキャプチャする。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                webView.createPDF(configuration: WKPDFConfiguration()) { result in
                    webView.evaluateJavaScript("document.body.classList.remove('exporting')", completionHandler: nil)
                    switch result {
                    case .success(let data):
                        completion((try? data.write(to: url)) != nil)
                    case .failure:
                        completion(false)
                    }
                }
            }
        }
    }
}
