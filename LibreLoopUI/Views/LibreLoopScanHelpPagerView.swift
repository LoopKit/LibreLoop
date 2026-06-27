import SwiftUI

struct LibreLoopScanHelpPagerView: View {
    let onDone: () -> Void

    private let steps: [HelpStep] = [
        HelpStep(
            title: LocalizedString("STEP 1", comment: "Scan-sensor help step 1 title"),
            image: .systemSymbol("iphone.gen3.radiowaves.left.and.right"),
            body: LocalizedString("Hold the BACK of your phone against the sensor.", comment: "Scan-sensor help step 1 body"),
            note: nil
        ),
        HelpStep(
            title: LocalizedString("STEP 2", comment: "Scan-sensor help step 2 title"),
            image: .systemSymbol("hand.raised.fill"),
            body: LocalizedString("Keep the phone still. Pairing takes a few seconds.", comment: "Scan-sensor help step 2 body"),
            note: LocalizedString("If your phone moves away, the scan will fail and you'll need to try again.", comment: "Scan-sensor help step 2 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 3", comment: "Scan-sensor help step 3 title"),
            image: .systemSymbol("checkmark.seal.fill"),
            body: LocalizedString("Your phone will vibrate when pairing succeeds.", comment: "Scan-sensor help step 3 body"),
            note: nil
        )
    ]

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(steps) { step in
                    HelpStepCard(step: step)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(LocalizedString("How to scan a Sensor", comment: "Scan-sensor help screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedString("Done", comment: "Done button"), action: onDone)
                }
            }
        }
    }
}
