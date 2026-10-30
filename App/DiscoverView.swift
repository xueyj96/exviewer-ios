import SwiftUI
import ExViewerCore

struct DiscoverView: View {
    @Binding var query: SearchQuery
    @Binding var site: GallerySite
    @Binding var editingSaved: UUID?
    var onSearchTag: (GalleryTag, GallerySite) -> Void
    var runRevision: UUID? = nil

    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var navigation: DiscoveryNavigation
    @State private var started = false
    @State private var composing = false
    @State private var composerStart: SearchComposerStart = .main
    @State private var historyShowing = false
    @State private var saving = false
    @State private var error: String?
    @State private var pendingEdit: SavedSearch?
    @State private var web: WebDestination?

    init(query: Binding<SearchQuery>, site: Binding<GallerySite>, editingSaved: Binding<UUID?>, runRevision: UUID? = nil,
         onSearchTag: @escaping (GalleryTag, GallerySite) -> Void = { _, _ in }) {
        _query = query; _site = site; _editingSaved = editingSaved; self.runRevision = runRevision
        self.onSearchTag = onSearchTag
        _navigation = StateObject(wrappedValue: DiscoveryNavigation(query: query.wrappedValue, site: site.wrappedValue, lane: 0, savedID: editingSaved.wrappedValue))
    }

    private var entry: DiscoveryEntry { navigation.current }
    private var hasActiveConditions: Bool { entry.query.count > 0 }

