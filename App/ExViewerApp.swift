import SwiftUI
import UIKit
import ExViewerCore
import ImageIO

enum AppMode {
    static var qa: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--qa")
        #else
        return false
        #endif
    }
    static var screen: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard qa, let index = arguments.firstIndex(of: "--screen"), arguments.indices.contains(index + 1) else { return "browse" }
        return arguments[index + 1]
    }
}
enum Palette {
    static let accent = Color(uiColor: .systemBlue)
    static let background = Color(uiColor: .systemGroupedBackground)
}

private struct QAVisualEnvironment: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if AppMode.qa {
            content.preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--qa-dark") ? .dark : nil)
                .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-large-type") ? .accessibility2 : .large)
        } else { content }
    }
}

private enum BrowserPreferenceDefaults {
    static let suite = "ExViewer.Browser.QA"
    static let store: UserDefaults = AppMode.qa ? UserDefaults(suiteName: suite)! : .standard
}

@main struct ExViewerApp: App {
    @StateObject private var session: SiteSession
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    init() {
        if AppMode.qa && !ProcessInfo.processInfo.arguments.contains("--qa-keep-site-preference") {
            BrowserPreferenceDefaults.store.set(GallerySite.ex.rawValue, forKey: "browser.site")
        }
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reset-reader-preferences") {
            UserDefaults(suiteName: "ExViewer.Reader.QA")?.removePersistentDomain(forName: "ExViewer.Reader.QA")
        }
        let session = SiteSession(qa: AppMode.qa), library = LibraryStore(qa: AppMode.qa)
        library.load(owner: session.owner)
        _session = StateObject(wrappedValue: session); _library = StateObject(wrappedValue: library)
        _downloads = StateObject(wrappedValue: DownloadManager(session: session, library: library))
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(session).environmentObject(library).environmentObject(downloads).tint(Palette.accent)
                .modifier(QAVisualEnvironment())
                .overlay { SelectionPerformanceProbeInstaller() }
                .task { if !AppMode.qa && session.hasCredentials { await session.verify() } }
                .onChange(of: session.owner) { _, owner in downloads.pauseAll(); library.load(owner: owner) }
                .onChange(of: session.generation) { _, _ in downloads.pauseAll() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { downloads.pauseAll() } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in ReaderImagePipeline.shared.clearCache() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = AppMode.screen == "tags" || AppMode.screen == "account" ? 2 : 0
    @State private var search = SearchQuery()
    @AppStorage("browser.site", store: BrowserPreferenceDefaults.store) private var browserSiteRaw = GallerySite.ex.rawValue
    @State private var editingSaved: UUID?
    @State private var searchRun = UUID()
    @State private var discoveryPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var accountPath = NavigationPath()
    private var browserSite: GallerySite {
        get { GallerySite(rawValue: browserSiteRaw) ?? .ex }
        nonmutating set { browserSiteRaw = newValue.rawValue }
    }
    private var browserSiteBinding: Binding<GallerySite> {
        Binding(get: { browserSite }, set: { browserSite = $0 })
    }
    private var settingsSiteBinding: Binding<GallerySite> {
        Binding(get: { browserSite }, set: { newSite in
            guard newSite != browserSite else { return }
            browserSite = newSite
            searchRun = UUID()
        })
    }
    var body: some View {
        CompactMainTabs(selection: $selection) {
            TabView(selection: $selection) {
                NavigationStack(path: $discoveryPath) {
                    DiscoverView(query: $search, site: browserSiteBinding, editingSaved: $editingSaved, runRevision: searchRun)
                        .navigationDestination(for: Gallery.self) {
                            GalleryDetailView(gallery: $0, onSearchTag: useTag)
                                .toolbar(.visible, for: .navigationBar)
                        }
                }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(0)
                NavigationStack(path: $libraryPath) {
                    LibraryView(site: browserSiteBinding, useSearch: useSearch)
                        .navigationDestination(for: Gallery.self) {
                            GalleryDetailView(gallery: $0, onSearchTag: useTag)
                                .toolbar(.visible, for: .navigationBar)
                        }
                }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("资料库", systemImage: "books.vertical") }.tag(1)
                NavigationStack(path: $accountPath) {
                    AccountView(site: settingsSiteBinding) { useTag($0, browserSite) }
                }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("账号", systemImage: "person.crop.circle") }.tag(2)
            }
        }
        .id(session.generation)
        .onChange(of: session.generation) { _, _ in
            discoveryPath = NavigationPath(); libraryPath = NavigationPath(); accountPath = NavigationPath()
        }
        .onChange(of: session.owner) { _, _ in
            search = SearchQuery(); editingSaved = nil; searchRun = UUID(); selection = 0
        }
        .sheet(isPresented: .constant(AppMode.screen == "reader" || AppMode.screen == "web-compat")) {
            if AppMode.screen == "web-compat" { WebCompatibilityQAView() }
            else { ReaderView(gallery: QASamples.galleries[0]) }
        }
    }
    private func useSearch(_ saved: SavedSearch) {
        browserSite = saved.site; search = saved.query; editingSaved = saved.id
        discoveryPath = NavigationPath(); searchRun = UUID(); selection = 0
    }
    private func useTag(_ tag: GalleryTag, _ sourceSite: GallerySite) {
        browserSite = sourceSite
        search.rules.removeAll { $0.id == tag.id }; search.rules.append(.init(tag: tag)); editingSaved = nil
        discoveryPath = NavigationPath(); searchRun = UUID(); selection = 0
    }
}

