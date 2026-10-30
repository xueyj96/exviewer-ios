import SwiftUI
import ExViewerCore

enum LibrarySelectionPolicy {
    static func filtered(_ galleries: [Gallery], blocked: Set<String>) -> (visible: [Gallery], unknown: Int) {
        var visible: [Gallery] = []; var unknown = 0
        for gallery in galleries {
            switch TagFilter.decision(tags: gallery.tags, blocked: blocked, complete: gallery.tagsComplete) {
            case .visible: visible.append(gallery)
            case .unknown: unknown += 1
            case .blocked: break
            }
        }
        return (visible, unknown)
    }

    static func toggled(_ id: String, in current: Set<String>) -> Set<String> {
        var next = current
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    static func selectAllOrClear(_ ids: [String], current: Set<String>) -> Set<String> {
        let target = Set(ids)
        return target.isSubset(of: current) ? current.subtracting(target) : current.union(target)
    }

    static func allSelected(_ ids: [String], current: Set<String>) -> Bool {
        Set(ids).isSubset(of: current)
    }
}

struct TagsView: View {
    var use: (GalleryTag) -> Void
    @EnvironmentObject private var library: LibraryStore
    @State private var scope = 0
    @State private var query = ""
    @State private var adding = false
    @State private var undone: GalleryTag?
    private var tags: [GalleryTag] { (scope == 0 ? library.snapshot.favoriteTags : library.snapshot.blockedTags).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section { Picker("标签范围", selection: $scope) { Text("常用标签").tag(0); Text("屏蔽标签").tag(1) }.pickerStyle(.segmented) }.listRowBackground(Color.clear)
            if let undone { Section { HStack { Text("已屏蔽 \(undone.name)").font(.caption); Spacer(); Button("撤销") { library.unblock(undone); self.undone = nil } } } }
            Section {
                ForEach(tags) { tag in
                    HStack { VStack(alignment: .leading, spacing: 4) { Text(tag.name); Text(tag.namespace).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: scope == 0 ? "arrow.up.left" : "eye.slash").foregroundStyle(.secondary) }
                        .contentShape(Rectangle()).onTapGesture { if scope == 0 { use(tag) } }
                        .contextMenu {
                            Button("用于组合搜索") { use(tag) }
                            if scope == 0 { Button("屏蔽标签") { library.block(tag); undone = tag }; Button("取消常用") { library.unpin(tag) } }
                            else { Button("解除屏蔽") { library.unblock(tag) }; Button("加入常用") { library.pin(tag) } }
                        }
                        .swipeActions { if scope == 0 { Button("取消常用", role: .destructive) { library.unpin(tag) } } else { Button("解除屏蔽") { library.unblock(tag) }.tint(Palette.accent) } }
                }
                if tags.isEmpty { Text(scope == 0 ? "在画廊详情长按标签，可加入常用。" : "屏蔽按命名空间和标签原名精确匹配。") .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 18) }
            }
            Section { Text("屏蔽应用于本机列表、详情和离线阅读。站点收藏和文件会保留。标签不完整的结果暂时隐藏，可重试补查。") .font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("标签").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
            .searchable(text: $query, prompt: "搜索标签原名")
            .toolbar { AppToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityIdentifier("tags.add") } }
            .sheet(isPresented: $adding) { TagEntryView { tag, _ in if scope == 0 { library.pin(tag) } else { library.block(tag); undone = tag } } }
    }
}