    var body: some View {
        FloatingFeedLayout { headerHeight in
            Group {
                if !session.hasCredentials && !AppMode.qa && !started {
                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "books.vertical").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.accent)
                            Text("发现画廊").font(.title2.weight(.medium))
                            Text("登录自己的站点账号，或以访客身份开始浏览。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("登录站点账号") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                            Button("开始浏览") { startCurrent() }.font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        Spacer()
                    }
                } else {
                    DiscoveryFeedView(entry: entry, topInset: headerHeight, onRefresh: { [id = entry.id] in
                        guard navigation.current.id == id else { return }; refreshCurrent()
                    }, isCurrent: { [id = entry.id] in navigation.current.id == id })
                        .id(entry.id)
                        .environmentObject(session)
                        .environmentObject(library)
                        .modifier(DiscoveryHistoryGesture(topInset: headerHeight,
                                                         canGoBack: navigation.canGoBack, canGoForward: navigation.canGoForward,
                                                         onBack: goBack, onForward: goForward))
                }
            }
        } header: {
            discoverFloatingHeader
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $web) { OfficialWebView(destination: $0) }
        .sheet(isPresented: $historyShowing) {
            NavigationStack {
                ReadingHistoryView().navigationDestination(for: Gallery.self) { gallery in
                    GalleryDetailView(gallery: gallery) { tag, site in
                        historyShowing = false; onSearchTag(tag, site)
                    }
                }
            }
        }
        .onChange(of: runRevision) { oldValue, newValue in
            guard oldValue != newValue else { return }
            do {
                _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: editingSaved, session: session, qa: AppMode.qa)
                started = true
                publish(navigation.current)
                library.recordSearch(query: navigation.current.query, site: navigation.current.site)
                error = nil
            } catch { self.error = message(for: error) }
        }
        .onChange(of: session.hasCredentials) { _, value in if value { startCurrent() } }
        .task {
            guard !started && (AppMode.qa || session.hasCredentials || query.count > 0) else { return }
            if query == entry.query && site == entry.site && editingSaved == entry.savedID { startCurrent() }
            else {
                do {
                    _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: editingSaved, session: session, qa: AppMode.qa)
                    started = true; publish(navigation.current)
                    library.recordSearch(query: navigation.current.query, site: navigation.current.site)
                } catch { self.error = message(for: error) }
            }
        }
    }

    private var discoverFloatingHeader: some View {
        FloatingHeaderPanel {
            VStack(spacing: 6) {
                if let error { StatusMessage(title: error) }
                searchEntryRow
                if !library.snapshot.saved.isEmpty { savedSearchShortcuts }
                if !entry.query.rules.isEmpty { ruleChips }
                if entry.query.count == 0 {
                    Picker("浏览范围", selection: laneBinding) { Text("最新").tag(0); Text("热门").tag(1) }
                        .pickerStyle(.segmented)
                } else {
                    HStack(spacing: 10) {
                        Text("已执行：\(searchSummary(entry.query, site: entry.site))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button(action: prepareToSave) { Image(systemName: "bookmark").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("保存搜索组合")
                            .accessibilityIdentifier("discover.save")
                            .sheet(isPresented: $saving) { savedSearchSheet }
                        Button("清除条件") { clearConditions() }.font(.caption).frame(minHeight: 44)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.header.floating")
    }

    private var searchEntryRow: some View {
        HStack(spacing: 0) {
            if navigation.canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                .accessibilityIdentifier("discover.back")
                .contextMenu {
                    if navigation.canGoForward { Button("前进", systemImage: "chevron.right", action: goForward) }
                }
            }
            Button { pendingEdit = nil; composerStart = .main; composing = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.body).foregroundStyle(.secondary)
                    Text(hasActiveConditions ? searchSummary(entry.query, site: entry.site) : "关键词、标签与条件")
                        .font(.subheadline).lineLimit(1).foregroundStyle(hasActiveConditions ? .primary : .secondary)
                    Spacer(minLength: 0)
                }.padding(.leading, 12).padding(.trailing, 8).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasActiveConditions ? "编辑搜索条件" : "搜索关键词、标签与条件")
            .accessibilityIdentifier("discover.search-entry")
            Divider().frame(height: 18)
            Button { pendingEdit = nil; composerStart = .filters; composing = true } label: {
                Image(systemName: "slider.horizontal.3").font(.body)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if entry.query.count > 0 {
                            Text(String(entry.query.count)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(3).background(Color.accentColor, in: Circle()).offset(x: -2, y: 1)
                        }
                    }
            }.buttonStyle(.plain)
            .accessibilityLabel("搜索筛选条件")
            .accessibilityIdentifier("discover.filters")
            Button { historyShowing = true } label: {
                Image(systemName: "clock").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("阅读历史").accessibilityIdentifier("discover.history")
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 2)
        .sheet(isPresented: $composing) { composerSheet }
    }

    private var savedSearchShortcuts: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(library.snapshot.saved) { saved in
                        Button { edit(saved) } label: {
                            Text(saved.name).font(.caption.weight(entry.savedID == saved.id ? .semibold : .regular))
                                .lineLimit(1).padding(.horizontal, 11).padding(.vertical, 7)
                                .background(entry.savedID == saved.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035), in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("载入组合编辑：\(saved.name)")
                            .accessibilityIdentifier("discover.preset.\(saved.id)")
                    }
                }
            }
            .accessibilityIdentifier("discover.saved-shortcuts")
            Button { pendingEdit = nil; composerStart = .favorites; composing = true } label: { Text("全部").frame(minHeight: 44) }
                .font(.caption.weight(.medium)).accessibilityIdentifier("discover.saved-menu")
        }
        .padding(.bottom, 2)
    }

    private var ruleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(entry.query.rules) { rule in
                    Button {
                        var updated = entry.query
                        updated.rules.removeAll { $0.id == rule.id }
                        submit(updated, site: entry.site, lane: entry.lane, savedID: nil)
                    } label: {
                        Text("\(rule.match.name) · \(rule.tag.label)  ×")
                            .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                            .frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, 2)
        }
        .accessibilityIdentifier("discover.rule-chips")
    }

    private var laneBinding: Binding<Int> {
        Binding(get: { entry.lane }, set: { lane in submit(entry.query, site: entry.site, lane: lane, savedID: entry.savedID) })
    }

    private var composerSheet: some View {
        let saved = pendingEdit ?? entry.savedID.flatMap { id in library.snapshot.saved.first { $0.id == id } }
        let initialQuery = saved?.query ?? entry.query
        let initialSite = saved?.site ?? entry.site
        let initialSavedID = saved?.id ?? entry.savedID
        return DiscoveryComposerView(query: initialQuery, site: initialSite, savedID: initialSavedID,
                                     startAt: composerStart, loadedPreset: saved) { query, site, savedID in
            _ = try navigation.submit(query: query, site: site, lane: entry.lane, savedID: savedID, session: session, qa: AppMode.qa)
            started = true
            publish(navigation.current)
            library.recordSearch(query: navigation.current.query, site: navigation.current.site)
            error = nil
            pendingEdit = nil
        }
        .environmentObject(library)
    }

    private var savedSearchSheet: some View {
        SaveSearchSheet(query: entry.query, site: entry.site, replacing: entry.savedID,
                        initialName: entry.savedID.flatMap { id in library.snapshot.saved.first { $0.id == id }?.name } ?? "") { id in
            do {
                _ = try navigation.submit(query: entry.query, site: entry.site, lane: entry.lane, savedID: id, session: session, qa: AppMode.qa)
                publish(navigation.current); error = nil
            } catch { self.error = message(for: error) }
        }
    }

    private func startCurrent() {
        do {
            let isFirstExecution = !entry.didStart
            try navigation.startCurrent(session: session, qa: AppMode.qa)
            if isFirstExecution { library.recordSearch(query: entry.query, site: entry.site) }
            started = true; error = nil
        } catch { self.error = message(for: error) }
    }

    private func submit(_ query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?) {
        do {
            _ = try navigation.submit(query: query, site: site, lane: lane, savedID: savedID, session: session, qa: AppMode.qa)
            started = true; publish(navigation.current); error = nil
            library.recordSearch(query: navigation.current.query, site: navigation.current.site)
        } catch { self.error = message(for: error) }
    }

    private func edit(_ saved: SavedSearch) {
        pendingEdit = saved; composerStart = .main; composing = true
    }

    private func goBack() {
        guard navigation.back() else { return }
        resumeHistoryEntry()
    }

    private func goForward() {
        guard navigation.forward() else { return }
        resumeHistoryEntry()
    }

    private func resumeHistoryEntry() {
        publish(navigation.current)
        startCurrent()
        if entry.pager.interrupted { entry.pager.retry(session: session) }
    }

    private func clearConditions() {
        submit(SearchQuery(), site: entry.site, lane: entry.lane, savedID: nil)
    }

    private func publish(_ value: DiscoveryEntry) {
        query = value.query; site = value.site; editingSaved = value.savedID
    }

    private func refreshCurrent() {
        entry.pager.reset(url: entry.requestURL, session: session, qa: AppMode.qa)
    }

    private func prepareToSave() {
        guard hasActiveConditions else { return }
        saving = true
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
    }

    private func searchSummary(_ query: SearchQuery, site: GallerySite) -> String {
        SearchPresentation.summary(query, site: site)
    }
}

