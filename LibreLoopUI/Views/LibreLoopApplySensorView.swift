import SwiftUI

struct LibreLoopApplySensorView: View {
    let onNext: () -> Void
    let onShowHelp: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    heroImage
                        .padding(.top, 32)

                    Text(LocalizedString("Apply a new Sensor", comment: "Apply-sensor screen title"))
                        .font(.title2.weight(.semibold))

                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedString("The sensor should only be applied to the back of your upper arm.", comment: "Apply-sensor instruction"))
                        Text(LocalizedString("Do not remove the cap from the sensor applicator until you're ready to apply the sensor.", comment: "Apply-sensor cap instruction"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 24)

                    Button(action: onShowHelp) {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle.fill")
                            Text(LocalizedString("HOW TO APPLY A SENSOR", comment: "Apply-sensor help button"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            }

            Button(action: onNext) {
                Text(LocalizedString("Next", comment: "Next button"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(LocalizedString("Cancel", comment: "Cancel button"), action: onCancel)
            }
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        if let uiImage = UIImage(named: "ApplySensorStep1",
                                 in: Bundle(for: LibreLoopSettingsViewModel.self),
                                 compatibleWith: nil) {
            // Light card behind the illustration so the transparent
            // SVG reads in dark mode.
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(height: 230)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.97))
                )
                .padding(.horizontal, 12)
        } else {
            Image(systemName: "figure.arms.open")
                .resizable()
                .scaledToFit()
                .frame(height: 140)
                .foregroundStyle(.tint)
        }
    }
}