struct StatusMessage: View {
    var title: String
    var symbol = "exclamationmark.circle"
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button("重试", action: action).buttonStyle(AppActionButtonStyle()) }
        }.frame(maxWidth: .infinity).padding(28)
    }
}

enum GalleryLayout { case list, grid }

struct GalleryFeedViewport {
    var space: String
    var height: CGFloat
    var topOcclusion: CGFloat = 0

    static func restorationID(for galleryID: String) -> String { "feed.restore.\(galleryID)" }

    // The restoration marker is one point high, independent of the cover's
    // aspect ratio. Align that marker immediately below the floating header.
    var restorationAlignment: UnitPoint {
        UnitPoint(x: 0.5, y: min(max(0, topOcclusion) / max(1, height - 1), 1))
    }
}

private struct GalleryCellFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct GalleryRows: View {
    var galleries: [Gallery]
    var layout: GalleryLayout = .list
    var freezeGridLayout = false
    var selectionStore: LibrarySelectionStore? = nil
    var onLongPressSelect: ((Gallery) -> Void)? = nil
    var onBookmarkToggle: ((Gallery) -> Void)? = nil
    var onNearEnd: (() -> Void)? = nil
    var viewport: GalleryFeedViewport? = nil
    var onVisibleAnchor: ((String) -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore
    private let aspectCache = CoverAspectCache.shared
    @State private var preparedVisible: [Gallery]?
    @State private var preparedUnknown = 0
    @State private var preparedColumns: [[Gallery]]?
    @State private var lastAutomaticAnchor: String?
    private var visible: [Gallery] { preparedVisible ?? filterGalleries().visible }
    private var unknown: Int { preparedVisible == nil ? filterGalleries().unknown : preparedUnknown }
    var body: some View {
        LazyVStack(spacing: 0) {
            if unknown > 0 { Text("\(unknown) 项标签尚未核实，暂按屏蔽设置隐藏。") .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding() }
            if layout == .grid {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(gridColumns.enumerated()), id: \.offset) { entry in
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(entry.element) { gallery in
                                VStack(spacing: 0) {
                                    restorationAnchor(gallery)
                                    gridCell(gallery)
                                }.id(gallery.id).background { measure(gallery) }
                            }
                        }.scrollTargetLayout().frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ForEach(visible) { gallery in
                    VStack(spacing: 0) {
                        restorationAnchor(gallery)
                        NavigationLink(value: gallery) { GalleryRow(gallery: gallery) }.buttonStyle(.plain)
                    }.id(gallery.id).background { measure(gallery) }
                    Divider().padding(.leading, 122)
                }
            }
            if !galleries.isEmpty && visible.isEmpty && unknown == 0 { StatusMessage(title: "当前结果已被本机标签屏蔽。可到账号的「标签与屏蔽」调整。", symbol: "eye.slash") }
        }
        .onAppear(perform: prepareLayout)
        .onChange(of: galleries) { _, _ in prepareLayout() }
        .onChange(of: library.blockedIDs) { _, _ in prepareLayout() }
        .onReceive(aspectCache.revisionChanges) { _ in if !freezeGridLayout { prepareColumns() } }
        .onChange(of: freezeGridLayout) { _, frozen in if !frozen { prepareColumns() } }
        .onPreferenceChange(GalleryCellFrames.self, perform: observedFrames)
    }

