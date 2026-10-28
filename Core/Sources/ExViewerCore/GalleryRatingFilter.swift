import Foundation

/// Numeric ratings must come from the average, never the list's star sprite
/// (which can show a user's personal vote).
public enum GalleryRatingFilter {
    public static func average(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...5).contains(value) else { return nil }
        return value
    }

    public static func minimum(in url: URL) -> Int? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "f_sr" })?.value == "on",
              let raw = query.first(where: { $0.name == "f_srdd" })?.value,
              let minimum = Int(raw), (2...5).contains(minimum) else { return nil }
        return minimum
    }

    public static func includes(_ gallery: Gallery, minimum: Int?) -> Bool {
        guard let minimum else { return true }
        guard let rating = average(gallery.rating) else { return false }
        return rating >= Double(minimum)
    }
}
