import SwiftUI

/// One visual treatment for Start Ride and the persistent navigation action.
struct WaymatePrimaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .foregroundStyle(destructive ? WaymateTheme.onError : WaymateTheme.onAccent)
            .background(destructive ? WaymateTheme.error : WaymateTheme.accent,
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
