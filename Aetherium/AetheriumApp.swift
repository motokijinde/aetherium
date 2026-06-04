import SwiftUI

@main
struct AetheriumApp: App {
    // 複数シーン（メイン／RAG／設定）を宣言しても、最後のウィンドウを閉じたらアプリを終了させる。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // メインウィンドウ・RAG管理・設定(⌘,)で同じ ViewModel を共有するため App 階層で保持する。
    @StateObject private var vm = ChatViewModel()
    @State private var isShowingAbout = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Window（単一ウィンドウ）にして「New Window」での複製を無くす。
        // vm をApp階層で共有しているため複数ウィンドウは同一セッションになり無意味なため。
        Window("Aetherium", id: "main") {
            AetheriumView()
                .environmentObject(vm)
                .sheet(isPresented: $isShowingAbout) {
                    AboutView()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    isShowingAbout = true
                } label: {
                    Label("About Aetherium", systemImage: "info.circle")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("RAG Documents…") {
                    openWindow(id: "rag-manager")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // RAG管理（ネイティブな閉じるボタンを持つ単一ウィンドウ。WindowGroup でないため複製されない）。
        // vm を共有して同期状態・ragClient を参照する。
        Window("RAG Documents", id: "rag-manager") {
            RAGManagerView()
                .environmentObject(vm)
        }
        .defaultSize(width: 620, height: 520)

        // ネイティブの設定ウィンドウ（メニュー「Aetherium → 設定…」/ ⌘,）。
        Settings {
            SettingsView()
                .environmentObject(vm)
        }
    }
}

/// 全ウィンドウを閉じたらアプリを終了する（複数シーン宣言時の「終了しない」挙動を明示的に打ち消す）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
