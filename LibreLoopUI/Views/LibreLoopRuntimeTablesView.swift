import SwiftUI
import LibreLoop

/// First onboarding step: download the app credentials once, before any sensor
/// is applied, so a missing download can't strand a freshly activated sensor.
struct LibreLoopRuntimeTablesView: View {
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(LocalizedString("Couldn't download the sensor data LibreLoop needs. Check your internet connection and try again.", comment: "App credentials download failure message"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                ProgressView()
                Text(LocalizedString("Downloading sensor data…", comment: "Shown while downloading the app credentials during setup"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if failed {
                Button {
                    Task { await download() }
                } label: {
                    Text(LocalizedString("Try Again", comment: "Retry button"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(LocalizedString("Cancel", comment: "Cancel button"), action: onCancel)
            }
        }
        .task { await download() }
    }

    @MainActor
    private func download() async {
        failed = false
        do {
            try await LibreLoopAppIdentities.ensureInstalled()
            onFinished()
        } catch {
            failed = true
        }
    }
}
