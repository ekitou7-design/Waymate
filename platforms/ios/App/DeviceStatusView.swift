import SwiftUI

/// Connection and protocol readiness are distinct; neither proves live GPS.
struct DeviceStatusView: View {
    let device: BLEDeviceSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ready ? WaymateTheme.connected : WaymateTheme.warning)
                .frame(width: 7, height: 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("ROUND DISPLAY").font(.caption.weight(.semibold))
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var ready: Bool {
        if case .connected = device.connection { return device.negotiatedProtocol == "V1" }
        return false
    }

    private var status: String {
        switch device.connection {
        case .connected: return ready ? "已连接 · 协议就绪" : "已连接 · 正在准备协议"
        case .connecting: return "正在连接"
        case .scanning: return "正在寻找圆屏"
        case .failed: return "连接未成功"
        case .bluetoothUnavailable: return "蓝牙不可用"
        case .idle: return "未连接"
        }
    }
}
