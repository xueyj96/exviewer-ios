import SwiftUI
import ExViewerCore

enum ReaderPreferenceDefaults {
    static let store: UserDefaults = {
        let defaults = AppMode.qa ? UserDefaults(suiteName: "ExViewer.Reader.QA")! : .standard
        ReaderLoadPolicy.migrate(defaults: defaults)
        return defaults
    }()
}

enum ReaderMode: Int, CaseIterable, Identifiable {
    case continuous = 0
    case singlePage = 1
    var id: Int { rawValue }
    var title: String { self == .continuous ? "连续模式" : "单页模式" }
}

enum ReaderDirection: String, CaseIterable, Identifiable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop
    var id: String { rawValue }
    var horizontal: Bool { self == .leftToRight || self == .rightToLeft }
    var reverseOrder: Bool { self == .rightToLeft || self == .bottomToTop }
    var axis: Axis.Set { horizontal ? .horizontal : .vertical }
    var arrow: String { switch self { case .leftToRight: "→"; case .rightToLeft: "←"; case .topToBottom: "↓"; case .bottomToTop: "↑" } }
    var title: String { switch self { case .leftToRight: "从左到右"; case .rightToLeft: "从右到左"; case .topToBottom: "从上到下"; case .bottomToTop: "从下到上" } }
    var menuTitle: String { "\(title) \(arrow)" }
    var forwardSymbol: String { switch self { case .leftToRight: "arrow.right"; case .rightToLeft: "arrow.left"; case .topToBottom: "arrow.down"; case .bottomToTop: "arrow.up" } }
    var backwardSymbol: String { switch self { case .leftToRight: "arrow.left"; case .rightToLeft: "arrow.right"; case .topToBottom: "arrow.up"; case .bottomToTop: "arrow.down" } }
}

enum ReaderPageSizing {
    static func extent(imageSize: CGSize?, crossAxisExtent: CGFloat, direction: ReaderDirection) -> CGFloat {
        guard crossAxisExtent > 0 else { return 1 }
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return direction.horizontal ? crossAxisExtent * 0.72 : crossAxisExtent * 1.32
        }
        let ratio = imageSize.width / imageSize.height
        return direction.horizontal ? crossAxisExtent * ratio : crossAxisExtent / ratio
    }
}

private struct ReaderContentOrigin: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct ReaderPageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

@MainActor final class ReaderModel: ObservableObject {
    @Published private(set) var pages: [GalleryPage] = []
    @Published private(set) var total: Int?
    @Published private(set) var next: URL?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var seen = Set<URL>()
    private var context = UUID()
    private var generation: UUID?
    private var owner: String?
    private var metadataDemand: MediaRequestDemand?
    private(set) var qaMetadataCalls = 0
    func cancel() { context = UUID(); generation = nil; owner = nil; loading = false; metadataDemand = nil }
    func promotePendingMetadata() { metadataDemand?.setPriority(.foreground) }
    var hasForegroundMetadataDemand: Bool { metadataDemand?.priority == .foreground }
    func load(gallery: Gallery, offline: Bool, session: SiteSession, library: LibraryStore) async {
        cancel(); generation = session.generation; owner = library.owner
        pages = []; seen = []; total = gallery.pages; error = nil
        if AppMode.qa {
            let fixtures: [GalleryPage]
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-large-window") {
                fixtures = (1...40).map { GalleryPage(index: $0, url: QASamples.image(index: $0)) }
            } else {
                fixtures = QASamples.pages
            }
            total = fixtures.count
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-paging") {
                pages = Array(fixtures.prefix(2)); next = URL(string: "https://exhentai.org/g/1/preview/?p=1")
            } else { pages = fixtures; next = nil }
            return
        }
        if offline {
            guard TagFilter.decision(tags: gallery.tags, blocked: library.blockedIDs, complete: gallery.tagsComplete) == .visible else { error = "此画廊已被标签设置屏蔽，或标签尚未核实。"; return }
            if let record = library.snapshot.downloads.first(where: { $0.id == gallery.id }) {
                let directory = library.offlineDirectory(gallery)
                pages = record.completed.sorted { $0.key < $1.key }.compactMap { index, file in
                    guard !file.contains("/"), file == "page-\(index).media" else { return nil }
                    let url = directory.appendingPathComponent(file)
                    return FileManager.default.fileExists(atPath: url.path) ? GalleryPage(index: index, url: url) : nil
                }
                total = record.total
            }
            if pages.isEmpty { error = "本机没有可读取的离线副本。" }
            return
        }
        await fetch(url: gallery.ref.url, gallery: gallery, session: session, library: library)
    }
    func more(gallery: Gallery, session: SiteSession, library: LibraryStore,
              priority: MediaRequestPriority = .foreground, beforeAppending: (() -> Void)? = nil) async {
        guard !loading else { return }
        if AppMode.qa, next != nil {
            qaMetadataCalls += 1
            let expected = context
            loading = true
            defer { if expected == context { loading = false } }
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-metadata-stall") {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-delay") { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-metadata-ms=") })?.split(separator: "=").last.flatMap({ UInt64($0) }) {
                try? await Task.sleep(nanoseconds: min(value, 15_000) * 1_000_000)
            }
            guard !Task.isCancelled, expected == context, generation == session.generation, owner == library.owner else { return }
            beforeAppending?()
            pages = QASamples.pages; next = nil; return
        }
        if let next { await fetch(url: next, gallery: gallery, session: session, library: library, priority: priority, beforeAppending: beforeAppending) }
    }
    private func fetch(url: URL, gallery: Gallery, session: SiteSession, library: LibraryStore,
                       priority: MediaRequestPriority = .foreground, beforeAppending: (() -> Void)? = nil) async {
        guard generation == session.generation, owner == library.owner, !seen.contains(url), seen.count < 100 else { return }
        let current = context, revision = session.generation
        let demand = MediaRequestDemand(priority: priority)
        metadataDemand = demand
        loading = true
        defer { if current == context { loading = false; if metadataDemand === demand { metadataDemand = nil } } }
        do {
            let detail = try EHParser.detail(await session.html(url, request: demand), reference: gallery.ref, pageURL: url)
            guard current == context, revision == session.generation, owner == library.owner else { return }
            guard TagFilter.decision(tags: detail.gallery.tags, blocked: library.blockedIDs, complete: true) == .visible else { throw ViewerError.invalidQuery("此画廊命中本机屏蔽标签，可到账号的「标签与屏蔽」调整。") }
            beforeAppending?()
            seen.insert(url); var indexes = Set(pages.map(\.index)); pages += detail.pages.filter { indexes.insert($0.index).inserted }
            pages.sort { $0.index < $1.index }; next = detail.next; total = detail.gallery.pages; error = nil
        } catch is CancellationError { }
        catch { guard current == context, revision == session.generation, owner == library.owner else { return }; self.error = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription) }
    }
}

