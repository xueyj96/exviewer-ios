import Foundation
import ExViewerCore

@MainActor final class DownloadManager: ObservableObject {
    @Published private(set) var running: String?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let session: SiteSession
    private let library: LibraryStore
    init(session: SiteSession, library: LibraryStore) { self.session = session; self.library = library }
    func enqueue(_ gallery: Gallery) {
        guard library.error == nil else { return }
        if let record = library.snapshot.downloads.first(where: { $0.id == gallery.id }), record.status == .complete { return }
        let completed = library.snapshot.downloads.first(where: { $0.id == gallery.id })?.completed ?? [:]
        library.updateDownload(.init(gallery: gallery.stored, status: .waiting, completed: completed, total: gallery.pages))
        if running == nil { startNext() }
    }
    func pauseAll() {
        runID = UUID()
        task?.cancel(); task = nil
        if let id = running, var record = library.snapshot.downloads.first(where: { $0.id == id }) { record.status = .paused; library.updateDownload(record) }
        running = nil
    }
    private func startNext() {
        guard library.error == nil, running == nil, let record = library.snapshot.downloads.first(where: { $0.status == .waiting }) else { return }
        running = record.id
        let run = UUID(); runID = run
        let revision = session.generation, owner = library.owner
        let directory = library.offlineDirectory(record.gallery)
        task = Task {
            guard !Task.isCancelled, runID == run, revision == session.generation, owner == library.owner else { return }
            var current = record; current.status = .downloading; current.error = nil; library.updateDownload(current)
            do {
                guard library.error == nil else { throw ViewerError.storage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var cursor: URL? = record.gallery.ref.url
                var seen = Set<URL>()
                while let url = cursor {
                    try Task.checkCancellation()
                    guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                    guard seen.insert(url).inserted, seen.count <= 100 else { throw ViewerError.layoutChanged }
                    let detail = try EHParser.detail(await session.html(url), reference: record.gallery.ref, pageURL: url)
                    try Task.checkCancellation()
                    guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                    current.total = detail.gallery.pages
                    for page in detail.pages {
                        try Task.checkCancellation()
                        guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                        let name = "page-\(page.index).media"
                        let destination = directory.appendingPathComponent(name)
                        let alreadySaved = await MediaRepository.shared.hasValidManualFile(at: destination)
                        try Task.checkCancellation()
                        guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                        if alreadySaved {
                            current.completed[page.index] = name
                            library.updateDownload(current)
                            if library.error != nil { throw ViewerError.storage }
                            continue
                        }
                        if let remaining = session.quota.remaining, remaining == 0 { throw ViewerError.imageLimit }
                        let source = try EHParser.image(await session.html(page.url), base: page.url)
                        try Task.checkCancellation()
                        guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                        _ = try await MediaRepository.shared.saveManual(url: source.url, destination: destination)
                        try Task.checkCancellation()
                        guard runID == run, revision == session.generation, owner == library.owner else { throw ViewerError.stale }
                        current.completed[page.index] = name; library.updateDownload(current)
                        if library.error != nil { throw ViewerError.storage }
                        try await Task.sleep(nanoseconds: 750_000_000)
                    }
                    cursor = detail.next
                }
                guard let total = current.total, current.completed.count == total else { throw ViewerError.layoutChanged }
                current.status = .complete
            } catch is CancellationError { current.status = .paused }
            catch {
                current.status = .paused
                let fileError = (error as NSError).domain == NSCocoaErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain
                current.error = ErrorMessages.message(error, fallback: (fileError ? ViewerError.storage : ViewerError.network).localizedDescription)
            }
            guard revision == session.generation, owner == library.owner, runID == run else { return }
            library.updateDownload(current); running = nil; task = nil
            if current.status == .complete && library.error == nil { startNext() }
        }
    }
}
