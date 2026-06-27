import SwiftUI

struct LibreLoopApplyHelpPagerView: View {
    let onDone: () -> Void

    private let steps: [HelpStep] = [
        HelpStep(
            title: LocalizedString("STEP 1", comment: "Apply-sensor help step 1 title"),
            image: .asset("ApplySensorStep1"),
            body: LocalizedString("Select a site on the back of your upper arm.", comment: "Apply-sensor help step 1 body"),
            note: LocalizedString("Avoid scars, moles, stretch marks, lumps, and insulin injection sites. Rotate sites between applications.", comment: "Apply-sensor help step 1 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 2", comment: "Apply-sensor help step 2 title"),
            image: .asset("ApplySensorStep2"),
            body: LocalizedString("Wash the site with plain soap, dry, then clean with an alcohol wipe.", comment: "Apply-sensor help step 2 body"),
            note: LocalizedString("Let the area air-dry completely before applying.", comment: "Apply-sensor help step 2 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 3", comment: "Apply-sensor help step 3 title"),
            image: .asset("ApplySensorStep3"),
            body: LocalizedString("Twist off the cap from the sensor applicator.", comment: "Apply-sensor help step 3 body"),
            note: LocalizedString("Do not reuse the cap. The sterile barrier is broken once removed.", comment: "Apply-sensor help step 3 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 4", comment: "Apply-sensor help step 4 title"),
            image: .asset("ApplySensorStep4"),
            body: LocalizedString("Press the applicator firmly against the prepared site.", comment: "Apply-sensor help step 4 body"),
            note: LocalizedString("Hold steady for a moment so the sensor seats fully against the skin.", comment: "Apply-sensor help step 4 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 5", comment: "Apply-sensor help step 5 title"),
            image: .asset("ApplySensorStep5"),
            body: LocalizedString("Lift the applicator straight away from your arm.", comment: "Apply-sensor help step 5 body"),
            note: LocalizedString("The sensor stays on your arm; the applicator comes off empty.", comment: "Apply-sensor help step 5 note")
        ),
        HelpStep(
            title: LocalizedString("STEP 6", comment: "Apply-sensor help step 6 title"),
            image: .asset("ApplySensorStep6"),
            body: LocalizedString("Run a finger around the adhesive edge to make sure the sensor is secure.", comment: "Apply-sensor help step 6 body"),
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
            .navigationTitle(LocalizedString("How to apply a Sensor", comment: "Apply-sensor help screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedString("Done", comment: "Done button"), action: onDone)
                }
            }
        }
    }
}

struct HelpStep: Identifiable {
    let id = UUID()
    let title: String
    let image: HelpStepImage
    let body: String
    let note: String?
}

enum HelpStepImage {
    case systemSymbol(String)
    case asset(String)
}

struct HelpStepCard: View {
    let step: HelpStep

    var body: some View {
        VStack(spacing: 20) {
            stepImage
                .padding(.top, 32)

            Text(step.title)
                .font(.title3.weight(.bold))
                .tracking(2)

            Text(step.body)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let note = step.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepImage: some View {
        switch step.image {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .foregroundStyle(.tint)
        case .asset(let name):
            // Asset-catalog SVG: load through UIImage from the framework
            // bundle for the same reason FSL3-sensor.png does -- SwiftUI's
            // Image(_:bundle:) is unreliable for plugin-framework assets.
            // The illustrations are drawn on a transparent background with
            // dark line work, so they need a light card behind them to read
            // in dark mode. Use a fixed light fill rather than a system
            // color so the contrast stays consistent in both modes.
            if let uiImage = UIImage(named: name,
                                     in: Bundle(for: LibreLoopSettingsViewModel.self),
                                     compatibleWith: nil) {
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
            }
        }
    }
}
