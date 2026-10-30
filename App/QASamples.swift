import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ExViewerCore

enum QASamples {
    @MainActor static func installOfflineSample(in library: LibraryStore) {
        guard AppMode.qa else { return }
        let gallery = galleries[0]
        let directory = library.offlineDirectory(gallery)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var completed: [Int: String] = [:]
            for page in pages {
                let name = "page-\(page.index).media"
                let target = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: page.url, to: target) }
                completed[page.index] = name
            }
            library.updateDownload(.init(gallery: gallery, status: .complete, completed: completed, total: completed.count))
        } catch { assertionFailure("Could not install neutral offline QA fixture") }
    }

    static var favoriteGroupName: String {
        guard AppMode.qa else { return "已读" }
        let prefix = "--qa-favorite-group="
        return ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count).prefix(200)) } ?? "已读"
    }
    static var sortingLibrary: LibrarySnapshot {
        let names = ["Beta 10", "Alpha 2", "Alpha 10", "Never Read"]
        let values = names.enumerated().map { index, title -> Gallery in
            var value = galleries[index]; value.title = title; value.ref.gid = Int64(7201 + index)
            value.cover = cover(seed: index + 1); return value
        }
        var result = LibrarySnapshot()
        result.favoriteTags = [.init(namespace: "language", name: "english")]
        result.history = [0, 2, 1].map { index in
            .init(gallery: values[index], page: index + 1, date: Date(timeIntervalSince1970: Double((index == 2 ? 3 : index + 1) * 100)))
        }
        result.bookmarks = [0, 3, 2, 1].map { values[$0] }
        result.downloads = [3, 1, 0, 2].map { .init(gallery: values[$0], status: .paused, total: 10) }
        return result
    }
    static var galleries: [Gallery] {
        ["海岸线 · 插画与速写", "日常风景记录 / FIELD NOTES", "色彩与形状 · 动图习作", "城市散步手记"].enumerated().map { index, title in
            var gallery = Gallery(ref: .init(site: .ex, gid: Int64(index + 1), token: "preview"), title: title, category: "Non-H", uploader: "Preview Studio", pages: 3, rating: 4.75, tags: [.init(namespace: "language", name: "chinese"), .init(namespace: "other", name: "full color"), .init(namespace: "artist", name: "preview studio")]); gallery.tagsComplete = true
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-layout-cases") {
                if index == 0 { gallery.title = "短标题" }
                if index == 1 { gallery.title = "这是一条需要换行并且超过两行的中性画廊标题用于验证标题自然高度与截断" }
                if index == 2 { gallery.title = "缺少元数据"; gallery.category = ""; gallery.pages = nil }
            }
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reader-many") { gallery.pages = 12 }
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-stored-bookmark-covers") { gallery.cover = cover(seed: index + 1) }
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-rating-filter") { gallery.rating = [2.8, 2.9, 3.0, 4.75][index] }
            return gallery
        }
    }
    static func detail(_ gallery: Gallery) -> GalleryDetail {
        let archive = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-detail-actions") ? GallerySite.ex.baseURL.appendingPathComponent("archiver.php") : nil
        let favorite = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorite-existing") ? favoriteGroupName : nil
        return GalleryDetail(gallery: gallery, pages: pages, next: nil, archive: archive, favoriteName: favorite)
    }
    static var additionalGalleries: [Gallery] {
        Array(galleries.prefix(2)).enumerated().map { index, source in
            var gallery = source; gallery.ref.gid += 100; gallery.title = index == 0 ? "第二批 · 山间笔记" : "第二批 · 色彩练习"; return gallery
        }
    }
    static var feedGalleries: [Gallery] {
        if AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-feed-performance") {
            return (0..<1000).map { index in
                var gallery = galleries[index % 4]
                gallery.ref.gid = Int64(20000 + index); gallery.title = "浏览性能样例 \(index + 1)"
                gallery.cover = cover(seed: index % 4 + 1)
                return gallery
            }
        }
        guard AppMode.qa, ProcessInfo.processInfo.arguments.contains("--qa-feed-paging") else { return galleries }
        return galleries + (4..<12).map { index in
            var gallery = galleries[index % 4]
            gallery.ref.gid = Int64(200 + index)
            gallery.title = "浏览样例 · \(index + 1)"
            return gallery
        }
    }
    static var pages: [GalleryPage] {
        let count = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reader-many") ? 12 : 3
        return (1...count).map { GalleryPage(index: $0, url: image(index: $0)) }
    }
    static func cover(seed: Int) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-neutral-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cover-aspect-\(seed).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let size = seed.isMultiple(of: 2) ? CGSize(width: 720, height: 480) : CGSize(width: 480, height: 680)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGray5.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemGray3.setFill(); context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.12, y: size.height * 0.1, width: size.width * 0.45, height: size.width * 0.45))
            UIColor.systemGray.setFill(); context.fill(CGRect(x: 0, y: size.height * 0.65, width: size.width, height: size.height * 0.35))
            "NEUTRAL STUDY".draw(at: CGPoint(x: 28, y: size.height * 0.76), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.white])
        }
        try? image.pngData()?.write(to: file, options: .atomic)
        return file
    }
    static func image(index: Int) -> URL {
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reader-transition") {
            return transitionImage(index: index)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-neutral-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let longPage = AppMode.qa && index == 2 && ProcessInfo.processInfo.arguments.contains("--qa-reader-long-page")
        let file = directory.appendingPathComponent(index == 1 ? "moving-shape.gif" : longPage ? "reader-v9-long-2.png" : "reader-v8-page-\(index).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let count = index == 1 ? 12 : 1
        let type = index == 1 ? UTType.gif.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type as CFString, count, nil) else { return file }
        if count > 1 { CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
        for frame in 0..<count {
            let size = longPage ? CGSize(width: 720, height: 2160) : index == 2 ? CGSize(width: 720, height: 360) : index == 3 ? CGSize(width: 512, height: 512) : CGSize(width: 512, height: 720)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                UIColor(red: 0.89, green: 0.88, blue: 0.82, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                UIColor(red: 0.26, green: 0.45, blue: 0.43, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45))
                UIColor(red: 0.76, green: 0.45, blue: 0.3, alpha: 1).setFill(); context.cgContext.fillEllipse(in: CGRect(x: 45 + frame * 24, y: 110, width: 110, height: 110))
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 35, weight: .light), .foregroundColor: UIColor.white]
                (count > 1 ? "MOTION STUDY" : "FIELD NOTES").draw(at: CGPoint(x: 36, y: size.height * 0.68), withAttributes: attrs)
                "NEUTRAL READER FIXTURE".draw(at: CGPoint(x: 36, y: size.height * 0.81), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.white.withAlphaComponent(0.6)])
            }
            if let cg = image.cgImage { CGImageDestinationAddImage(destination, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary) }
        }
        CGImageDestinationFinalize(destination); return file
    }
    private static func transitionImage(index: Int) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-neutral-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reader-v11-page-\(index).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let size = CGSize(width: 720, height: 1040)
        let colors: [UIColor] = [UIColor(red: 0.88, green: 0.68, blue: 0.32, alpha: 1),
                                 UIColor(red: 0.28, green: 0.72, blue: 0.72, alpha: 1),
                                 UIColor(red: 0.72, green: 0.48, blue: 0.72, alpha: 1)]
        let image = UIGraphicsImageRenderer(size: size).image { context in
            colors[(index - 1) % colors.count].setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.25).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: size.height))
            "PAGE \(index)".draw(at: CGPoint(x: 100, y: 400), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 100, weight: .bold), .foregroundColor: UIColor.white])
            "LOCAL TRANSITION FIXTURE".draw(at: CGPoint(x: 100, y: 570), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 24, weight: .medium), .foregroundColor: UIColor.white])
        }
        try? image.pngData()?.write(to: file, options: .atomic)
        return file
    }
}
struct QACover: View {
    var seed: Int
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(red: 0.88, green: 0.87, blue: 0.8)
                Rectangle().fill(Palette.accent).frame(height: geometry.size.height * 0.42).frame(maxHeight: .infinity, alignment: .bottom)
                Circle().fill(Color(red: 0.75, green: 0.44, blue: 0.30)).frame(width: geometry.size.width * 0.55).offset(x: geometry.size.width * 0.15, y: geometry.size.height * 0.15)
                Text(seed % 2 == 0 ? "FIELD\nNOTES" : "COAST\nLINES").font(.system(size: geometry.size.width * 0.14, weight: .light, design: .serif)).foregroundStyle(.white).padding(geometry.size.width * 0.12).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}
