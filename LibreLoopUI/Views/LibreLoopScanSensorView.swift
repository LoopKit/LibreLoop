import SwiftUI

struct LibreLoopScanSensorView: View {
    let onScan: () -> Void
    let onShowHelp: () -> Void
    let onShowRecovery: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 140)
                        .foregroundStyle(.tint)
                        .padding(.top, 32)

                    Text(LocalizedString("Scan new Sensor", comment: "Scan-sensor screen title"))
                        .font(.title2.weight(.semibold))

                    VStack(alignment: .leading, spacing: 12) {
                        Text(LocalizedString("Hold the top of your phone against the sensor.", comment: "Scan-sensor instruction"))
                        Text(LocalizedString("Keep it still — your phone will vibrate once the sensor is paired.", comment: "Scan-sensor stillness instruction"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 24)

                    Button(action: onShowHelp) {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle.fill")
                            Text(LocalizedString("HOW TO SCAN A SENSOR", comment: "Scan-sensor help button"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            }

            VStack(spacing: 12) {
                Button(action: onScan) {
                    Text(LocalizedString("Start pairing", comment: "Start pairing button"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Button(LocalizedString("Recover existing sensor", comment: "Recover existing sensor button"), action: onShowRecovery)
                    .font(.subheadline)
            }
            .padding()
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
    }
}
