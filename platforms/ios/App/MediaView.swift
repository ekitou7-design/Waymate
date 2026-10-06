import SwiftUI

struct MediaView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("APPLE MUSIC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let media = model.mediaState {
                        Text(media.trackTitle).font(.largeTitle.weight(.semibold))
                        if !media.artistName.isEmpty { Text(media.artistName).font(.title3).foregroundStyle(.secondary) }
                        if media.connected {
                            Text(media.playing ? "正在播放" : "已暂停 / 尚未播放").foregroundStyle(.secondary)
                            HStack(spacing: 24) {
                                mediaButton("上一首", symbol: "backward.end.fill", kind: 16)
                                mediaButton(media.playing ? "暂停" : "播放", symbol: media.playing ? "pause.fill" : "play.fill", kind: 17)
                                mediaButton("下一首", symbol: "forward.end.fill", kind: 18)
                            }
                        } else {
                            Button("前往设置查看媒体权限") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    } else {
                        Text("媒体信息不可用").font(.title2)
                        Text("等待 Apple Music 的媒体资料库状态。")
                    }
                    Text("读取与控制 iPhone 音乐 App。请先在 Apple Music 中选择音乐；不支持其他播放器的通用控制。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DeviceStatusView(device: model.device)
                }.padding(24)
            }
            .background(WaymateTheme.background)
            .tint(WaymateTheme.accent)
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("media-done-button")
                }
            }
            .accessibilityIdentifier("media-sheet")
            .tint(WaymateTheme.accent)
        }
    }

    private func mediaButton(_ title: String, symbol: String, kind: UInt8) -> some View {
        Button { model.performMediaCommand(kind) } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("media-command-\(kind)")
    }
}