struct LibraryView: View {
    @Binding var site: GallerySite
    var isActive = true
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var scope = 0
    @State private var deleteRecord: DownloadRecord?
    @State private var sortOrders: [LibrarySortSection: LibrarySortOrder] = [:]
    @StateObject private var readLaterSelection = LibrarySelectionStore()
    @State private var selectingReadLater = false
    @State private var removingReadLater = false
    private var readLaterVisible: [Gallery] {
        LibrarySelectionPolicy.filtered(library.snapshot.readLater, blocked: library.blockedIDs).visible
    }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }

    var body: some View {
        VStack(spacing: 0) {
            if scope == 1 { CloudFavoritesView(site: $site, scope: $scope, isActive: isActive) }
            else if scope == 2 {
                FloatingFeedLayout { inset in ReadingHistoryView(embedded: true, topInset: inset) }
                    header: { FloatingHeaderPanel { scopePicker } }
            }
            else { localLibrary }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sortOrders = sortPreferences.load() }
        .onChange(of: library.owner) { _, _ in sortOrders = sortPreferences.load() }
        .onChange(of: scope) { _, _ in endReadLaterSelection() }
        .onChange(of: library.owner) { _, _ in endReadLaterSelection() }
        .onChange(of: isActive) { _, active in if !active { endReadLaterSelection() } }
        .onChange(of: readLaterVisible.map(\.id)) { _, ids in readLaterSelection.updateLoadedIDs(Set(ids)) }
        .transformPreference(MainTabsHiddenPreference.self) { hidden in
            hidden = hidden || (selectingReadLater && scope == 0 && isActive)
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if selectingReadLater && scope == 0 {
                ReadLaterSelectionActions(summary: readLaterSelection.summary, store: readLaterSelection) { removingReadLater = true }
            }
        }
        .confirmationDialog("从稍后再读移除所选作品？", isPresented: $removingReadLater, titleVisibility: .visible) {
            Button("移出所选作品", role: .destructive) {
                if library.removeReadLater(readLaterSelection.selectedIDs) { endReadLaterSelection() }
            }
        } message: { Text("站点收藏、下载文件和阅读进度会保留。") }
        .confirmationDialog("移除这份本机离线副本？", isPresented: Binding(get: { deleteRecord != nil }, set: { if !$0 { deleteRecord = nil } }), titleVisibility: .visible) {
            Button("移除本机副本", role: .destructive) { if let deleteRecord { library.removeDownload(deleteRecord) }; deleteRecord = nil }
        }
    }

    private var localLibrary: some View {
        FloatingFeedLayout { headerHeight in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let error = library.error { StatusMessage(title: error) { library.load(owner: library.owner) } }
                    if scope == 3 { downloadsSection }
                    else { bookmarksSection }
                }
                .padding(.top, headerHeight + 8).padding(.bottom, 30)
            }
            .contentMargins(.top, headerHeight, for: .scrollIndicators)
            .accessibilityIdentifier("library.local")
        } header: {
            FloatingHeaderPanel {
                VStack(spacing: 6) {
                    scopePicker
                    if selectingReadLater {
                        HStack {
                            FavoritesSelectionCount(summary: readLaterSelection.summary)
                            Spacer()
                            Button("退出", action: endReadLaterSelection).frame(minHeight: 44)
                                .accessibilityIdentifier("read-later.exit")
                        }
                    }
                }
            }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.header.floating")
        }
    }

    private var scopePicker: some View {
        LibraryScopePicker(selection: $scope)
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("手动下载", count: library.snapshot.downloads.count, symbol: "arrow.down.circle", sorting: .downloads)
            Text("按设备可用空间保存，切到后台会暂停；下载内容不参与浏览缓存清理。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 6)
            if library.snapshot.downloads.isEmpty {
                StatusMessage(title: "在画廊详情下载当前画质，即可离线阅读。", symbol: "arrow.down.circle")
            } else {
                ForEach(LibrarySorting.downloads(library.snapshot.downloads, order: sortOrders[.downloads] ?? .original, history: library.snapshot.history)) { record in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(record.gallery.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack { Text("\(record.completed.count) / \(record.total.map(String.init) ?? "未知") 页"); Spacer(); Text(status(record.status)) }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: record.total.map { Double(record.completed.count) / Double(max($0, 1)) })
                        if let error = record.error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            NavigationLink("离线阅读") { ReaderView(gallery: record.gallery, offline: true) }.disabled(record.completed.isEmpty)
                            Spacer()
                            if downloads.running == record.id { Button("暂停") { downloads.pauseAll() } }
                            else if record.status != .complete { Button("继续") { downloads.enqueue(record.gallery) } }
                            Button("移除副本", role: .destructive) { deleteRecord = record }.disabled(downloads.running != nil)
                        }.font(.subheadline)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("library.download.item.\(record.gallery.ref.gid)")
                    .contextMenu {
                        NavigationLink { ReaderView(gallery: record.gallery, offline: true) } label: {
                            Label("离线阅读", systemImage: "book")
                        }.disabled(record.completed.isEmpty)
                        if downloads.running == record.id {
                            Button { downloads.pauseAll() } label: { Label("暂停下载", systemImage: "pause") }
                        } else if record.status != .complete {
                            Button { downloads.enqueue(record.gallery) } label: { Label("继续下载", systemImage: "arrow.down") }
                        }
                        Button(role: .destructive) { deleteRecord = record } label: {
                            Label("移除副本", systemImage: "trash")
                        }.disabled(downloads.running != nil)
                    }
                    Divider().padding(.leading, 20)
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("library.downloads")
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("稍后再读", count: library.snapshot.readLater.count, symbol: "text.badge.plus", sorting: .bookmarks)
            if library.snapshot.readLater.isEmpty {
                Text("长按发现页的作品，或在详情的更多操作中加入稍后再读。").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 14)
                    .accessibilityIdentifier("read-later.empty")
            }
            else {
                GalleryRows(galleries: LibrarySorting.galleries(library.snapshot.readLater, order: sortOrders[.bookmarks] ?? .original, history: library.snapshot.history), layout: .grid,
                            freezeGridLayout: selectingReadLater, sourceIdentity: library.owner + ":read-later",
                            selectionStore: selectingReadLater ? readLaterSelection : nil,
                            onLongPressSelect: selectingReadLater ? nil : { gallery in
                                readLaterSelection.updateLoadedIDs(Set(readLaterVisible.map(\.id)))
                                selectingReadLater = readLaterSelection.beginSelecting(gallery.id)
                            },
                            onBookmarkToggle: { library.toggleReadLater($0) })
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("library.bookmarks")
    }

    private func endReadLaterSelection() { selectingReadLater = false; readLaterSelection.clear() }

    private func sectionHeader(_ title: String, count: Int, symbol: String, sorting section: LibrarySortSection? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Palette.accent)
            Text(title).font(.headline)
            Spacer()
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            if let section {
                Menu {
                    ForEach(section.options) { option in
                        Button {
                            sortPreferences.set(option, for: section)
                            sortOrders[section] = option
                        } label: {
                            if option == (sortOrders[section] ?? section.defaultOrder) { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }.accessibilityIdentifier("library.sort.\(section.rawValue).\(option.rawValue)")
                    }
                    if section != .history { Text("最近阅读：无记录的作品置后，保留原序。") }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.subheadline).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("\(section.title)排序")
                .accessibilityValue((sortOrders[section] ?? section.defaultOrder).title)
                .accessibilityIdentifier("library.sort.\(section.rawValue)")
            }
        }.padding(.horizontal, 20).padding(.vertical, 7)
    }

    private func status(_ value: DownloadRecord.Status) -> String {
        switch value { case .waiting: return "等待中"; case .downloading: return "下载中"; case .paused: return "已暂停"; case .complete: return "已下载"; case .failed: return "失败" }
    }
}