    @ViewBuilder private func measure(_ gallery: Gallery) -> some View {
        if let viewport {
            GeometryReader { geometry in
                Color.clear.preference(key: GalleryCellFrames.self,
                                       value: [gallery.id: geometry.frame(in: .named(viewport.space))])
            }
        }
    }

    @ViewBuilder private func restorationAnchor(_ gallery: Gallery) -> some View {
        if viewport != nil {
            Color.clear.frame(height: 1)
                .id(GalleryFeedViewport.restorationID(for: gallery.id))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func observedFrames(_ frames: [String: CGRect]) {
        guard let viewport, viewport.height > 0 else { return }
        let visibleTop = min(max(0, viewport.topOcclusion), viewport.height)
        let inView = frames.filter { $0.value.maxY > visibleTop && $0.value.minY < viewport.height }
        let anchor = inView.min(by: { abs($0.value.minY - visibleTop) < abs($1.value.minY - visibleTop) })?.key
        if let anchor {
            onVisibleAnchor?(anchor)
        }
        // SwiftUI can create lazy cells before they enter the viewport. Only
        // an actual tail cell near the visible bottom may request another page.
        if let anchor, lastAutomaticAnchor != anchor, visible.suffix(2).contains(where: { gallery in
            guard let frame = frames[gallery.id] else { return false }
            return frame.maxY > visibleTop && frame.minY <= viewport.height + max(1, viewport.height - visibleTop)
        }) {
            // One automatic batch per visible-anchor advance prevents a short
            // feed from recursively fetching every page while the user is idle.
            lastAutomaticAnchor = anchor; onNearEnd?()
        }
    }

    @ViewBuilder private func gridCell(_ gallery: Gallery) -> some View {
        if let selectionStore {
            GallerySelectableCell(gallery: gallery,
                                  store: selectionStore,
                                  entry: selectionStore.entry(for: gallery.id),
                                  accessibilityLabel: selectionLabel(gallery))
        } else {
            let link = NavigationLink(value: gallery) { GalleryGridCell(gallery: gallery) }
            if let onLongPressSelect {
                link.buttonStyle(.plain)
                    .accessibilityIdentifier("favorites.gallery.\(gallery.ref.gid)")
                    .accessibilityHint("轻点打开详情，长按选择并管理")
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.55)
                        .onEnded { _ in onLongPressSelect(gallery) })
            } else if onBookmarkToggle != nil {
                link.buttonStyle(.plain)
                    .accessibilityIdentifier("favorites.gallery.\(gallery.ref.gid)")
                    .contextMenu { gridContextMenu(for: gallery) }
            } else {
                link.buttonStyle(.plain).accessibilityIdentifier("gallery.open.\(gallery.ref.gid)")
                }
        }
    }

    private func selectionLabel(_ gallery: Gallery) -> String {
        guard AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-library-delayed-covers") else { return gallery.title }
        return gallery.title + (CoverAspectCache.shared.hasAspect(for: gallery) ? "，封面已载入" : "，封面载入中")
    }

    @ViewBuilder private func gridContextMenu(for gallery: Gallery) -> some View {
        if onBookmarkToggle != nil {
            NavigationLink(value: gallery) { Label("打开详情", systemImage: "book.closed") }
            Button { onBookmarkToggle?(gallery) } label: {
                Label("切换本机书签", systemImage: "bookmark")
            }
        }
    }

    /// Assign each item to the currently shorter column. Cover aspect ratios are
    /// updated from image metadata as visible cells finish loading.
    private var gridColumns: [[Gallery]] { preparedColumns ?? makeGridColumns(for: visible) }

    private func filterGalleries() -> (visible: [Gallery], unknown: Int) {
        LibrarySelectionPolicy.filtered(galleries, blocked: library.blockedIDs)
    }

    private func prepareLayout() {
        let result = filterGalleries()
        preparedVisible = result.visible
        preparedUnknown = result.unknown
        preparedColumns = makeGridColumns(for: result.visible)
    }

    private func prepareColumns() { preparedColumns = makeGridColumns(for: visible) }