struct ReaderView: View {
    var gallery: Gallery
    var offline = false
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ReaderModel()
    @StateObject private var media = ReaderMediaStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current = 1
    @State private var scrollPosition: Int? = 1
    @AppStorage("reader.mode", store: ReaderPreferenceDefaults.store) private var mode = 0
    @AppStorage("reader.direction", store: ReaderPreferenceDefaults.store) private var storedDirection = ReaderDirection.leftToRight.rawValue
    @AppStorage("reader.prefetchCount", store: ReaderPreferenceDefaults.store) private var prefetchCount = ReaderLoadPolicy.defaultPrefetchCount
    @AppStorage("reader.downloadConcurrency", store: ReaderPreferenceDefaults.store) private var downloadConcurrency = ReaderLoadPolicy.defaultConcurrency
    @State private var pageSizes: [Int: CGSize] = [:]
    @State private var progressHUD = false
    @State private var progressRevision = UUID()
    private var direction: ReaderDirection {
        get { ReaderDirection(rawValue: storedDirection) ?? .leftToRight }
        nonmutating set { storedDirection = newValue.rawValue }
    }
    private var readingAnchor: UnitPoint {
        // A stable tracking anchor also identifies short pages at clamped edges.
        // Direction-specific boundary alignment belongs to the snapping policy.
        direction.horizontal ? .center : .top
    }
    private var motionReduced: Bool { reduceMotion || (AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reduce-motion")) }
    @State private var progressTarget = 1.0
    @State private var pageZoomed = false
    @State private var settings = false
    @State private var jump = false
    @State private var jumpText = ""
    @State private var findingPage = false
    @State private var holdingPosition = false
    @State private var userScrolling = false
    @State private var draggingCanvas = false
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var contentOrigin: CGPoint = .zero
    @State private var visiblePageFrames: [Int: CGRect] = [:]
    @State private var seekRevision = UUID()
    @State private var slideProgress: CGFloat = 1
    @State private var slideForward = true
    @State private var slideRevision = UUID()
    @State private var slideTask: Task<Void, Never>?
    @State private var historyCheckpoint: ReaderHistoryCheckpoint?
    @State private var singleDragActive = false
    @State private var singleDragFinishing = false
    @State private var singleDragOffset: CGFloat = 0
    @State private var singleDragPreview: Int?
    @State private var presentations: [Int: ImageCanvasPresentation] = [:]
    @State private var decodedFiles: [Int: URL] = [:]
    @State private var singleDragExtent: CGFloat = 0
    @State private var singleDragRevision = UUID()
    @State private var singleMetadataTask: Task<Void, Never>?
    @State private var singleMetadataRevision = UUID()
    @State private var singleMetadataAttemptedTarget: Int?
    @State private var singleMetadataError: String?
    @State private var automaticMetadataTask: Task<Void, Never>?
    @State private var automaticMetadataCursor: URL?
    @State private var automaticMetadataRevision = UUID()
    @State private var ignoreCanvasTapUntil = Date.distantPast
    @State private var lastDragEvidence = "none"
    @State private var lastReleaseEvidence = "none"
    @GestureState private var singleFingerDown = false
    @State private var viewportFrame: CGRect = .zero
    private struct ReadingContext: Equatable {
        let id = UUID()
        var generation: UUID
        var owner: String
    }
    @State private var readingContext: ReadingContext?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = model.error, model.pages.isEmpty || mode == ReaderMode.continuous.rawValue { StatusMessage(title: error) { Task { guard let context = readingContext, isCurrent(context) else { return }; await model.load(gallery: gallery, offline: offline, session: session, library: library) } } }
                if model.loading && model.pages.isEmpty { Spacer(); ProgressView(); Spacer() }
                GeometryReader { geometry in
                    ZStack {
                        if mode == ReaderMode.continuous.rawValue {
                            continuousPages
                        } else {
                            singlePage.simultaneousGesture(singleDragGesture(size: geometry.size), including: pageZoomed ? .subviews : .all)
                        }
                        edgeControls(size: geometry.size).allowsHitTesting(!pageZoomed && (!singleDragActive || singleDragFinishing))
                    }
                    .contentShape(Rectangle())
                    .onAppear { updateViewportFrame(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in updateViewportFrame(frame) }
                }
            }
                .safeAreaInset(edge: .bottom, spacing: 0) { readerControls }
                .background(Color.black)
                .navigationTitle(gallery.title).navigationBarTitleDisplayMode(.inline).appNavigationChrome()
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .cancellationAction) { closeButton }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .cancellationAction) { closeButton }
                    }
                }
                .preferredColorScheme(.dark)
                .task {
                    let context = ReadingContext(generation: session.generation, owner: library.owner)
                    readingContext = context
                    let expectedSession = session, expectedLibrary = library, expectedGallery = gallery
                    historyCheckpoint = ReaderHistoryCheckpoint(isCurrent: { [weak expectedSession, weak expectedLibrary] in
                        expectedSession?.generation == context.generation && expectedLibrary?.owner == context.owner
                    }, persist: { [weak expectedLibrary] page in
                        expectedLibrary?.remember(expectedGallery, page: page)
                    })
                    automaticMetadataCursor = nil
                    if AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-reader-transition") {
                        mode = ReaderMode.singlePage.rawValue
                        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-prefetch=") })?.split(separator: "=").last.flatMap({ Int($0) }), (0...ReaderLoadPolicy.maxPrefetchCount).contains(value) { prefetchCount = value }
                        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-concurrency=") })?.split(separator: "=").last.flatMap({ Int($0) }), (2...ReaderLoadPolicy.maxConcurrency).contains(value) { downloadConcurrency = value }
                    }
                    await model.load(gallery: gallery, offline: offline, session: session, library: library)
                    guard !Task.isCancelled, isCurrent(context) else { return }
                    let desired = library.snapshot.history.first(where: { $0.id == gallery.id })?.page ?? 1
                    await seek(desired)
                }
                .onDisappear { historyCheckpoint?.flush(); historyCheckpoint = nil; if let context = readingContext { MediaRepository.shared.releasePinnedFiles(context: context.id) }; singleDragRevision = UUID(); singleMetadataRevision = UUID(); singleMetadataTask?.cancel(); singleMetadataTask = nil; automaticMetadataTask?.cancel(); automaticMetadataTask = nil; scrollEndTask?.cancel(); scrollEndTask = nil; slideTask?.cancel(); seekRevision = UUID(); media.reset(); presentations = [:]; decodedFiles = [:]; userScrolling = false; draggingCanvas = false; pageZoomed = false; progressHUD = false; readingContext = nil; model.cancel() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { historyCheckpoint?.flush() } }
                .onChange(of: current) { _, value in
                    progressTarget = Double(value); pageZoomed = false
                    pageSizes = pageSizes.filter { abs($0.key - value) <= 2 }
                    presentations = presentations.filter { abs($0.key - value) <= 1 }
                    decodedFiles = decodedFiles.filter { abs($0.key - value) <= 1 }
                    updateMedia()
                }
                .onChange(of: model.pages) { _, _ in updateMedia() }
                .onChange(of: model.loading) { _, loading in if !loading { updateMedia() } }
                .onChange(of: media.files) { _, files in
                    presentations = presentations.filter { files[$0.key] == $0.value.file && abs($0.key - current) <= 1 }
                    if ReaderNetworkMetrics.enabled { decodedFiles = decodedFiles.filter { files[$0.key] == $0.value && abs($0.key - current) <= 1 } }
                    if let context = readingContext, isCurrent(context) { updatePinnedFiles(context) }
                    if AppMode.qa, singleDragActive, let preview = singleDragPreview {
                        lastDragEvidence = "\(current)+\(preview);offset=\(Int(abs(singleDragOffset)));neighborFile=\(files[preview] != nil)"
                    }
                }
                .onChange(of: prefetchCount) { _, value in
                    if !(0...ReaderLoadPolicy.maxPrefetchCount).contains(value) { prefetchCount = ReaderLoadPolicy.clampedPrefetchCount(value) }
                    if value == 0 {
                        automaticMetadataRevision = UUID()
                        automaticMetadataTask?.cancel(); automaticMetadataTask = nil; automaticMetadataCursor = nil
                    }
                    updateMedia()
                }
                .onChange(of: downloadConcurrency) { _, value in
                    if !(2...ReaderLoadPolicy.maxConcurrency).contains(value) { downloadConcurrency = ReaderLoadPolicy.clampedConcurrency(value) }
                    updateMedia()
                }
                .onChange(of: media.prefetchPaused) { _, paused in
                    if paused {
                        if !model.hasForegroundMetadataDemand {
                            automaticMetadataRevision = UUID()
                            automaticMetadataTask?.cancel(); automaticMetadataTask = nil; automaticMetadataCursor = nil
                        }
                    } else { updateMedia() }
                }
                .onChange(of: findingPage) { _, finding in if !finding { updateMedia() } }
                .onChange(of: pageZoomed) { _, zoomed in if zoomed { stopTrackingScroll(); cancelSingleDrag() } }
                .onChange(of: model.total) { _, total in if let total { progressTarget = min(progressTarget, Double(max(1, total))) } }
                .onChange(of: mode) { _, newMode in
                    progressHUD = false; pageZoomed = false; cancelPageAnimation()
                    if newMode == ReaderMode.continuous.rawValue { let page = current; Task { await seek(page) } }
                }
                .onChange(of: storedDirection) { _, _ in
                    progressHUD = false; pageZoomed = false; cancelPageAnimation()
                    let page = current; Task { await seek(page) }
                }
                .onChange(of: settings) { _, shown in if shown { progressHUD = false; stopTrackingScroll(); cancelSingleDrag() } }
                .onChange(of: singleFingerDown) { _, down in
                    if !down {
                        let intent = seekRevision
                        Task {
                            await Task.yield()
                            if seekRevision == intent && !singleFingerDown && singleDragActive && !singleDragFinishing { finishSingleDrag(commit: false) }
                        }
                    }
                }
                .alert("跳转到页码", isPresented: $jump) { TextField("页码", text: $jumpText).keyboardType(.numberPad); Button("跳转") { if let page = Int(jumpText) { Task { await seek(page) } } }; Button("取消", role: .cancel) { } } message: { Text("动图完整播放，按一张图片计算一页。") }
                .overlay(alignment: .top) { if findingPage { ProgressView("正在定位页面").font(.caption).padding(8).allowsHitTesting(false) } }
                .sheet(isPresented: $settings) { readerSettings }
        }
        .overlay {
            if progressHUD, let total = model.total {
                Text("\(Int(progressTarget.rounded())) / \(total)")
                    .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.76), in: Capsule())
                    .accessibilityIdentifier("reader.progress.hud")
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if AppMode.qa || ReaderNetworkMetrics.enabled {
                Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier(AppMode.qa ? "reader.cache.qa" : "reader.metrics.state").accessibilityValue(cacheDiagnostic).allowsHitTesting(false)
            }
        }
    }

    private var continuousPages: some View {
        GeometryReader { geometry in
            ScrollView(direction.axis) {
                if direction.horizontal {
                    LazyHStack(spacing: 2) { continuousPageContent(geometry: geometry) }
                        .scrollTargetLayout()
                        .background { scrollOriginReporter }
                } else {
                    LazyVStack(spacing: 2) { continuousPageContent(geometry: geometry) }
                        .scrollTargetLayout()
                        .background { scrollOriginReporter }
                }
            }
            .scrollDisabled(pageZoomed)
            .scrollTargetBehavior(ReaderSnappingBehavior(ranges: visiblePageFrames.compactMap { index, rect in
                guard pageSizes[index] != nil else { return nil }
                return rect.offsetBy(dx: -contentOrigin.x, dy: -contentOrigin.y)
            }, direction: direction, zoomed: pageZoomed))
            .coordinateSpace(name: "reader.canvas")
            .scrollPosition(id: $scrollPosition, anchor: readingAnchor)
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { _ in if !pageZoomed { scrollEndTask?.cancel(); userScrolling = true; draggingCanvas = true } }
                .onEnded { _ in draggingCanvas = false; finishScrollWhenStable() })
            .onPreferenceChange(ReaderContentOrigin.self) { origin in contentOrigin = origin; if userScrolling && !draggingCanvas { finishScrollWhenStable() } }
            .onPreferenceChange(ReaderPageFrames.self) { frames in visiblePageFrames = frames }
            .onChange(of: scrollPosition) { _, page in if userScrolling && !pageZoomed && !findingPage && !holdingPosition, let page { current = page; remember() } }
        }
    }

    private var scrollOriginReporter: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ReaderContentOrigin.self, value: geometry.frame(in: .named("reader.canvas")).origin)
        }
    }

    private func stopTrackingScroll() {
        scrollEndTask?.cancel(); scrollEndTask = nil; userScrolling = false; draggingCanvas = false
    }

    private func finishScrollWhenStable() {
        guard userScrolling, !draggingCanvas else { return }
        scrollEndTask?.cancel()
        scrollEndTask = Task {
            // Geometry keeps extending this window during inertial scrolling.
            // Once motion settles, later image-size updates cannot write history.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            userScrolling = false; scrollEndTask = nil
        }
    }

    @ViewBuilder private func continuousPageContent(geometry: GeometryProxy) -> some View {
        let ordered = direction.reverseOrder ? Array(model.pages.reversed()) : model.pages
        let expectedGeneration = session.generation
        let expectedOwner = library.owner
        let expectedContext = readingContext
        if direction.reverseOrder && model.next != nil { loadMorePagesButton }
        ForEach(ordered) { page in
            let extent = ReaderPageSizing.extent(imageSize: pageSizes[page.index], crossAxisExtent: direction.horizontal ? geometry.size.height : geometry.size.width, direction: direction)
            ReaderPage(page: page, active: abs(page.index - current) <= 1,
                       file: media.files[page.index], failure: media.failures[page.index],
                       loading: media.inflight[page.index] != nil, progress: media.progress[page.index], animated: page.index == current,
                       retry: { media.retry(page: page.index) }, onSingleTap: canvasTapped,
                       onZoomChanged: { zoomed in
                           guard page.index == self.current,
                                 let expectedContext, self.readingContext == expectedContext,
                                 expectedGeneration == session.generation, expectedOwner == library.owner,
                                 isCurrent(expectedContext) else { return }
                           pageZoomed = zoomed
                       },
                       onImageSizeChanged: { size in
                           guard let expectedContext, self.readingContext == expectedContext,
                                 expectedGeneration == session.generation, expectedOwner == library.owner,
                                 isCurrent(expectedContext) else { return }
                           pageSizes[page.index] = size
                       }, onPresentation: { value in
                           guard let expectedContext, isCurrent(expectedContext), media.files[page.index] == value.file else { return }
                           recordDecoded(page.index, file: value.file)
                       })
                .id("\(page.index):\(storedDirection)")
                .frame(width: direction.horizontal ? extent : geometry.size.width,
                       height: direction.horizontal ? geometry.size.height : extent)
                .background { GeometryReader { proxy in Color.clear.preference(key: ReaderPageFrames.self, value: [page.index: proxy.frame(in: .named("reader.canvas"))]) } }
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader.page.frame")
                .accessibilityValue(AppMode.qa ? "page \(page.index)" : "第 \(page.index) 页")
                .id(page.index)
        }
        if !direction.reverseOrder && model.next != nil { loadMorePagesButton }
        if model.loading { ProgressView().tint(.white).padding() }
    }

    private var loadMorePagesButton: some View {
        Button("继续加载后续页面") {
            Task { await loadNextPagesKeepingPosition() }
        }
        .disabled(model.loading)
        .padding(24).foregroundStyle(.white)
        .accessibilityIdentifier("reader.load-more")
    }

    private var singlePage: some View {
        GeometryReader { geometry in
            let travel = ReaderSlidePolicy.travel(direction: direction, forward: slideForward, size: geometry.size)
            let translation = singleDragActive ? singleDragOffset : (direction.horizontal ? travel.width : travel.height) * (1 - slideProgress)
            ZStack {
                Color.black
                // A page keeps its Canvas while its role changes from neighboring
                // preview to current. Position depends on page order, never on
                // the sign of an offset that is animating back to zero.
                ForEach(singlePageIndices, id: \.self) { index in
                    let offset = ReaderDragPolicy.pageOffset(index: index, current: current, direction: direction, size: geometry.size, translation: translation)
                    singlePageContent(index)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: offset.width, y: offset.height)
                        .allowsHitTesting(index == current && !singleDragActive)
                        .accessibilityHidden(index != current)
                }
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.single.canvas")
            .accessibilityValue(AppMode.qa ? "page \(current); \(singleDragActive ? "dragging" : (slideProgress < 1 ? "transitioning" : "settled")); reduced=\(motionReduced); lastDrag=\(lastDragEvidence); release=\(lastReleaseEvidence)" : "第 \(current) 页")
        }
    }

    private var singlePageIndices: [Int] {
        let last = max(current, model.total ?? model.pages.last?.index ?? (model.next == nil ? current : current + 1))
        return Array(max(1, current - 1)...min(last, current + 1))
    }

    @ViewBuilder private func singlePageContent(_ index: Int) -> some View {
        if let page = model.pages.first(where: { $0.index == index }) {
            pageCanvas(page)
        } else {
            ReaderLoadingPage(index: index, metadata: true,
                              failure: offline ? "离线副本中没有这一页。" : (index == current ? singleMetadataError : nil),
                              retry: offline || model.next == nil ? nil : { singleMetadataAttemptedTarget = nil; singleMetadataError = nil; updateMedia() })
        }
    }

    private func pageCanvas(_ page: GalleryPage) -> some View {
        let expected = readingContext
        return ReaderPage(page: page, active: true, file: media.files[page.index],
                          failure: media.failures[page.index], loading: media.inflight[page.index] != nil, progress: media.progress[page.index],
                          animated: page.index == current, retry: { media.retry(page: page.index) }, onSingleTap: canvasTapped, onZoomChanged: { value in
            guard page.index == current, let expected, isCurrent(expected) else { return }
            pageZoomed = value
        }, onImageSizeChanged: { size in
            guard let expected, isCurrent(expected), abs(page.index - current) <= 1 else { return }
            pageSizes[page.index] = size
        }, onPresentation: { value in
            guard let expected, isCurrent(expected), abs(page.index - current) <= 1,
                  media.files[page.index] == value.file else { return }
            presentations[page.index] = value
            recordDecoded(page.index, file: value.file)
        })
        .id("\(page.index):\(storedDirection)")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(media.files[page.index] == nil ? "reader.page.loading.\(page.index)" : "reader.page.frame")
    }

    private func recordDecoded(_ page: Int, file: URL) {
        guard ReaderNetworkMetrics.enabled, decodedFiles[page] != file else { return }
        decodedFiles[page] = file
        ReaderNetworkMetrics.record(UUID(), phase: "decoded", page: page)
    }

    private func displayPage(_ page: Int, animatedTurn: Bool) {
        cancelSingleDrag(updateDemand: false)
        let old = current
        slideTask?.cancel(); slideTask = nil; slideRevision = UUID()
        let animate = animatedTurn && mode == ReaderMode.singlePage.rawValue && !motionReduced && old != page
        slideForward = page > old
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { slideProgress = animate ? 0 : 1; current = page }
        updateMedia()
        guard animate, let context = readingContext else { return }
        let token = slideRevision
        slideTask = Task {
            await Task.yield()
            guard !Task.isCancelled, token == slideRevision, isCurrent(context), current == page else { return }
            withAnimation(.easeOut(duration: 0.22)) { slideProgress = 1 }
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled, token == slideRevision, isCurrent(context) else { return }
            slideTask = nil
            historyCheckpoint?.flush()
        }
    }

    private func cancelPageAnimation(updateDemand: Bool = true) {
        cancelSingleDrag(updateDemand: updateDemand)
        slideTask?.cancel(); slideTask = nil; slideRevision = UUID()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { slideProgress = 1 }
    }

    private var cacheDiagnostic: String {
        "current=\(current);prefetch=\(media.prefetchCount);files=\(media.files.keys.sorted().map(String.init).joined(separator: ","));tasks=\(media.inflight.count);metadataCalls=\(model.qaMetadataCalls);metadataTask=\(singleMetadataTask != nil);automaticMetadata=\(automaticMetadataTask != nil);metadataLoading=\(model.loading);decoded=\(decodedFiles.keys.sorted().map(String.init).joined(separator: ","));concurrency=\(downloadConcurrency);presentations=\(presentations.keys.sorted().map { "\($0):\(presentations[$0]!.canvasIdentity):\(presentations[$0]!.loadCount)" }.joined(separator: ","))"
    }

    private func updateMedia() {
        guard let context = readingContext, isCurrent(context) else { return }
        let scope = ReaderMediaScope(galleryID: gallery.id, owner: context.owner,
                                     generation: context.generation, context: context.id)
        media.update(scope: scope, pages: model.pages, current: current,
                     prefetchCount: prefetchCount, downloadConcurrency: downloadConcurrency, preview: singleDragPreview,
                     validateCachedFile: { FileManager.default.fileExists(atPath: $0.path) }, demandLoader: { page, demand in
            if AppMode.qa {
                if ProcessInfo.processInfo.arguments.contains("--qa-reader-prefetch-timeout"), page.index == 2, demand.priority == .prefetch {
                    throw RequestFailure.transport(.media, URLError.timedOut.rawValue)
                }
                let largeWindowFixture = ProcessInfo.processInfo.arguments.contains("--qa-reader-large-window")
                if (page.index > 1 || largeWindowFixture), let delay = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-transfer-ms=") })?.split(separator: "=").last.flatMap({ UInt64($0) }) {
                    if ProcessInfo.processInfo.arguments.contains("--qa-transfer-progress") {
                        demand.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: 25_000, totalBytes: 100_000))
                    }
                    try await Task.sleep(nanoseconds: min(delay, 15_000) * 1_000_000)
                }
                if ProcessInfo.processInfo.arguments.contains("--qa-media-delayed"), demand.priority == .prefetch {
                    try await Task.sleep(nanoseconds: 350_000_000)
                }
                return page.url
            }
            if offline { return page.url }
            return try await ReaderNetworkMetrics.measure(demand.id, phase: "pipeline", page: page.index) {
                try await PageMediaLoader.file(
                    resolvePage: {
                        demand.reportProgress(MediaLoadProgress(phase: .resolvingPage))
                        return try await ReaderNetworkMetrics.measure(demand.id, phase: "image-page", page: page.index) {
                            try EHParser.image(await session.html(page.url, recoverConnection: false, request: demand), base: page.url)
                        }
                    },
                    loadMedia: { try await MediaRepository.shared.file(for: $0, owner: context.owner, request: demand) },
                    isCurrent: { isCurrent(context) })
            }
        }, isCurrent: { isCurrent(context) })
        updatePinnedFiles(context)
        requestSingleMetadataIfNeeded(context)
        requestNextMetadataIfNeeded(context)
    }

    private func updatePinnedFiles(_ context: ReadingContext) {
        guard isCurrent(context) else { return }
        let files = Set(media.files.filter { abs($0.key - current) <= 1 }.map(\.value))
        MediaRepository.shared.setPinnedFiles(files, owner: context.owner, context: context.id)
    }

    private func requestNextMetadataIfNeeded(_ context: ReadingContext) {
        guard !offline, prefetchCount > 0, !media.prefetchPaused, !findingPage, !model.loading, model.error == nil,
              automaticMetadataTask == nil, singleMetadataTask == nil,
              let cursor = model.next, cursor != automaticMetadataCursor,
              let last = model.pages.last?.index, last - current <= prefetchCount + 1 else { return }
        automaticMetadataCursor = cursor
        let revision = UUID(); automaticMetadataRevision = revision
        automaticMetadataTask = Task {
            await loadNextPagesKeepingPosition(priority: .prefetch)
            guard automaticMetadataRevision == revision, isCurrent(context), !Task.isCancelled else { return }
            automaticMetadataTask = nil
            updateMedia()
        }
    }

    private var neededSingleMetadataTarget: Int? {
        guard mode == ReaderMode.singlePage.rawValue else { return nil }
        if !model.pages.contains(where: { $0.index == current }) { return current }
        if let target = singleDragPreview, !model.pages.contains(where: { $0.index == target }) { return target }
        return nil
    }

    private func requestSingleMetadataIfNeeded(_ context: ReadingContext) {
        let target = neededSingleMetadataTarget
        if target != nil { model.promotePendingMetadata() }
        if target != singleMetadataAttemptedTarget {
            singleMetadataRevision = UUID(); singleMetadataTask?.cancel(); singleMetadataTask = nil
            singleMetadataAttemptedTarget = nil; singleMetadataError = nil
        }
        guard !offline, let target, singleMetadataTask == nil, !model.loading,
              singleMetadataAttemptedTarget != target else { return }
        guard model.next != nil else {
            if !model.pages.isEmpty { singleMetadataError = "未能取得第 \(target) 页的页面信息。" }
            return
        }
        singleMetadataAttemptedTarget = target
        let revision = UUID(); singleMetadataRevision = revision
        singleMetadataTask = Task {
            var attempts = 0
            while !model.pages.contains(where: { $0.index == target }), model.next != nil, attempts < 100 {
                guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision,
                      neededSingleMetadataTarget == target else { return }
                if model.loading { try? await Task.sleep(nanoseconds: 20_000_000); continue }
                let count = model.pages.count, cursor = model.next
                attempts += 1
                await model.more(gallery: gallery, session: session, library: library)
                guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision,
                      neededSingleMetadataTarget == target || model.pages.contains(where: { $0.index == target }) else { return }
                if model.pages.contains(where: { $0.index == target }) { break }
                if model.error != nil || model.pages.count == count || model.next == cursor {
                    singleMetadataError = model.error ?? "未能取得第 \(target) 页的页面信息，请重试。"
                    break
                }
            }
            guard !Task.isCancelled, isCurrent(context), singleMetadataRevision == revision else { return }
            singleMetadataTask = nil
            if model.pages.contains(where: { $0.index == target }) { singleMetadataError = nil; remember() }
            else if singleMetadataError == nil { singleMetadataError = "未能取得第 \(target) 页的页面信息，请重试。" }
            updateMedia()
        }
    }

    private func edgeControls(size: CGSize) -> some View {
        Group {
            if direction.horizontal {
                HStack(spacing: 0) {
                    edgeButton(forward: direction == .rightToLeft, width: size.width * 0.24, height: size.height, alignment: .leading)
                    Spacer(minLength: 0)
                    edgeButton(forward: direction == .leftToRight, width: size.width * 0.24, height: size.height, alignment: .trailing)
                }.frame(width: size.width, height: size.height)
            } else {
                VStack(spacing: 0) {
                    edgeButton(forward: direction == .bottomToTop, width: size.width, height: size.height * 0.22, alignment: .top)
                    Spacer(minLength: 0)
                    edgeButton(forward: direction == .topToBottom, width: size.width, height: size.height * 0.22, alignment: .bottom)
                }.frame(width: size.width, height: size.height)
            }
        }
    }

    private func edgeButton(forward: Bool, width: CGFloat, height: CGFloat, alignment: Alignment) -> some View {
        Button { if !pageZoomed { changePage(by: forward ? 1 : -1) } } label: {
            Image(systemName: forward ? direction.forwardSymbol : direction.backwardSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .frame(width: width, height: height, alignment: alignment)
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "下一页，\(direction.title)" : "上一页，\(direction.title)")
        .accessibilityIdentifier(forward ? "reader.next" : "reader.previous")
    }

    private var readerControls: some View {
        ViewThatFits(in: .horizontal) {
            readerControlRow(includeBookmark: true)
            readerControlRow(includeBookmark: false)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.controls.compact")
    }

    private func readerControlRow(includeBookmark: Bool) -> some View {
        HStack(spacing: 0) {
            Menu {
                Button { mode = ReaderMode.continuous.rawValue; scrollPosition = current } label: {
                    Label("连续模式", systemImage: mode == ReaderMode.continuous.rawValue ? "checkmark" : "rectangle.split.1x2")
                }
                Button { mode = ReaderMode.singlePage.rawValue } label: {
                    Label("单页模式", systemImage: mode == ReaderMode.singlePage.rawValue ? "checkmark" : "book")
                }
            } label: {
                Image(systemName: mode == ReaderMode.continuous.rawValue ? "rectangle.split.1x2" : "book")
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("阅读方式").accessibilityIdentifier("reader.mode")

            Menu {
                ForEach(ReaderDirection.allCases) { item in
                    Button { direction = item } label: {
                        Label(item.menuTitle, systemImage: direction == item ? "checkmark" : item.forwardSymbol)
                    }
                }
            } label: {
                Image(systemName: direction.forwardSymbol).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("翻页方向，当前 \(direction.menuTitle)").accessibilityIdentifier("reader.direction")

            if let total = model.total, total > 0 {
                Slider(value: $progressTarget, in: 1...Double(max(1, total))) { editing in
                    if editing { progressRevision = UUID(); progressHUD = true }
                    else {
                        let target = Int(progressTarget.rounded()), token = progressRevision
                        Task { await seek(target); if progressRevision == token { progressHUD = false } }
                    }
                }
                .frame(minWidth: 56, maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("阅读进度")
                .accessibilityValue("第 \(current) 页，共 \(total) 页")
                .accessibilityIdentifier("reader.progress")
            }
            Button { jumpText = String(current); jump = true } label: {
                Text("\(current) / \(model.total.map(String.init) ?? "未知")")
                    .font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(.white).frame(minWidth: 66, maxWidth: 90, minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("reader.page")
            Button { settings = true } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("阅读设置").accessibilityIdentifier("reader.settings")
            if includeBookmark {
                Button { library.bookmark(gallery) } label: {
                    Image(systemName: library.snapshot.bookmarks.contains(where: { $0.id == gallery.id }) ? "bookmark.fill" : "bookmark")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("本机书签").accessibilityIdentifier("reader.bookmark")
            }
        }.font(.system(size: 18, weight: .medium))
    }

    private var readerSettings: some View {
        NavigationStack {
            Form {
                Section("阅读方式") {
                    Picker("布局", selection: $mode) {
                        Text("连续模式").tag(ReaderMode.continuous.rawValue)
                        Text("单页模式").tag(ReaderMode.singlePage.rawValue)
                    }.pickerStyle(.segmented).accessibilityIdentifier("reader.settings.mode")
                }
                Section("翻页方向") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(ReaderDirection.allCases) { item in
                            Button { direction = item } label: {
                                HStack(spacing: 8) { Text(item.arrow).font(.body.weight(.semibold)); Text(item.title).font(.subheadline); Spacer(minLength: 0) }
                                    .foregroundStyle(direction == item ? Color.accentColor : Color.primary)
                                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                                    .background(direction == item ? Color.accentColor.opacity(0.1) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(direction == item ? "已选择" : "未选择")
                                .accessibilityIdentifier("reader.settings.direction.\(item.rawValue)")
                        }
                    }
                }
                Section {
                    Button { library.bookmark(gallery) } label: {
                        Label(library.snapshot.bookmarks.contains(where: { $0.id == gallery.id }) ? "移除本机书签" : "加入本机书签", systemImage: "bookmark")
                    }
                }
                Section { Text("连续模式和单页模式均可按所选方向阅读。单页模式可点按边缘或滑动翻页；动图按一页自动播放，双击图片缩放。")
                    .font(.caption).foregroundStyle(.secondary) }
            }
            .listSectionSpacing(16)
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar { AppToolbarItem(placement: .confirmationAction, tone: .accent) { Button("完成") { settings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(FloatingChrome.controlFill, in: RoundedRectangle(cornerRadius: 10))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("reader.close")
    }

    private func canvasTapped(_ point: CGPoint) {
        guard !pageZoomed, !singleDragActive, Date() >= ignoreCanvasTapUntil,
              let context = readingContext, isCurrent(context), viewportFrame.width > 0 else { return }
        let x = (point.x - viewportFrame.minX) / viewportFrame.width
        let y = (point.y - viewportFrame.minY) / viewportFrame.height
        if (0.28...0.72).contains(x) && (0.24...0.76).contains(y) { settings = true }
    }

    private func updateViewportFrame(_ frame: CGRect) {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        if viewportFrame.size != frame.size { cancelPageAnimation() }
        viewportFrame = frame
    }

    private func singleDragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($singleFingerDown) { _, down, _ in down = true }
            .onChanged { value in
                guard mode == ReaderMode.singlePage.rawValue, !pageZoomed,
                      let context = readingContext, isCurrent(context) else { return }
                if singleDragFinishing { cancelPageAnimation(updateDemand: false) }
                let raw = direction.horizontal ? value.translation.width : value.translation.height
                let cross = direction.horizontal ? value.translation.height : value.translation.width
                let extent = direction.horizontal ? size.width : size.height
                guard extent.isFinite, extent > 0 else { return }
                guard singleDragActive || abs(raw) > max(8, abs(cross)) else { return }
                if !singleDragActive {
                    cancelPageAnimation(updateDemand: false); seekRevision = UUID(); findingPage = false
                    singleDragExtent = extent
                    singleDragActive = true
                }
                ignoreCanvasTapUntil = Date().addingTimeInterval(0.45)
                let target = current + ReaderDragPolicy.pageDelta(offset: raw, direction: direction)
                let valid = target > 0 && (model.total.map { target <= $0 } ?? (model.pages.contains { $0.index == target } || model.next != nil))
                let preview = valid ? target : nil
                let changed = preview != singleDragPreview
                singleDragPreview = preview
                singleDragOffset = ReaderDragPolicy.boundedOffset(raw, extent: singleDragExtent, hasNeighbor: valid)
                if changed {
                    updateMedia()
                }
                if AppMode.qa, let preview {
                    lastDragEvidence = "\(current)+\(preview);offset=\(Int(abs(singleDragOffset)));neighborFile=\(media.files[preview] != nil)"
                }
            }
            .onEnded { value in
                guard singleDragActive, !pageZoomed else { return }
                let raw = direction.horizontal ? value.translation.width : value.translation.height
                let predicted = direction.horizontal ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                let extent = direction.horizontal ? size.width : size.height
                finishSingleDrag(commit: singleDragPreview != nil && ReaderDragPolicy.commits(offset: raw, predicted: predicted, extent: extent))
            }
    }

    private func finishSingleDrag(commit: Bool) {
        guard singleDragActive, !singleDragFinishing, let context = readingContext, isCurrent(context) else { return }
        guard singleDragExtent.isFinite, singleDragExtent > 0 else { cancelSingleDrag(); return }
        singleDragFinishing = true
        ignoreCanvasTapUntil = Date().addingTimeInterval(0.4)
        let target = commit ? singleDragPreview : nil
        let oldPage = current
        if target != nil { seekRevision = UUID(); findingPage = false }
        let intent = seekRevision
        let releaseDirection = storedDirection
        // Use the exact geometry that handled the finger, including a pending
        // slow target. Preferences across NavigationStack can read as zero.
        let extent = singleDragExtent
        if AppMode.qa {
            lastReleaseEvidence = "commit=\(commit),target=\(target ?? 0),extent=\(extent),from=\(singleDragOffset),fileReady=\(target.map { media.files[$0] != nil } ?? false)"
        }
        let revision = UUID(); singleDragRevision = revision
        if let target {
            let offset = ReaderDragPolicy.pageOffset(index: target, current: oldPage, direction: direction,
                                                     size: CGSize(width: extent, height: extent), translation: singleDragOffset)
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                current = target; scrollPosition = target; progressTarget = Double(target)
                singleDragPreview = nil
                singleDragOffset = direction.horizontal ? offset.width : offset.height
            }
            remember()
            updateMedia()
        }
        withAnimation(motionReduced ? nil : .easeOut(duration: 0.18), completionCriteria: .removed) {
            singleDragOffset = 0
        } completion: {
            guard singleDragRevision == revision, singleDragFinishing,
                  isCurrent(context), seekRevision == intent,
                  mode == ReaderMode.singlePage.rawValue, storedDirection == releaseDirection else { return }
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                singleDragActive = false; singleDragFinishing = false; singleDragOffset = 0
                singleDragPreview = nil; singleDragExtent = 0
            }
            historyCheckpoint?.flush()
            updateMedia()
        }
    }

    private func cancelSingleDrag(updateDemand: Bool = true) {
        let hadPreview = singleDragActive || singleDragPreview != nil
        singleDragRevision = UUID(); singleDragExtent = 0
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { singleDragActive = false; singleDragFinishing = false; singleDragOffset = 0; singleDragPreview = nil }
        if updateDemand { historyCheckpoint?.finishMotion(fingerDown: singleFingerDown) }
        if hadPreview && updateDemand { updateMedia() }
    }

    private func changePage(by offset: Int) {
        guard offset != 0 else { return }
        Task {
            let target = max(1, current + offset)
            guard model.total == nil || target <= (model.total ?? target) else { return }
            await seek(target, animatedTurn: true)
            if mode != ReaderMode.singlePage.rawValue, target >= (model.pages.last?.index ?? 0) - 2, let context = readingContext, isCurrent(context) {
                await loadNextPagesKeepingPosition()
            }
        }
    }

    private func isCurrent(_ context: ReadingContext) -> Bool {
        readingContext == context && context.generation == session.generation && context.owner == library.owner
    }
    private func remember() {
        guard let context = readingContext, isCurrent(context), current > 0,
              model.total.map({ current <= $0 }) ?? model.pages.contains(where: { $0.index == current }) else { return }
        if singleDragActive || singleDragFinishing || slideTask != nil, let historyCheckpoint {
            historyCheckpoint.stage(current)
        } else {
            historyCheckpoint?.discard()
            library.remember(gallery, page: current)
        }
    }
    private func loadNextPagesKeepingPosition(priority: MediaRequestPriority = .foreground) async {
        guard let context = readingContext, isCurrent(context), !holdingPosition else { return }
        let startedIntent = seekRevision
        var page: Int?
        defer { holdingPosition = false }
        await model.more(gallery: gallery, session: session, library: library, priority: priority, beforeAppending: {
            // Keep accepting scrolling and seeks while I/O is pending. Pin the
            // user's latest page only for the actual layout mutation.
            page = current; holdingPosition = true
        })
        guard !Task.isCancelled, isCurrent(context), let page else { return }
        if mode == ReaderMode.singlePage.rawValue { return }
        // A pending jump can still have the old current page while it waits for
        // metadata. Internal layout repair must not replace that newer intent.
        if seekRevision == startedIntent { await seek(page, expectedIntent: startedIntent) }
        else if !findingPage { await seek(current, expectedIntent: seekRevision) }
    }
    private func seek(_ page: Int, animatedTurn: Bool = false, expectedIntent: UUID? = nil) async {
        guard let context = readingContext, isCurrent(context), !Task.isCancelled,
              page > 0, page <= (model.total ?? 2000) else { return }
        if let expectedIntent, expectedIntent != seekRevision { return }
        cancelSingleDrag(updateDemand: false)
        let intent = expectedIntent ?? UUID(); seekRevision = intent
        stopTrackingScroll()
        if mode == ReaderMode.singlePage.rawValue {
            findingPage = false
            displayPage(page, animatedTurn: animatedTurn)
            scrollPosition = page; progressTarget = Double(page); remember()
            updateMedia()
            return
        }
        findingPage = true; defer { if seekRevision == intent { findingPage = false } }
        var count = 0
        while !model.pages.contains(where: { $0.index == page }), model.next != nil, model.error == nil, count < 100 {
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            if model.loading { try? await Task.sleep(nanoseconds: 20_000_000); continue }
            count += 1; await model.more(gallery: gallery, session: session, library: library)
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
        }
        guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
        if model.pages.contains(where: { $0.index == page }) {
            displayPage(page, animatedTurn: animatedTurn); scrollPosition = nil
            await Task.yield()
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            scrollPosition = page
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, isCurrent(context), seekRevision == intent else { return }
            current = page; progressTarget = Double(page); remember()
        }
    }
}

struct ReaderPage: View {
    var page: GalleryPage
    var active: Bool
    var file: URL?
    var failure: Error?
    var loading: Bool
    var progress: MediaLoadProgress? = nil
    var animated: Bool
    var retry: () -> Void
    var onSingleTap: ((CGPoint) -> Void)? = nil
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onImageSizeChanged: ((CGSize) -> Void)? = nil
    var onPresentation: ((ImageCanvasPresentation) -> Void)? = nil
    var body: some View {
        ZStack {
            Color.black
            if active, let file {
                MediaCanvas(file: file, animated: animated, onZoomChanged: onZoomChanged,
                            onImageSizeChanged: onImageSizeChanged, onSingleTap: onSingleTap, onPresentation: onPresentation)
            } else if active, let failure {
                ReaderLoadingPage(index: page.index, failure: ErrorMessages.message(failure), retry: retry)
            } else if active { ReaderLoadingPage(index: page.index, progress: progress) }
            else { Text("第 \(page.index) 页").font(.caption).foregroundStyle(.white.opacity(0.4)) }
        }
        .onChange(of: active) { _, value in if !value { onZoomChanged?(false) } }
        .onChange(of: file) { _, _ in onZoomChanged?(false) }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { value in
            if active, file == nil, failure == nil { onSingleTap?(value.location) }
        })
    }
}

struct GalleryDetailView: View {
    var gallery: Gallery
    var onSearchTag: (GalleryTag, GallerySite) -> Void
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var coverAspect = CoverAspectCache.shared
    @State private var detail: GalleryDetail?
    @State private var failure: String?
    @State private var loading = false
    @State private var reader = false
    @State private var web: WebDestination?
    @State private var lastBlocked: GalleryTag?
    private var current: Gallery {
        guard var resolved = detail?.gallery else { return gallery }
        if resolved.cover == nil { resolved.cover = gallery.cover }
        if resolved.title.isEmpty { resolved.title = gallery.title }
        if resolved.category.isEmpty { resolved.category = gallery.category }
        if resolved.uploader.isEmpty { resolved.uploader = gallery.uploader }
        if resolved.pages == nil { resolved.pages = gallery.pages }
        if resolved.rating == nil { resolved.rating = gallery.rating }
        if resolved.tags.isEmpty { resolved.tags = gallery.tags; resolved.tagsComplete = gallery.tagsComplete }
        return resolved
    }
    private var favoriteStatus: String {
        if loading { return "读取中…" }
        if failure != nil { return "读取失败" }
        guard let detail else { return "尚未读取" }
        if let name = detail.favoriteName { return "已收藏 · \(name)" }
        return "未收藏"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    let ratio = coverAspect.aspect(for: current)
                    CoverView(gallery: current).frame(width: min(108, 160 * ratio), height: min(160, 108 / ratio)).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 10) {
                        if !current.category.isEmpty { Text(current.category).font(.subheadline.weight(.medium)).foregroundStyle(.primary) }
                        Text(current.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if current.pages != nil || current.rating != nil {
                            HStack(spacing: 12) {
                                if let pages = current.pages { Text("\(pages) 页") }
                                if let rating = current.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                            }.font(.subheadline).foregroundStyle(.primary)
                        }
                        let artists = current.tags.filter { $0.namespace == "artist" }.map(\.name)
                        if !artists.isEmpty { Text("作者 · \(artists.joined(separator: "、"))").font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true) }
                        if !current.uploader.isEmpty { Text("上传者 · \(current.uploader)").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                HStack(spacing: 10) {
                    Button { reader = true } label: { Label(library.snapshot.history.contains(where: { $0.id == gallery.id }) ? "继续阅读" : "在线阅读", systemImage: "book").frame(maxWidth: .infinity, minHeight: 28) }.buttonStyle(AppActionButtonStyle(tone: .accent)).controlSize(.regular).disabled(detail == nil && !AppMode.qa)
                    Button { library.bookmark(current) } label: { Image(systemName: library.snapshot.bookmarks.contains(where: { $0.id == gallery.id }) ? "bookmark.fill" : "bookmark").font(.body).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("本机书签")
                    Button { downloads.enqueue(current) } label: { Image(systemName: "arrow.down").font(.body).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("下载当前画质").disabled(detail == nil || AppMode.qa)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("detail.actions")
                if loading { ProgressView() }
                if let failure { StatusMessage(title: failure) { Task { await load() } } }
                Divider()
                HStack {
                    Text("站点收藏")
                    Spacer()
                    Text(favoriteStatus).font(.caption).foregroundStyle(.secondary)
                    Button("管理") { var components = URLComponents(url: current.ref.site.baseURL.appendingPathComponent("gallerypopups.php"), resolvingAgainstBaseURL: false)!; components.queryItems = [.init(name: "gid", value: String(current.ref.gid)), .init(name: "t", value: current.ref.token), .init(name: "act", value: "addfav")]; web = .init(title: "管理站点收藏", url: components.url!) }.disabled(AppMode.qa)
                }.font(.subheadline)
                if let lastBlocked { HStack { Text("已屏蔽 \(lastBlocked.name)").font(.caption); Spacer(); Button("撤销") { library.unblock(lastBlocked); self.lastBlocked = nil } }.font(.caption) }
                if !current.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("标签").font(.headline)
                        Text("点按用于组合搜索，长按加入常用或屏蔽。").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(Set(current.tags.map(\.namespace))).sorted(), id: \.self) { namespace in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(namespace.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                TagWrapLayout(spacing: 7) {
                                    ForEach(current.tags.filter { $0.namespace == namespace }) { tag in
                                        Button { onSearchTag(tag, current.ref.site) } label: { Text(tag.name).font(.subheadline).padding(.horizontal, 11).padding(.vertical, 8).background(Color(uiColor: .secondarySystemFill), in: Capsule()) }
                                            .contextMenu { Button("加入常用标签") { library.pin(tag) }; Button("屏蔽标签") { library.block(tag); lastBlocked = tag }; if library.blockedIDs.contains(tag.id) { Button("解除屏蔽") { library.unblock(tag) } } }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("打开站点原网页") { web = .init(title: "画廊原网页", url: current.ref.url) }.disabled(AppMode.qa)
                if let archive = detail?.archive { Button("归档下载与费用") { web = .init(title: "归档下载", url: archive) } }
                Text("当前画质下载会使用看图额度。归档价格和免费配额以站点当前账号页面为准。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }.navigationTitle("画廊详情").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
            .task { await load() }
            .accessibilityHidden(reader)
            .fullScreenCover(isPresented: $reader) { ReaderView(gallery: current) }
            .sheet(item: $web, onDismiss: { Task { await load() } }) { OfficialWebView(destination: $0) }
    }
    private func load() async {
        if AppMode.qa { detail = QASamples.detail(gallery); return }
        let revision = session.generation
        loading = true; defer { loading = false }
        do { let value = try EHParser.detail(await session.html(gallery.ref.url), reference: gallery.ref); guard revision == session.generation else { return }; detail = value; failure = nil }
        catch { guard revision == session.generation else { return }; failure = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription) }
    }
}

struct TagWrapLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { positions(width: proposal.width ?? 320, subviews: subviews).1 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { let points = positions(width: bounds.width, subviews: subviews).0; for (i, point) in points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified) } }
    private func positions(width: CGFloat, subviews: Subviews) -> ([CGPoint], CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0; var points: [CGPoint] = []
        for subview in subviews { let size = subview.sizeThatFits(.unspecified); if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }; points.append(CGPoint(x: x, y: y)); x += size.width + spacing; height = max(height, size.height) }
        return (points, CGSize(width: width, height: y + height))
    }
}