struct CloudFavoritesView: View {
    @Binding var site: GallerySite
    @Binding var scope: Int
    var isActive = true
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var pager = GalleryPager()
    @StateObject private var selectionStore = LibrarySelectionStore()
    @State private var web: WebDestination?
    @State private var category = "all"
    @State private var selecting = false
    @State private var initialLayoutReady = false
    @State private var pending: FavoriteAction?
    @State private var working = false
    @State private var workingCount = 0
    @State private var submitted = 0
    @State private var message: String?
    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationID = UUID()
    @State private var qaFavoriteAttemptCount = 0
    private struct RequestedSource: Equatable {
        let url: URL
        let generation: UUID
        let owner: String
        let favoritesRevision: UUID
    }
    @State private var requestedSource: RequestedSource?
    private var displayedItems: [Gallery] {
        AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection")
            ? LibrarySelectionQA.galleries : pager.items
    }
    @State private var preparedVisible: [Gallery]?
    private var visible: [Gallery] { preparedVisible ?? filteredItems() }
    var body: some View {
        FloatingFeedLayout { headerHeight in
        VStack(spacing: 0) {
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection") {
                Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier("library.qa.workload")
                    .accessibilityValue("galleries=\(displayedItems.count);blocked=\(library.snapshot.blockedTags.count)")
                    .allowsHitTesting(false)
            }
            if !session.hasCredentials && !AppMode.qa {
                ContentUnavailableView {
                    Label("登录后读取站点收藏", systemImage: "heart")
                } description: {
                    Text("使用自己的站点账号访问收藏。")
                } actions: {
                    Button("打开官方登录页") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                }
            } else {
                GeometryReader { viewport in
                 ScrollView {
                    LazyVStack(spacing: 0) {
                        GalleryRows(galleries: displayedItems, layout: .grid, freezeGridLayout: selecting,
                                    sourceIdentity: "\(site.rawValue):\(category)",
                                    selectionStore: selecting ? selectionStore : nil,
                                    onLongPressSelect: selecting ? nil : beginSelection(at:),
                                    onNearEnd: { if isActive && initialLayoutReady && !selecting && pager.failure == nil { pager.more(session: session, prefetch: true) } },
                                    viewport: .init(space: "favorites-feed", height: viewport.size.height, topOcclusion: headerHeight))
                        if !selecting { GalleryContinuationFooter(pager: pager) }
                        if !pager.loading && pager.failure == nil && displayedItems.isEmpty { StatusMessage(title: "当前分组没有收藏结果。", symbol: "heart") }
                    }
                    .padding(.top, headerHeight)
                 }.coordinateSpace(name: "favorites-feed").refreshable {
                    if !working {
                        selectionStore.clear()
                        selecting = false
                        reload()
                    }
                 }.contentMargins(.top, headerHeight, for: .scrollIndicators)
                 .task(id: isActive ? headerHeight : -1) {
                     initialLayoutReady = false
                     guard isActive, headerHeight > 0 else { return }
                     await Task.yield()
                     try? await Task.sleep(nanoseconds: 120_000_000)
                     guard !Task.isCancelled, isActive else { return }
                     initialLayoutReady = true
                 }
                }
            }
          }
        } header: {
            favoritesFloatingHeader
        }
        .preference(key: MainTabsHiddenPreference.self, value: selecting && isActive)
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if selecting {
                VStack(spacing: 10) {
                    if working { ProgressView("正在处理 \(workingCount) 项…") }
                    FavoritesSelectionActions(store: selectionStore,
                                              onMove: { pending = .move($0) },
                                              onRemove: { pending = .remove },
                                              categoryName: categoryName)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                .padding(.horizontal, 12)
                .disabled(working)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("favorites.actions")
            }
        }
        .alert("管理所选收藏", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let action = pending {
                Button(action == .remove ? "移除所选收藏" : "确认移动", role: action == .remove ? .destructive : nil) { pending = nil; perform(action) }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text(confirmationTitle) }
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .task { prepareVisible(); reload(force: false) }
        .onChange(of: pager.items) { _, _ in prepareVisible() }
        .onChange(of: library.blockedIDs) { _, _ in selectionStore.clear(); selecting = false; prepareVisible() }
        .onChange(of: category) { _, _ in selectionStore.clear(); selecting = false; reload() }
        .onChange(of: site) { _, _ in cancel(); selectionStore.clear(); selecting = false; category = "all"; reload() }
        .onChange(of: session.hasCredentials) { _, _ in reload() }
        .onChange(of: session.favoritesRevision) { _, _ in reload() }
        .onChange(of: session.generation) { _, _ in cancel(); selectionStore.clear(); selecting = false; message = nil }
        .onChange(of: session.owner) { _, _ in cancel(); selectionStore.clear(); selecting = false; message = nil }
        .onChange(of: isActive) { _, active in
            if active { reload(force: false) }
            else { initialLayoutReady = false; cancel(); pager.cancel(); selectionStore.clear(); selecting = false }
        }
        .onDisappear { initialLayoutReady = false; cancel(); pager.cancel(); selectionStore.clear(); selecting = false }
    }

