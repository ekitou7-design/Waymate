import SwiftUI
import UIKit

/// Local output state only. Summary and Detail use the same system share flow.
struct RideShareActions: View {
    let record: RideRecord
    @State private var busy = false
    @State private var error: String?
    @State private var payload: Payload?
    @State private var temporaryFile: URL?

    private struct Payload: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private var exportReason: String? {
        do { try RideGPXExporter.validate(record); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                Button("SHARE", action: shareImage).accessibilityIdentifier("ride-share-button")
                Button("EXPORT GPX", action: exportGPX)
                    .disabled(exportReason != nil).accessibilityIdentifier("ride-export-gpx-button")
            }.font(.subheadline.weight(.medium)).frame(minHeight: 44).disabled(busy)
            if busy { ProgressView("正在准备分享…").accessibilityIdentifier("ride-share-progress") }
            Text("共享内容包含实际骑行轨迹。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("ride-share-privacy")
            if let exportReason {
                Text(exportReason).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ride-gpx-unavailable")
            }
        }
        .sheet(item: $payload, onDismiss: cleanup) { payload in
            RideActivitySheet(items: payload.items) { message in error = message }
        }
        .alert("未完成分享", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { if payload == nil { cleanup() } }
    }

    private func shareImage() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            // Let the progress indicator appear before the synchronous native render.
            await Task.yield()
            do { payload = Payload(items: [try RideShareRenderer.image(for: record)]) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func exportGPX() {
        busy = true
        let record = record
        Task { @MainActor in
            defer { busy = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try RideGPXExporter.temporaryFile(for: record)
                }.value
                temporaryFile = file
                payload = Payload(items: [file])
            } catch { self.error = error.localizedDescription }
        }
    }

    private func cleanup() {
        if let file = temporaryFile { RideGPXExporter.removeTemporaryFile(file) }
        temporaryFile = nil
    }
}

private struct RideActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
