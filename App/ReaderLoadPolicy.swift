import Foundation

enum ReaderLoadPolicy {
    static let maxPrefetchCount = 128
    static let defaultPrefetchCount = 32
    static let maxConcurrency = 16
    static let defaultConcurrency = 16
    static let concurrencyChoices = [2, 4, 8, 16]
    static let prefetchChoices = [0, 2, 4, 6, 8, 16, 32, 64, 128]

    static func migrate(defaults: UserDefaults) {
        let versionKey = "reader.loadPolicyVersion"
        guard defaults.integer(forKey: versionKey) < 1 else { return }

        let prefetchKey = "reader.prefetchCount"
        if let stored = defaults.object(forKey: prefetchKey) as? Int {
            let migrated = (1...6).contains(stored) ? defaultPrefetchCount : stored
            defaults.set(min(maxPrefetchCount, max(0, migrated)), forKey: prefetchKey)
        } else {
            defaults.set(defaultPrefetchCount, forKey: prefetchKey)
        }

        let concurrencyKey = "reader.downloadConcurrency"
        if defaults.object(forKey: concurrencyKey) == nil {
            defaults.set(defaultConcurrency, forKey: concurrencyKey)
        } else {
            defaults.set(clampedConcurrency(defaults.integer(forKey: concurrencyKey)), forKey: concurrencyKey)
        }
        defaults.set(1, forKey: versionKey)
    }

    static func clampedPrefetchCount(_ value: Int) -> Int {
        min(maxPrefetchCount, max(0, value))
    }

    static func clampedConcurrency(_ value: Int) -> Int {
        min(maxConcurrency, max(2, value))
    }
}
