import SwiftUI
import WebKit
import AppKit

/// メッセージ本文を、同梱した KaTeX + marked.js で描画する WebView。
/// codecogs を使わないため日本語入りの数式や cases/align などの環境系も正しく表示でき、
/// オフラインでも動作する。本文の幅・高さは JS から受け取って SwiftUI 側の frame に反映し、
/// 吹き出しが内容にフィットするようにする。
struct MathMarkdownView: NSViewRepresentable {
    let content: String
    /// true で本文を白文字にする（ユーザー吹き出しの青背景／ダークモード用）。
    let dark: Bool
    /// 吹き出しの最大幅(px)。ウィンドウ幅に応じて SwiftUI 側で算出して渡す。
    let maxWidth: CGFloat
    @Binding var size: CGSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "size")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 吹き出しの背景を透過させるため、WebView 自身は背景を描かない。
        webView.setValue(false, forKey: "drawsBackground")
        // バンドルでフォルダ構造が保持される場合(WebAssets配下)とフラット化される場合の両対応。
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets")
            ?? Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.lastContent != content || c.lastDark != dark {
            c.lastContent = content
            c.lastDark = dark
            c.lastMaxWidth = maxWidth
            c.applyContent(to: webView)
        } else if abs(c.lastMaxWidth - maxWidth) > 0.5 {
            // 内容は同じでウィンドウ幅だけ変わった場合は、再パースせず最大幅だけ更新する。
            c.lastMaxWidth = maxWidth
            c.applyMaxWidth(to: webView)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathMarkdownView
        var lastContent: String
        var lastDark: Bool
        var lastMaxWidth: CGFloat
        private var loaded = false
        // 生成中はトークン毎に内容が変わるため、再描画を間引く（最終内容は必ず反映される）。
        private var pendingRender: DispatchWorkItem?
        private var lastRender = Date.distantPast
        private let minInterval: TimeInterval = 0.15

        init(_ parent: MathMarkdownView) {
            self.parent = parent
            self.lastContent = parent.content
            self.lastDark = parent.dark
            self.lastMaxWidth = parent.maxWidth
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(to: webView)
        }

        /// 内容変更を反映する。短時間に連続した場合はスロットルし、末尾の呼び出しは必ず実行する。
        func applyContent(to webView: WKWebView) {
            guard loaded else { return }
            pendingRender?.cancel()
            let elapsed = Date().timeIntervalSince(lastRender)
            if elapsed >= minInterval {
                render(to: webView)
            } else {
                let work = DispatchWorkItem { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.render(to: webView)
                }
                pendingRender = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
            }
        }

        private func render(to webView: WKWebView) {
            lastRender = Date()
            let b64 = Data(lastContent.utf8).base64EncodedString()
            webView.evaluateJavaScript("setContent(\"\(b64)\", \(lastDark), \(Int(lastMaxWidth)))", completionHandler: nil)
        }

        /// 内容を再描画せず、最大幅だけ更新する（ウィンドウリサイズ時用）。
        func applyMaxWidth(to webView: WKWebView) {
            guard loaded else { return }
            webView.evaluateJavaScript("setMaxWidth(\(Int(lastMaxWidth)))", completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "size",
                  let dict = message.body as? [String: Any],
                  let w = (dict["w"] as? NSNumber)?.doubleValue,
                  let h = (dict["h"] as? NSNumber)?.doubleValue
            else { return }
            let newSize = CGSize(width: CGFloat(w), height: CGFloat(h))
            DispatchQueue.main.async {
                if abs(self.parent.size.width - newSize.width) > 0.5
                    || abs(self.parent.size.height - newSize.height) > 0.5 {
                    self.parent.size = newSize
                }
            }
        }

        // リンクはアプリ内で遷移させず、外部ブラウザで開く。
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