    private var favoritesFloatingHeader: some View {
        FloatingHeaderPanel {
            VStack(spacing: 6) {
                LibraryScopePicker(selection: $scope).disabled(working)
                if session.hasCredentials || AppMode.qa {
                HStack {
                    if !selecting {
                    Menu {
                        Button("全部分组") { category = "all" }
                        ForEach(0...9, id: \.self) { index in Button(categoryName(index)) { category = String(index) } }
                    } label: { Label(category == "all" ? "全部分组" : categoryName(Int(category) ?? 0), systemImage: "folder").frame(minHeight: 44) }
                        .disabled(working)
                    }
                    Spacer()
                    if selecting {
                        FavoritesSelectionCount(summary: selectionStore.summary)
                        Button("退出") {
                            selecting = false
                            selectionStore.clear()
                            if pager.interrupted { pager.retry(session: session) }
                        }
                        .accessibilityLabel("退出多选")
                        .disabled(working)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("favorites.edit")
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.subheadline)
                }
                if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "favorites") }
                if let error = library.error {
                    StatusMessage(title: error) { library.load(owner: library.owner) }
                }
                if let message {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if message.contains("核实") {
                            Button("刷新核实") { self.message = nil; reload() }
                                .font(.caption.weight(.semibold)).frame(minHeight: 44)
                                .accessibilityIdentifier("favorites.verify-refresh")
                        }
                        Button { self.message = nil } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("关闭操作提示")
                    }
                }
                if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response") {
                    Text("QA 模拟提交次数：\(qaFavoriteAttemptCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("favorites.qa-attempt-count")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("favorites.header.floating")
    }
    private var confirmationTitle: String {
        if case let .move(index)? = pending { return "将 \(selectionStore.selectedIDs.count) 项收藏移至「\(categoryName(index))」？" }
        return "从站点收藏移除 \(selectionStore.selectedIDs.count) 项？本机下载和稍后再读会保留。"
    }
    private func filteredItems() -> [Gallery] {
        LibrarySelectionPolicy.filtered(displayedItems, blocked: library.blockedIDs).visible
    }
    private func prepareVisible() {
        let items = filteredItems()
        preparedVisible = items
        selectionStore.updateLoadedIDs(Set(items.map(\.id)))
    }
    private func categoryName(_ index: Int) -> String { pager.categories[String(index)] ?? "分组 \(index + 1)" }
    private func beginSelection(at gallery: Gallery) {
        guard !working, !selecting else { return }
        SelectionPerformanceProbe.markAction(id: gallery.id)
        guard selectionStore.beginSelecting(gallery.id) else { return }
        pager.pauseForSelection()
        SelectionPerformanceProbe.markStateSet(id: gallery.id, count: selectionStore.selectedIDs.count)
        selecting = true
    }
    private func cancel() { mutationID = UUID(); mutationTask?.cancel(); mutationTask = nil; working = false; workingCount = 0 }
    private func perform(_ action: FavoriteAction) {
        let references = visible.filter { selectionStore.selectedIDs.contains($0.id) }.map(\.ref)
        guard !references.isEmpty, !working else { return }
        let simulateUnknown = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response")
        if AppMode.qa && !simulateUnknown { selectionStore.clear(); selecting = false; message = "测试模式仅检查多选交互，未修改站点收藏。"; return }
        let generation = session.generation, owner = session.owner, sourceSite = site
        let operation = UUID(); mutationID = operation
        message = nil; working = true; submitted = 0
        workingCount = references.count
        mutationTask = Task {
            defer {
                if operation == mutationID {
                    working = false
                    workingCount = 0
                    mutationTask = nil
                }
            }
            guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
            // Any submitted batch can change server state, including an
            // interrupted request or an unreadable response. Invalidate once
            // before the first send so no pre-mutation snapshot survives.
            await pager.invalidateFavoriteCache(owner: owner)
            for offset in stride(from: 0, to: references.count, by: 25) {
                let batch = Array(references[offset..<min(offset + 25, references.count)])
                do {
                    try Task.checkCancellation()
                    guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
                    if simulateUnknown {
                        try await Task.sleep(nanoseconds: 150_000_000)
                        guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
                        qaFavoriteAttemptCount += 1
                        throw FavoriteMutationFailure(requestMayHaveBeenSent: true,
                                                      underlying: NSError(domain: "ExViewer.QA", code: 1,
                                                                          userInfo: [NSLocalizedDescriptionKey: "QA 模拟：服务器响应丢失，结果未知。"]))
                    } else {
                        try await session.changeFavorites(batch, site: sourceSite, action: action)
                    }
                    guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
                    submitted += batch.count
                    selectionStore.remove(batch.map(\.id))
                } catch is CancellationError { return }
                catch let failure as FavoriteMutationFailure {
                    guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
                    let batchResult = failure.requestMayHaveBeenSent
                        ? "本批 \(batch.count) 项可能已生效，结果待核实；后续批次已停止。"
                        : "本批 \(batch.count) 项未发出；后续批次已停止。"
                    let prefix = submitted > 0 ? "此前已确认提交 \(submitted) 项。" : ""
                    message = prefix + batchResult + "\n" + ErrorMessages.message(failure.underlying)
                    return
                }
                catch {
                    guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
                    let prefix = submitted > 0 ? "此前已确认提交 \(submitted) 项。" : ""
                    message = prefix + "本批 \(batch.count) 项未能确认提交；后续批次已停止。请刷新收藏核实后再操作。\n" + ErrorMessages.message(error)
                    return
                }
            }
            guard operation == mutationID, generation == session.generation, owner == session.owner, sourceSite == site else { return }
            selecting = false; selectionStore.clear(); message = "已提交 \(submitted) 项收藏操作，服务器返回内容可读取，正在刷新列表核实。"
            reload()
        }
    }
    private func reload(force: Bool = true) {
        guard isActive else { return }
        guard AppMode.qa || session.hasCredentials, let base = try? SearchQuery().url(site: site, favorites: true), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.queryItems?.removeAll { $0.name == "favcat" }; components.queryItems?.append(.init(name: "favcat", value: category))
        if let url = components.url {
            let source = RequestedSource(url: url, generation: session.generation, owner: session.owner, favoritesRevision: session.favoritesRevision)
            if !force, requestedSource == source {
                if pager.interrupted { pager.retry(session: session) }
                return
            }
            requestedSource = source
            pager.reset(url: url, session: session, qa: AppMode.qa)
        }
    }
}

struct AccountView: View {
    @Binding var site: GallerySite
    var onUseTag: (GalleryTag) -> Void
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var web: WebDestination?
    @State private var showManagement = false
    @State private var loggingOut = false
    @State private var message: String?

