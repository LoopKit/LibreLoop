import SwiftUI

struct LibreLoopPairingProgressView: View {
    @ObservedObject var viewModel: LibreLoopPairingViewModel
    let onDone: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            indicator
            Text(viewModel.statusText)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            footer
        }
        .padding()
        .navigationTitle(LocalizedString("Pairing", comment: "Pairing progress screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear { viewModel.start() }
    }

    @ViewBuilder
    private var indicator: some View {
        if viewModel.didSucceed {
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .scaledToFit()
                .frame(height: 88)
                .foregroundStyle(.green)
        } else if viewModel.didFail {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(height: 88)
                .foregroundStyle(.red)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.didSucceed {
            Button(action: onDone) {
                Text(LocalizedString("Done", comment: "Done button"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        } else if viewModel.didFail {
            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text(LocalizedString("Try again", comment: "Retry button"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                Button(LocalizedString("Cancel", comment: "Cancel button"), action: onCancel)
                    .font(.subheadline)
            }
        } else {
            Button(LocalizedString("Cancel", comment: "Cancel button"), action: onCancel)
                .font(.subheadline)
        }
    }
}
