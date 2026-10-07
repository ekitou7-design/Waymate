import SwiftUI

struct RideHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.rideHistoryLoading {
                    ProgressView("正在读取记录…")
                } else if let error = model.rideHistoryError {
                    ContentUnavailableView("无法读取 Ride 历史", systemImage: "exclamationmark.triangle",
                                           description: Text("\(error)\n原始文件已保留。"))
                        .accessibilityIdentifier("ride-history-error")
                } else if model.rideHistory.isEmpty {
                    ContentUnavailableView("暂无骑行记录", systemImage: "bicycle",
                                           description: Text("结束 Ride 后，记录会保存在本机。"))
                        .accessibilityIdentifier("ride-history-empty")
                } else {
                    List(model.rideHistory) { record in
                        NavigationLink {
                            RideDetailView(model: model, recordID: record.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.displayName).font(.headline)
                                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(RideDisplayFormat.distance(record.distance)) · Elapsed \(RideDisplayFormat.duration(record.elapsedTime))")
                                    .font(.subheadline).monospacedDigit()
                            }.padding(.vertical, 8)
                        }.accessibilityIdentifier("ride-history-\(record.id.uuidString)")
                            .listRowBackground(WaymateTheme.surface)
                    }.scrollContentBackground(.hidden).accessibilityIdentifier("ride-history-list")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WaymateTheme.background)
            .navigationTitle("RIDES")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("ride-history-done")
                }
            }
        }.tint(WaymateTheme.accent)
    }
}