    var body: some View {
        List {
            Section("浏览偏好") {
                Picker("默认浏览站点", selection: $site) {
                    Text("EH").tag(GallerySite.eh)
                    Text("EX").tag(GallerySite.ex)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("account.browser-site")
            }
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 38)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.hasCredentials ? "站点账号" : "未登录").font(.headline)
                        Text(session.hasCredentials ? "会话凭据保存在本机" : "登录以读取站点收藏和额度").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !session.hasCredentials { Button("登录") { web = .login }.buttonStyle(AppActionButtonStyle()) }
                }.padding(.vertical, 5)
                LabeledContent("E-Hentai", value: session.ehStatus)
                LabeledContent("ExHentai", value: session.exStatus)
                NavigationLink {
                    AccountLoginManagement(onOpenWeb: { web = $0 }) { loggingOut = true }
                        .toolbar(.visible, for: .navigationBar)
                } label: { Label("登录管理", systemImage: "person.badge.key") }
                    .accessibilityIdentifier("account.login-management")
            }
            Section("偏好") {
                NavigationLink {
                    TagsView(use: onUseTag).toolbar(.visible, for: .navigationBar)
                } label: { Label("标签与屏蔽", systemImage: "tag") }.accessibilityIdentifier("account.tags")
            }
            Section("本机数据") {
                LabeledContent("浏览缓存", value: "上限 2 GB")
                LabeledContent("手动下载", value: "按设备可用空间保存")
                NavigationLink {
                    LocalDataManagementView(message: $message).toolbar(.visible, for: .navigationBar)
                } label: { Label("阅读与存储管理", systemImage: "internaldrive") }
                    .accessibilityIdentifier("account.storage")
            }
            Section("看图额度") {
                if let used = session.quota.used, let limit = session.quota.limit {
                    VStack(alignment: .leading, spacing: 8) { HStack { Text("已用 \(used)"); Spacer(); Text("上限 \(limit)") }; ProgressView(value: Double(used), total: Double(max(used, limit))); Text("剩余 \(session.quota.remaining ?? 0) 额度单位，原图等操作消耗可能更高。") .font(.caption).foregroundStyle(.secondary) }
                } else if session.quota.tracking == .ip {
                    Text("按 IP 动态计算额度").foregroundStyle(.secondary)
                } else if session.quota.tracking == .restrictedIP {
                    Text("当前 IP 暂限低分辨率图片").foregroundStyle(.secondary)
                } else { Text("尚未取得当前额度").foregroundStyle(.secondary) }
                Button("读取站点额度") { Task { await session.refreshQuota() } }.disabled(AppMode.qa)
                NavigationLink { QuotaDetailsView().toolbar(.visible, for: .navigationBar) } label: { Label("额度详情", systemImage: "chart.bar") }.accessibilityIdentifier("account.quota")
            }
            Section("站点赞助与权益") {
                NavigationLink { SponsorshipView().toolbar(.visible, for: .navigationBar) } label: { Label("赞助与权益", systemImage: "heart") }.accessibilityIdentifier("account.sponsorship")
            }
            Section {
                Text("ExViewer · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .confirmationDialog("退出本机登录？离线资料会保留在原账号下。", isPresented: $loggingOut, titleVisibility: .visible) {
            Button("退出", role: .destructive) { downloads.pauseAll(); Task { do { try await session.logout(); library.load(owner: session.owner) } catch { message = "退出未完成，请重试。" } } }
        }
        .alert("本机状态", isPresented: Binding(get: { message != nil || session.error != nil }, set: { if !$0 { message = nil; session.error = nil } })) {
            Button("好") { message = nil; session.error = nil }
        } message: { Text(message ?? session.error ?? "") }
    }
}

