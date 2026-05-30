import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isHoveringGitHub = false
    @State private var showingLicenses = false

    // Xcode の General 設定から Version と Build を自動取得
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .padding(.top, 20)
            }

            VStack(spacing: 2) {
                Text("Aetherium")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                Text("Version \(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Text("Aetherium（エーテリウム）は、ローカルLLMとVOICEVOXを繋ぐ、あなただけのプライベート・アシスタントです。")
                .font(.system(size: 13))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 40)

            HStack(spacing: 4) {
                Text("© 2026 NIK Co., Ltd. Developed by JINDE")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/motokijinde/aetherium.git")!)
                    .font(.system(size: 12, weight: .bold))
                    .underline(isHoveringGitHub)
                    .onHover { hovering in isHoveringGitHub = hovering }
            }
            .padding(.top, 20)

            Button("Open Source Licenses") {
                showingLicenses = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.accentColor)
            .padding(.bottom, 20)

            Divider()

            Button("完了") {
                dismiss()
            }
            .padding(12)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 320)
        .sheet(isPresented: $showingLicenses) {
            LicensesView()
        }
    }
}

/// 同梱した THIRD_PARTY_LICENSES（拡張子なし）を表示するシート。
struct LicensesView: View {
    @Environment(\.dismiss) var dismiss

    private var licensesText: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: nil)
            ?? Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: nil, subdirectory: "WebAssets"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "ライセンス情報を読み込めませんでした。" }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open Source Licenses")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button("完了") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(licensesText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 560, height: 520)
    }
}
