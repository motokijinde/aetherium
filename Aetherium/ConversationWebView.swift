import SwiftUI
import WebKit
import AppKit

/// テキスト上でカーソルが「矢印 ⇄ I 字」に点滅する macOS の WKWebView 既知の挙動を抑える。
/// 外側の WKWebView 側のカーソル更新を無効化し、WebKit 内部が決めたカーソル
/// （テキスト上は I 字、それ以外は矢印）をそのまま維持させる。
final class ChatWebView: WKWebView {
    override func cursorUpdate(with event: NSEvent) {
        // あえて super を呼ばず、矢印への上書きリセットを止める。
    }
}

/// 会話全体を1個の WKWebView で描画する。スクロールは WebView 内部に任せるため、
/// メッセージ毎に WebView を並べる方式の重さ・スクロール相性問題を回避できる。
/// 同梱した KaTeX + marked.js で数式・Markdown を描画し、オフラインで動作する。
struct ConversationWebView: NSViewRepresentable {
    let messages: [Message]
    let dark: Bool
    let isGenerating: Bool
    let speakerName: String
    let modelName: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 吹き出しのコピーボタン → JS から生テキストを受け取って NSPasteboard へ。
        // file:// では navigator.clipboard が使えないため Swift 側でコピーする。
        config.userContentController.add(context.coordinator, name: "copyToClipboard")
        let webView = ChatWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 背景を透過させて、SwiftUI 側の背景を見せる。
        webView.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets")
            ?? Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(self, webView: webView)
    }

    /// メッセージ配列を base64 化した JSON にする。
    static func encodeBase64<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return data.base64EncodedString()
    }

    /// 末尾メッセージの変化検知用シグネチャ（内容＋統計＋生成中フラグ）。
    private func lastSignature() -> String {
        guard let m = messages.last else { return "" }
        let s = m.stats.map { "\($0.completionTokens)/\($0.tokensPerSecond ?? 0)/\($0.ttft ?? 0)" } ?? ""
        return "\(m.content)\u{1}\(m.thinking ?? "")\u{1}\(s)\u{1}\(isGenerating)"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ConversationWebView
        private var loaded = false
        private var lastCount = -1
        private var lastDark: Bool?
        private var lastSpeaker = "\u{1}"
        private var lastModel = "\u{1}"
        private var lastLastSig = "\u{1}\u{1}"
        private var pending: DispatchWorkItem?
        private var lastRender = Date.distantPast
        private let minInterval: TimeInterval = 0.15

        init(_ parent: ConversationWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            fullReload(webView)
        }

        func update(_ newParent: ConversationWebView, webView: WKWebView) {
            parent = newParent
            guard loaded else { return }
            // 件数・テーマ・話者の変化は構造変化 → 全再描画。
            if parent.messages.count != lastCount || parent.dark != lastDark || parent.speakerName != lastSpeaker || parent.modelName != lastModel {
                fullReload(webView)
                return
            }
            // 末尾メッセージだけの変化（ストリーミング）→ 末尾だけ更新（スロットル）。
            let sig = parent.lastSignature()
            if sig != lastLastSig {
                lastLastSig = sig
                scheduleUpdateLast(webView)
            }
        }

        private func fullReload(_ webView: WKWebView) {
            lastCount = parent.messages.count
            lastDark = parent.dark
            lastSpeaker = parent.speakerName
            lastModel = parent.modelName
            lastLastSig = parent.lastSignature()
            pending?.cancel()
            guard let msgsB64 = ConversationWebView.encodeBase64(parent.messages) else { return }
            let speakerB64 = Data(parent.speakerName.utf8).base64EncodedString()
            let modelB64 = Data(parent.modelName.utf8).base64EncodedString()
            let js = "setMessages(\"\(msgsB64)\", \(parent.dark), \(parent.isGenerating), \"\(speakerB64)\", \"\(modelB64)\")"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func scheduleUpdateLast(_ webView: WKWebView) {
            pending?.cancel()
            let elapsed = Date().timeIntervalSince(lastRender)
            if elapsed >= minInterval {
                renderLast(webView)
            } else {
                let work = DispatchWorkItem { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.renderLast(webView)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
            }
        }

        private func renderLast(_ webView: WKWebView) {
            lastRender = Date()
            guard let last = parent.messages.last,
                  let b64 = ConversationWebView.encodeBase64(last) else { return }
            let idx = parent.messages.count - 1
            let js = "updateLast(\"\(b64)\", \(idx), \(parent.isGenerating))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // JS のコピーボタンから受け取った生テキストをクリップボードへ。
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "copyToClipboard", let text = message.body as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        // リンクはアプリ内で遷移させず外部ブラウザで開く。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