private struct AccountLoginManagement: View {
    var onOpenWeb: (WebDestination) -> Void
    var onLogout: () -> Void
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            Section("站点会话") {
                LabeledContent("E-Hentai", value: session.ehStatus)
                LabeledContent("ExHentai", value: session.exStatus)
                Button("重新登录") { onOpenWeb(.login) }
                if session.exStatus == ViewerError.challenge.localizedDescription {
                    Button("处理 EX 网页验证") { onOpenWeb(.init(title: "EX 网页验证", url: GallerySite.ex.baseURL, login: true)) }.accessibilityIdentifier("account.ex-web")
                }
                if session.hasCredentials { Button("退出本机登录", role: .destructive, action: onLogout) }
            }
            Section {
                Text("会话保存在本机 Keychain，网页使用独立的临时会话。资料库按账号隔离。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = session.error { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.navigationTitle("登录管理").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
    }
}

private struct LocalDataManagementView: View {
    @Binding var message: String?
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @AppStorage("reader.prefetchCount", store: ReaderPreferenceDefaults.store) private var prefetchCount = ReaderLoadPolicy.defaultPrefetchCount
    @AppStorage("reader.downloadConcurrency", store: ReaderPreferenceDefaults.store) private var downloadConcurrency = ReaderLoadPolicy.defaultConcurrency
    @AppStorage("network.pageConcurrency", store: ReaderPreferenceDefaults.store) private var pageConcurrency = SiteRequestPolicy.defaultConcurrency
    @State private var editingPrefetch = false
    @State private var prefetchEntry = ""

