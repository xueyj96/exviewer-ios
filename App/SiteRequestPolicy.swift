import Foundation

enum SiteRequestPolicy {
    static let defaultConcurrency = 2
    static let concurrencyChoices = [1, 2, 4]
    static let concurrencyKey = "network.pageConcurrency"

    static func clampedConcurrency(_ value: Int) -> Int {
        switch value {
        case ...1: return 1
        case 2...3: return 2
        default: return 4
        }
    }

    static func configuredConcurrency(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: concurrencyKey) != nil else { return defaultConcurrency }
        return clampedConcurrency(defaults.integer(forKey: concurrencyKey))
    }
}
