import Foundation

public enum GalleryMetadata {
    private struct Response: Decodable { var gmetadata: [Entry] }
    private struct Entry: Decodable {
        var gid: Int64
        var title: String?
        var title_jpn: String?
        var category: String?
        var uploader: String?
        var filecount: String?
        var rating: String?
        var tags: [String]?
        var thumb: URL?
        var error: String?
    }
    public static func request(_ galleries: [Gallery]) throws -> Data {
        guard !galleries.isEmpty, galleries.count <= 25 else { throw ViewerError.invalidQuery("元数据每批最多 25 项。") }
        let list: [[Any]] = galleries.map { [$0.ref.gid, $0.ref.token] }
        return try JSONSerialization.data(withJSONObject: ["method": "gdata", "gidlist": list, "namespace": 1])
    }
    public static func merge(_ data: Data, into galleries: [Gallery]) throws -> [Gallery] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var records: [Int64: Entry] = [:]
        for entry in response.gmetadata { records[entry.gid] = entry }
        return galleries.map { gallery in
            guard let entry = records[gallery.ref.gid], entry.error == nil else { return gallery }
            var value = gallery
            if let title = entry.title { value.title = title }
            if let title = entry.title_jpn { value.japaneseTitle = title }
            if let category = entry.category { value.category = category }
            if let uploader = entry.uploader { value.uploader = uploader }
            if let count = entry.filecount.flatMap(Int.init) { value.pages = count }
            if let rating = entry.rating.flatMap(Double.init) { value.rating = rating }
            if let tags = entry.tags { value.tags = tags.compactMap(GalleryTag.init); value.tagsComplete = true }
            if let thumb = entry.thumb, URLPolicy.media(thumb) { value.cover = thumb }
            return value
        }
    }
}