private struct DiscoveryHistoryGesture: ViewModifier {
    let topInset: CGFloat
    let canGoBack: Bool
    let canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.18))) private var drag: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .updating($drag) { value, state, _ in
                    guard value.startLocation.y > topInset,
                          direction(value.translation) != nil else { return }
                    state = value.translation.width
                }
                .onEnded { value in
                    guard value.startLocation.y > topInset,
                          let action = DiscoveryHistorySwipe.committedDirection(
                            horizontal: Double(value.translation.width), vertical: Double(value.translation.height),
                            predictedHorizontal: Double(value.predictedEndTranslation.width),
                            canGoBack: canGoBack, canGoForward: canGoForward) else { return }
                    if action == .back { onBack() } else { onForward() }
                })
            .overlay(alignment: drag >= 0 ? .leading : .trailing) {
                if drag != 0 {
                    Image(systemName: drag > 0 ? "chevron.left" : "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(FloatingChrome.background, in: Circle())
                        .padding(.horizontal, 10)
                        .opacity(Double(min(1, abs(drag) / 72)))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityAction(named: Text("返回上一页")) { if canGoBack { onBack() } }
            .accessibilityAction(named: Text("前进下一页")) { if canGoForward { onForward() } }
    }

    private func direction(_ translation: CGSize) -> DiscoveryHistorySwipe.Direction? {
        DiscoveryHistorySwipe.direction(horizontal: Double(translation.width), vertical: Double(translation.height),
                                        canGoBack: canGoBack, canGoForward: canGoForward)
    }
}

private struct DiscoveryFeedView: View {
    @ObservedObject var entry: DiscoveryEntry
    var topInset: CGFloat
    var onRefresh: () -> Void
    var isCurrent: () -> Bool
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var pager: GalleryPager
    @State private var restoring = true

    init(entry: DiscoveryEntry, topInset: CGFloat, onRefresh: @escaping () -> Void, isCurrent: @escaping () -> Bool) {
        self.entry = entry; self.topInset = topInset; self.onRefresh = onRefresh; self.isCurrent = isCurrent
        _pager = ObservedObject(wrappedValue: entry.pager)
    }

    var body: some View {
        GeometryReader { viewport in
          ScrollViewReader { proxy in
           ScrollView {
            LazyVStack(spacing: 0) {
                if pager.interrupted {
                    StatusMessage(title: "已暂停之前的加载，可重试继续。") { pager.retry(session: session) }
                }
                GalleryRows(galleries: pager.items, layout: .grid, sourceIdentity: entry.id.uuidString,
                            onNearEnd: { if !restoring && isCurrent() && pager.failure == nil && !pager.interrupted { pager.more(session: session, prefetch: true) } },
                            viewport: .init(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset),
                            onVisibleAnchor: { if !restoring && isCurrent() { entry.updateVisibleAnchor($0) } })
                    .scrollTargetLayout()
                GalleryContinuationFooter(pager: pager)
                if !pager.loading && pager.failure == nil && pager.items.isEmpty && !pager.interrupted {
                    StatusMessage(title: entry.query.count > 0 ? "当前组合没有结果，可调整筛选条件。" : "当前范围没有结果。", symbol: entry.query.count > 0 ? "magnifyingglass" : "tray")
                }
            }
            .padding(.top, topInset)
        }
        .coordinateSpace(name: entry.id.uuidString)
        .accessibilityIdentifier("discover.feed")
        .refreshable(action: onRefresh)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .task(id: topInset) {
            restoring = true
            // A new feed must finish its initial placement before viewport
            // callbacks can save anchors or request another batch.
            let anchor = entry.scrollAnchor ?? entry.pager.items.first?.id
            await Task.yield()
            guard !Task.isCancelled, isCurrent() else { return }
            if let anchor {
                let viewport = GalleryFeedViewport(space: entry.id.uuidString, height: viewport.size.height, topOcclusion: topInset)
                let target = GalleryFeedViewport.restorationID(for: anchor)
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, isCurrent() else { return }
                proxy.scrollTo(target, anchor: viewport.restorationAlignment)
            }
            restoring = false
        }
          }
        }
        .overlay(alignment: .topLeading) {
            if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "discover") }
        }
    }
}