    var body: some View {
        Form {
            Section("加载设置") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("后续图片预加载") {
                        Button {
                            prefetchEntry = String(prefetchCount)
                            editingPrefetch = true
                        } label: {
                            Text(prefetchCount == 0 ? "关闭" : "\(prefetchCount) 张")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("account.loading.prefetch-edit")
                        .accessibilityLabel("精确设置预加载数量")
                        .accessibilityValue("\(prefetchCount) 张")
                    }
                    Slider(value: Binding(
                        get: { Double(prefetchCount) },
                        set: { prefetchCount = Int($0.rounded()) }
                    ), in: 0...Double(ReaderLoadPolicy.maxPrefetchCount), step: 1) {
                        Text("后续图片预加载")
                    } minimumValueLabel: {
                        Text("0").font(.caption)
                    } maximumValueLabel: {
                        Text("128").font(.caption)
                    }
                    .accessibilityIdentifier("account.loading.prefetch")
                    .accessibilityLabel("后续图片预加载，\(prefetchCount) 张")
                    Text("按阅读顺序提前加载后续图片；0 表示关闭。点按数量可精确输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("图片加载并发")
                    Picker("图片加载并发", selection: $downloadConcurrency) {
                        ForEach(ReaderLoadPolicy.concurrencyChoices, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("account.loading.concurrency")
                    .accessibilityValue(String(downloadConcurrency))
                    Text("限制同时加载的阅读图片数量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("站点页面并发")
                    Picker("站点页面并发", selection: $pageConcurrency) {
                        ForEach(SiteRequestPolicy.concurrencyChoices, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("account.loading.site-concurrency")
                    .accessibilityValue(String(pageConcurrency))
                    .onChange(of: pageConcurrency) { _, _ in session.updatePageConcurrency() }
                    Text("站点连接不稳定时可调低；搜索仍保留请求间隔。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("阅读与存储") {
                LabeledContent("浏览缓存上限", value: "2 GB")
                LabeledContent("手动下载", value: "按设备可用空间保存")
                LabeledContent("阅读历史", value: "\(library.snapshot.history.count) 项")
                LabeledContent("稍后再读", value: "\(library.snapshot.bookmarks.count) 项")
                Button("清理浏览缓存", role: .destructive) {
                    Task { do { try await MediaRepository.shared.clear(owner: library.owner); message = "浏览缓存已清理" } catch { message = "缓存清理未完成，请重试。" } }
                }.disabled(downloads.running != nil)
                Text("清理浏览缓存会保留离线副本、稍后再读、标签、阅读历史和搜索组合。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("浏览缓存文件由本机存储管理；手动下载属于离线资料。网页登录使用临时 WebKit 会话。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("阅读与存储").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .onAppear {
            ReaderLoadPolicy.migrate(defaults: ReaderPreferenceDefaults.store)
            prefetchCount = ReaderLoadPolicy.clampedPrefetchCount(prefetchCount)
            downloadConcurrency = ReaderLoadPolicy.clampedConcurrency(downloadConcurrency)
            pageConcurrency = SiteRequestPolicy.clampedConcurrency(pageConcurrency)
        }
        .alert("预加载数量", isPresented: $editingPrefetch) {
            TextField("0–128", text: $prefetchEntry).keyboardType(.numberPad)
            Button("取消", role: .cancel) { }
            Button("保存") {
                if let count = Int(prefetchEntry), (0...ReaderLoadPolicy.maxPrefetchCount).contains(count) {
                    prefetchCount = count
                }
            }
            .disabled(Int(prefetchEntry).map { !(0...ReaderLoadPolicy.maxPrefetchCount).contains($0) } ?? true)
        } message: {
            Text("输入 0–128 张；0 表示关闭预加载。")
        }
    }
}
