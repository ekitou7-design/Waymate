import Foundation
import MotoNavigationCore

enum AppConfiguration {
    static var gatewayBaseURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--moto-reset-gateway") {
            UserDefaults.standard.removeObject(forKey: GatewayConfiguration.defaultsKey)
            UserDefaults.standard.removeObject(forKey: GatewayConfiguration.legacyDefaultsKey)
        }
        #endif
        return GatewayConfiguration.resolvedURL(
            bundledAddress: Bundle.main.object(forInfoDictionaryKey: "MOTOGPSGatewayBaseURL") as? String
        ) ?? URL(string: "https://example.invalid/moto-gps/api/")!
    }
}
