import SwiftUI

@main
struct AetheriumApp: App {
    // メインウィンドウと設定ウィンドウ(⌘,)で同じ ViewModel を共有するため App 階層で保持する。
    @StateObject private var vm = ChatViewModel()
    @State private var isShowingAbout = false

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
        }

        // ネイティブの設定ウィンドウ（メニュー「Aetherium → 設定…」/ ⌘,）。
        Settings {
            SettingsView()
                .environmentObject(vm)
        }
    }
}
