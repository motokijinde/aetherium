import SwiftUI
import AppKit

/// RAGドキュメント管理（チャットから .sheet で開く）。
/// 監視フォルダのスキャン結果とサーバー登録情報をマージした一覧の「表示の窓」。
/// 状態と同期ロジックは ChatViewModel 側へ移設済みで、本ビューはそれを参照して表示・操作するだけ。
/// Sheet を閉じても同期 Task は ViewModel 側で生き続ける。
/// 接続ステータス・操作ボタンはチャット画面に合わせてツールバー（タイトルバー）へ集約する。
struct RAGManagerView: View {
    @EnvironmentObject var vm: ChatViewModel

    // 表示専用のローカル状態（同期の生死に関わらないため View に残す）。
    @State private var searchText = ""
    @State private var statusFilter: RAGDocumentStatus? = nil
    @State private var expandedIds: Set<String> = []   // 展開中の親 filePath

    private var lastSyncedAt: Date? { vm.ragLastSyncedAt }

    // MARK: - Body

    var body: some View {
        // チャットウィンドウと同じく、接続ステータス・同期ボタンをタイトルバー（.toolbar）に入れる。
        // 同期ボタンは .bordered（accentを拾う .borderedProminent は使わない）。閉じるはウィンドウの赤ボタン。
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    if let result = vm.ragSyncResult, !vm.ragIsSyncing {
                        resultToast(result)
                    }
                    if !vm.ragIsConnected && !vm.ragIsLoading {
                        notConnectedBanner
                    }
                    folderSection
                    Divider()
                    filterBar
                    if vm.ragIsSyncing { syncProgressView }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .disabled(!vm.ragIsConnected)
                .opacity(vm.ragIsConnected ? 1 : 0.4)

                fileList
                    .disabled(!vm.ragIsConnected)
                    .opacity(vm.ragIsConnected ? 1 : 0.4)
            }
            // チャットと同じく、ネイティブの title＋subtitle 2段表示にする（文字サイズ・左右マージンが自動で揃う）。
            .navigationTitle("Aetherium")
            .navigationSubtitle("RAG Documents")
            // チャットウィンドウと同じく、ツールバー背景を透明にして暗いウィンドウ背景を透けさせる。
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        connectionStatus
                        Divider().frame(height: 16).padding(.horizontal, 2)
                        syncButton
                    }
                    .padding(.leading, 14).padding(.trailing, 10)  // 左14・右10で統一
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        // 最小化・拡大（ズーム）ボタンを無効化する。
        .background(WindowConfigurator())
        // 仕様: スキャン＋マージはウィンドウを開いたときに実行する。
        .task { await vm.refreshRAG() }
    }

    /// 接続ステータス（丸＋テキスト＋件数＋最終同期）。操作ではないので日本語表示。
    private var connectionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.ragIsConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: (vm.ragIsConnected ? Color.green : Color.red).opacity(0.6), radius: 3)
            Text(vm.ragIsConnected ? "Qdrant 接続中" : "Qdrant 未接続")
                .font(.system(size: 11))
                .foregroundStyle(vm.ragIsConnected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
            if vm.ragIsConnected {
                Text("📄 \(vm.ragTotalDocuments)件")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                if !vm.ragIsSyncing, let d = lastSyncedAt {
                    Text("最終同期 \(syncTimeLabel(d))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
        // 件数や日時の桁が増えても truncate/改行せず、そのまま横に伸びるようにする。
        .fixedSize()
        .padding(.vertical, 4)  // チャットのステータス群と同じ縦余白（高さを揃える）
    }

    @ViewBuilder
    private var syncButton: some View {
        if !vm.ragIsConnected {
            Button(action: { Task { await vm.refreshRAG() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("再接続")
        } else if vm.ragIsSyncing {
            Button(action: { vm.cancelRAGSync() }) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("同期を中止")
        } else {
            Button(action: { vm.startRAGSync() }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(vm.ragDocuments.isEmpty)
            .help("今すぐ同期")
        }
    }

    // MARK: - 結果トースト

    private func resultToast(_ r: SyncResult) -> some View {
        HStack(spacing: 8) {
            Text("✅ 同期完了").font(.system(size: 11, weight: .semibold))
            chip("＋\(r.added) 追加", .green)
            chip("↑\(r.updated) 更新", .orange)
            chip("−\(r.deleted) 削除", .red)
            chip("\(r.skipped) スキップ", .secondary)
            if !r.errors.isEmpty { chip("⚠️\(r.errors.count) 失敗", .red) }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
                .overlay(Rectangle().fill(Color.green).frame(width: 2), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        )
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }

    // MARK: - 未接続バナー

    private var notConnectedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Qdrantに接続できません。Dockerコンテナが起動しているか確認してください。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 監視フォルダ

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watched Folders")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                // チャットの入力欄チップ（Web検索など）と同じ見た目・サイズのアイコンボタン。
                ChipButton(icon: "plus", isEnabled: vm.ragIsConnected,
                           help: "監視フォルダを追加") { vm.addWatchedFolder() }
            }
            if vm.ragWatchedFolders.isEmpty {
                Text("監視するフォルダを追加してください")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(vm.ragWatchedFolders) { folder in
                    FolderRow(folder: folder,
                              onOpen: { openInFinder(folder) },
                              onRemove: { vm.removeWatchedFolder(folder.id) })
                }
            }
        }
    }

    /// 監視フォルダを Finder で開く。サンドボックス下では security-scoped bookmark の
    /// アクセスを開いてから Finder に渡す必要がある（開かないと権限エラーになる）。
    private func openInFinder(_ folder: WatchedFolder) {
        guard let url = RAGScanner.resolveURL(folder) else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 絞り込みバー

    private var filterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("ファイル名で絞り込み...", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

            Menu {
                Button("すべて") { statusFilter = nil }
                Button("同期済み") { statusFilter = .synced }
                Button("更新あり") { statusFilter = .modified }
                Button("新規") { statusFilter = .new }
                Button("見つからない") { statusFilter = .missing }
                Button("エラー") { statusFilter = .error }
            } label: {
                Text(statusFilter.map(label(for:)) ?? "すべて")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - 同期中プログレス

    private var syncProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🔄 \(vm.ragSyncingLabel.isEmpty ? "準備中" : vm.ragSyncingLabel) を処理中...")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let p = vm.ragSyncProgress {
                    Text("\(p.current) / \(p.total)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: Double(vm.ragSyncProgress?.current ?? 0),
                         total: Double(max(vm.ragSyncProgress?.total ?? 1, 1)))
                .progressViewStyle(.linear)
        }
    }

    // MARK: - ファイル一覧

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredDocuments) { doc in
                    if doc.isWorkbook {
                        workbookRow(doc)
                        if expandedIds.contains(doc.filePath) {
                            ForEach(doc.tabs) { tab in
                                tabRow(tab)
                            }
                        }
                    } else {
                        standaloneRow(doc)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    /// xlsx系の親行（▶/▼で子タブを展開）。
    private func workbookRow(_ doc: RAGDocument) -> some View {
        let (text, color) = docBadge(doc)
        return Button(action: { toggleExpand(doc.filePath) }) {
            HStack(spacing: 8) {
                Image(systemName: expandedIds.contains(doc.filePath) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                Text("📊").font(.system(size: 13))
                Text(doc.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(folderLabel(doc.filePath))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Text("\(doc.tabs.count)タブ").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                badge(text, color)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// xlsx系の子タブ行。
    private func tabRow(_ tab: RAGDocumentTab) -> some View {
        let (text, color) = tabBadge(tab)
        return HStack(spacing: 8) {
            Spacer().frame(width: 18)
            Text("📄").font(.system(size: 12))
            Text(tab.tabName ?? tab.mdPath)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            badge(text, color)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    /// 単体ファイル行（フラット表示）。
    private func standaloneRow(_ doc: RAGDocument) -> some View {
        let (text, color) = docBadge(doc)
        return HStack(spacing: 8) {
            Spacer().frame(width: 10)
            Text(standaloneIcon(doc.filePath)).font(.system(size: 13))
            Text(doc.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Text(folderLabel(doc.filePath))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            badge(text, color)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }

    // MARK: - 表示ヘルパー

    private var filteredDocuments: [RAGDocument] {
        vm.ragDocuments.filter { doc in
            (statusFilter == nil || doc.status == statusFilter) &&
            (searchText.isEmpty || doc.title.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func toggleExpand(_ id: String) {
        if expandedIds.contains(id) { expandedIds.remove(id) } else { expandedIds.insert(id) }
    }

    /// file_path の親フォルダ名（例「仕様書/」）。
    private func folderLabel(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "" : "\(parent)/"
    }

    private func standaloneIcon(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" ? "📋" : "📄"
    }

    private func label(for status: RAGDocumentStatus) -> String {
        switch status {
        case .synced:   return "同期済み"
        case .modified: return "更新あり"
        case .new:      return "新規"
        case .missing:  return "見つからない"
        case .error:    return "エラー"
        case .pending:  return "処理中"
        }
    }

    private func color(for status: RAGDocumentStatus) -> Color {
        switch status {
        case .synced:           return .green
        case .modified:         return .orange
        case .new:              return .purple
        case .missing, .error:  return .red
        case .pending:          return .secondary
        }
    }

    /// 子タブのバッジ表示（同期中は処理中/待機中を優先）。
    private func tabBadge(_ tab: RAGDocumentTab) -> (String, Color) {
        if vm.ragIsSyncing {
            if tab.id == vm.ragSyncingTabId { return ("処理中...", .secondary) }
            if tab.status == .pending { return ("待機中", .secondary) }
        }
        return (label(for: tab.status), color(for: tab.status))
    }

    /// 親/単体のバッジ表示。
    private func docBadge(_ doc: RAGDocument) -> (String, Color) {
        if vm.ragIsSyncing {
            if doc.tabs.contains(where: { $0.id == vm.ragSyncingTabId }) { return ("処理中...", .secondary) }
            if doc.status == .pending { return ("待機中", .secondary) }
        }
        return (label(for: doc.status), color(for: doc.status))
    }

    private func syncTimeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
}

/// 監視フォルダ1行。フォルダ名部分がボタンで、クリックで Finder を開く（ホバーで背景が変わる）。
/// 右端の × は監視対象から外すだけ（登録済みドキュメントは削除しない）。
private struct FolderRow: View {
    let folder: WatchedFolder
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text("📁").font(.system(size: 12))
                    Text(folder.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("クリックで Finder で開く")
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("監視フォルダから外す（登録済みドキュメントは削除されません）")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(hovering ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}

/// ウィンドウの最小化・拡大（ズーム）ボタンを無効化する補助ビュー。
/// SwiftUI の Window には直接の指定が無いため、下地の NSView から NSWindow を辿って設定する。
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            w.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
