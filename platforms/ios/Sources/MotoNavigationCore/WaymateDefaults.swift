import Foundation

/// Reads the current key first and copies valid legacy data without deleting it.
public enum WaymateDefaults {
    public static func value<Value>(
        forKey key: String,
        legacyKey: String,
        defaults: UserDefaults = .standard,
        decode: (Any) -> Value?
    ) -> Value? {
        if let current = defaults.object(forKey: key) {
            return decode(current)
        }
        guard let legacy = defaults.object(forKey: legacyKey),
              let value = decode(legacy) else { return nil }
        defaults.set(legacy, forKey: key)
        return value
    }
}
