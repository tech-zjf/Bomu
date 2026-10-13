import Foundation

enum Brand {
    static let displayName = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleDisplayName"
    ) as? String ?? "Bomu"
}
