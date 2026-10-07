import SwiftUI

extension RideRecord {
    var displayName: String {
        let custom = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? "\(startedAt.formatted(date: .abbreviated, time: .omitted)) 骑行" : custom
    }
}

enum RideDisplayFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
    static func distance(_ meters: Double) -> String { String(format: "%.2f km", meters / 1_000) }
    static func speed(_ speed: Double?) -> String { speed.map { String(format: "%.1f km/h", $0 * 3.6) } ?? "--" }
}

/// Summary and historical detail share the same real-record presentation.
struct RideDetailView: View {
    @ObservedObject var model: AppModel
    let recordID: UUID
    var isSummary = false
    @Environment(\.dismiss) private var dismiss
    @State private var editingName = false
    @State private var draftName = ""
    @State private var confirmsDelete = false
    @State private var operationError: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            if let record = model.savedRide(id: recordID) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(record.displayName).font(.largeTitle.weight(.semibold))
                        .accessibilityIdentifier("ride-detail-name")
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ride-detail-date")
                    if model.savingRideIDs.contains(recordID) {
                        ProgressView("正在保存 Ride…").accessibilityIdentifier("ride-save-pending")
                    } else if let error = model.rideSaveErrors[recordID] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("保存失败 · 本次记录仍在内存中").font(.headline)
                            Text(error).font(.footnote)
                            Button("重试保存") { model.retryRideSave(id: recordID) }
                                .accessibilityIdentifier("ride-save-retry")
                        }.foregroundStyle(WaymateTheme.error).accessibilityIdentifier("ride-save-error")
                    } else {
                        Text("已保存在本机").font(.caption).foregroundStyle(WaymateTheme.connected)
                            .accessibilityIdentifier("ride-save-success")
                    }
                    metric("距离 · Distance", RideDisplayFormat.distance(record.distance), "ride-detail-distance", hero: true)
                    metric("骑行时间 · Elapsed", RideDisplayFormat.duration(record.elapsedTime), "ride-detail-elapsed")
                    metric("移动时间 · Moving", RideDisplayFormat.duration(record.movingTime), "ride-detail-moving")
                    metric("平均速度 · Average", RideDisplayFormat.speed(record.averageSpeed), "ride-detail-average")
                    metric("最高速度 · Max", RideDisplayFormat.speed(record.maxSpeed), "ride-detail-max")
                    RideRouteMap(track: record.track).id(record.id)
                    RideShareActions(record: record)
                    Button("Edit Name · 修改名称") {
                        draftName = record.name ?? ""
                        editingName = true
                    }.frame(minHeight: 44).accessibilityIdentifier("ride-edit-name")
                    Button("删除 Ride", role: .destructive) { confirmsDelete = true }
                        .frame(minHeight: 44).accessibilityIdentifier("ride-delete-button")
                }.padding(24)
                    .disabled(busy)
            } else {
                ContentUnavailableView("记录已删除", systemImage: "bicycle")
            }
        }
        .background(WaymateTheme.background)
        .navigationTitle(isSummary ? "Ride Summary" : "Ride Detail")
        .navigationBarTitleDisplayMode(.inline)
        .tint(WaymateTheme.accent)
        .accessibilityIdentifier(isSummary ? "ride-summary" : "ride-detail")
        .alert("修改 Ride 名称", isPresented: $editingName) {
            TextField("名称（留空使用日期）", text: $draftName).accessibilityIdentifier("ride-name-field")
            Button("保存") { rename() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("永久删除这次 Ride？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { delete() }.accessibilityIdentifier("ride-delete-confirm")
            Button("取消", role: .cancel) {}
        }
        .alert("未完成操作", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "") }
    }

    private func metric(_ label: String, _ value: String, _ id: String, hero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(hero ? .largeTitle.weight(.semibold) : .title2.weight(.medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func rename() {
        busy = true
        Task {
            defer { busy = false }
            do { try await model.renameRide(id: recordID, name: draftName) }
            catch { operationError = error.localizedDescription }
        }
    }

    private func delete() {
        busy = true
        Task {
            defer { busy = false }
            do { try await model.deleteRide(id: recordID); dismiss() }
            catch { operationError = error.localizedDescription }
        }
    }
}
