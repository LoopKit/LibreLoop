import SwiftUI
import LoopKitUI

struct LibreLoopRecoveryView: View {
    let onContinue: (UInt32) -> Void
    @Environment(\.appName) private var appName

    @State private var receiverIDInput: String = ""
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text(LocalizedString("Recover existing sensor", comment: "Recovery screen title"))
                            .font(.title2.weight(.semibold))
                        Text(LocalizedString("Enter the receiver ID this sensor was originally paired under. The sensor only accepts a switch-receiver command from the same ID it remembers — there's no way to recover without it.", comment: "Recovery screen explanation"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedString("Receiver ID", comment: "Receiver ID field label"))
                            .font(.subheadline.weight(.semibold))
                        TextField(LocalizedString("8-character hex (little-endian)", comment: "Receiver ID field placeholder"), text: $receiverIDInput)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .monospaced()
                            .onChange(of: receiverIDInput) { _, _ in validationError = nil }
                        Text(LocalizedString("Example: `78563412`. If this sensor was paired with this app before, the value is shown as \"Receiver ID\" in the Debug Info section of the Libre 3 CGM settings page.", comment: "Receiver ID field help text"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let validationError {
                            Text(validationError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Text(String(format: LocalizedString("The receiver ID is assigned by %1$@ when it first pairs a sensor. It's saved in this app and shown on the Libre 3 settings page — write it down if you want to re-pair this sensor after reinstalling %1$@.", comment: "Recovery screen footnote (1: appName)"), appName))
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 16)
                }
                .padding(24)
            }

            Button(action: tryContinue) {
                Text(LocalizedString("Continue", comment: "Continue button"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(receiverIDInput.isEmpty)
            .padding()
        }
        .navigationTitle(LocalizedString("Recovery", comment: "Recovery screen title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tryContinue() {
        let cleaned = receiverIDInput
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .filter { $0.isHexDigit }
        guard cleaned.count == 8 else {
            validationError = LocalizedString("Enter exactly 8 hex characters.", comment: "Receiver ID validation error: wrong length")
            return
        }
        // Little-endian: first hex pair is the least-significant byte
        var bytes: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else {
                validationError = LocalizedString("Couldn't parse hex.", comment: "Receiver ID validation error: parse failure")
                return
            }
            bytes.append(b)
            idx = next
        }
        let value = UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
        onContinue(value)
    }
}