    private func makeGridColumns(for visible: [Gallery]) -> [[Gallery]] {
        var columns = [ [Gallery](), [Gallery]() ]
        var heights: [CGFloat] = [0, 0]
        for gallery in visible {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(gallery)
            heights[column] += 1 / CoverAspectCache.shared.aspect(for: gallery) + 0.36
        }
        return columns
    }
}

struct GallerySelectableCell: View {
    let gallery: Gallery
    let store: LibrarySelectionStore
    @ObservedObject var entry: LibrarySelectionEntry
    var accessibilityLabel: String

    var body: some View {
        Button {
            SelectionPerformanceProbe.markAction(id: gallery.id)
            guard store.toggle(gallery.id) else { return }
            SelectionPerformanceProbe.markStateSet(id: gallery.id, count: store.selectedIDs.count)
        } label: {
            GalleryGridCell(gallery: gallery)
                .padding(5)
                .background(entry.isSelected ? Palette.accent.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(entry.isSelected ? Palette.accent : .clear, lineWidth: 2)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(entry.isSelected ? Palette.accent : .secondary)
                        .frame(width: 44, height: 44)
                        .background(FloatingChrome.background, in: Circle())
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(entry.isSelected ? "已选中" : "未选中")
        .accessibilityHint("轻点切换选择状态")
        .accessibilityIdentifier("favorites.select.\(gallery.ref.gid)")
        .onChange(of: entry.isSelected) { _, selected in
            SelectionPerformanceProbe.markSelectionViewUpdate(id: gallery.id, selected: selected)
        }
    }
}

struct GalleryGridCell: View {
    var gallery: Gallery
    @ObservedObject private var aspect: CoverAspectEntry
    init(gallery: Gallery) {
        self.gallery = gallery
        _aspect = ObservedObject(wrappedValue: CoverAspectCache.shared.entry(for: gallery))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(aspect.aspect, contentMode: .fit)
                .overlay { CoverView(gallery: gallery) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain).accessibilityIdentifier("gallery.cover.\(gallery.ref.gid)")
            Text(gallery.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .accessibilityIdentifier("gallery.title.\(gallery.ref.gid)")
            if !gallery.category.isEmpty || gallery.pages != nil {
                HStack(spacing: 6) {
                    if !gallery.category.isEmpty { Text(gallery.category).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let pages = gallery.pages { Text("\(pages) 页").fixedSize() }
                }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("gallery.metadata.\(gallery.ref.gid)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

@MainActor final class CoverAspectEntry: ObservableObject {
    @Published private(set) var aspect: CGFloat = 0.71
    @Published private(set) var hasAspect = false
    fileprivate func set(_ value: CGFloat) {
        guard aspect != value || !hasAspect else { return }
        aspect = value; hasAspect = true
    }
}

@MainActor final class CoverAspectCache: ObservableObject {
    static let shared = CoverAspectCache()
    private var entries: [String: CoverAspectEntry] = [:]
    @Published private(set) var revision = 0
    private init() {}

    func aspect(for gallery: Gallery) -> CGFloat {
        entry(for: gallery).aspect
    }

    func hasAspect(for gallery: Gallery) -> Bool { entry(for: gallery).hasAspect }

    func set(_ aspect: CGFloat, for gallery: Gallery) {
        guard aspect.isFinite, aspect > 0 else { return }
        let item = entry(for: gallery)
        guard item.aspect != aspect || !item.hasAspect else { return }
        item.set(aspect)
        revision &+= 1
    }

    var revisionChanges: Published<Int>.Publisher { $revision }

    func entry(for gallery: Gallery) -> CoverAspectEntry {
        let identity = key(for: gallery)
        if let entry = entries[identity] { return entry }
        let entry = CoverAspectEntry()
        entries[identity] = entry
        return entry
    }

    private func key(for gallery: Gallery) -> String { "\(gallery.id)|\(gallery.cover?.absoluteString ?? "")" }
}

struct GalleryRow: View {
    var gallery: Gallery
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(gallery: gallery).frame(width: 90, height: 126).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 7) {
                Text(gallery.category.isEmpty ? "画廊" : gallery.category.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(Palette.accent)
                Text(gallery.title).font(.system(size: 15, weight: .medium)).lineLimit(3).foregroundStyle(.primary).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let pages = gallery.pages { Text("\(pages) 页") }
                    if let rating = gallery.rating { Label(String(format: "%.2f", rating), systemImage: "star.fill") }
                }.font(.caption).foregroundStyle(.secondary)
                if !gallery.uploader.isEmpty { Text(gallery.uploader).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(gallery.tags.prefix(3).map(\.name).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.vertical, 16).contentShape(Rectangle())
    }
}

struct CoverView: View {
    var gallery: Gallery
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @State private var file: URL?
    @State private var fileContext: String?
    @State private var failure: String?
    @State private var retry = UUID()
    private struct RequestIdentity: Hashable { var owner: String; var gallery: String; var cover: URL?; var revision: UUID; var retry: UUID }
    private var requestIdentity: RequestIdentity { .init(owner: library.owner, gallery: gallery.id, cover: gallery.cover, revision: session.generation, retry: retry) }
    private var contextIdentity: String { "\(library.owner)|\(session.generation.uuidString)" }
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let file, fileContext == contextIdentity {
                StaticCover(file: file,
                            contextIdentity: contextIdentity,
                            requestIdentity: "\(gallery.id)|\(gallery.cover?.absoluteString ?? "none")|\(retry.uuidString)",
                            onDecodeFailure: { failure = ErrorMessages.message(ViewerError.unsupported) })
                    .overlay(alignment: .bottom) {
                        if let failure {
                            Button { self.failure = nil; retry = UUID() } label: {
                                Label("重试", systemImage: "arrow.clockwise").font(.caption).padding(8)
                            }.buttonStyle(.borderless).background(FloatingChrome.background, in: Capsule())
                                .accessibilityLabel("重新载入封面").accessibilityHint(failure)
                        }
                    }
            }
            else if AppMode.qa { QACover(seed: Int(gallery.ref.gid)) }
            else if let failure {
                VStack(spacing: 4) {
                    Text(failure).font(.caption2).lineLimit(3).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button { retry = UUID() } label: { Label("重试", systemImage: "arrow.clockwise").font(.caption).frame(minHeight: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("重新载入封面").accessibilityHint(failure)
                }.padding(5)
            }
            else if gallery.cover != nil { ProgressView() }
            else { Image(systemName: "book.closed").font(.title).foregroundStyle(Palette.accent.opacity(0.4)) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("cover.media.\(gallery.ref.gid)")
        .accessibilityValue(file == nil ? "载入中" : "已载入")
        .task(id: requestIdentity) {
            guard !Task.isCancelled else { return }
            // Keep a successfully displayed image while the same gallery is
            // revalidated. Identity changes recreate this task/context safely.
            failure = nil
            let currentContext = contextIdentity
            if fileContext != currentContext { file = nil; fileContext = nil }
            if AppMode.qa {
                if ProcessInfo.processInfo.arguments.contains("--qa-library-delayed-covers") {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                let fixture = gallery.cover.flatMap { $0.isFileURL ? $0 : nil } ?? QASamples.cover(seed: Int(gallery.ref.gid))
                fileContext = currentContext; file = fixture
                if let ratio = await coverAspectRatio(at: fixture) { CoverAspectCache.shared.set(ratio, for: gallery) }
                return
            }
            guard let cover = gallery.cover else { return }
            let revision = session.generation, owner = library.owner
            do {
                failure = nil
                let result = try await MediaRepository.shared.file(for: cover, owner: owner, priority: .thumbnail)
                try Task.checkCancellation()
                guard revision == session.generation, owner == library.owner else { return }
                fileContext = currentContext; file = result
                if !CoverAspectCache.shared.hasAspect(for: gallery),
                   let ratio = await coverAspectRatio(at: result) {
                    try Task.checkCancellation()
                    guard revision == session.generation, owner == library.owner else { return }
                    CoverAspectCache.shared.set(ratio, for: gallery)
                }
            } catch is CancellationError { }
            catch { guard revision == session.generation, owner == library.owner else { return }; failure = ErrorMessages.message(error) }
        }
    }
}

private func coverAspectRatio(at file: URL) async -> CGFloat? {
    await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        var width = CGFloat(rawWidth.doubleValue)
        var height = CGFloat(rawHeight.doubleValue)
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber,
           [5, 6, 7, 8].contains(orientation.intValue) { swap(&width, &height) }
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }.value
}

