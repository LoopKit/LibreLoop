import Foundation
import UIKit
import SwiftUI
import LoopKit
import LoopKitUI
import LibreLoop

final class LibreLoopUICoordinator: UINavigationController, CGMManagerOnboarding, CompletionNotifying {
    var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private var cgmManager: LibreLoopCGMManager?
    private let colorPalette: LoopUIColorPalette
    private let displayGlucosePreference: DisplayGlucosePreference

    init(cgmManager: LibreLoopCGMManager?,
         colorPalette: LoopUIColorPalette,
         displayGlucosePreference: DisplayGlucosePreference) {
        self.cgmManager = cgmManager
        self.colorPalette = colorPalette
        self.displayGlucosePreference = displayGlucosePreference
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
        if cgmManager == nil {
            setViewControllers([applySensorViewController()], animated: false)
        } else {
            setViewControllers([settingsViewController()], animated: false)
        }
    }

    // MARK: - Onboarding flow

    private func applySensorViewController() -> UIViewController {
        let view = LibreLoopApplySensorView(
            onNext: { [weak self] in self?.pushScanSensorView() },
            onShowHelp: { [weak self] in self?.presentApplyHelp() },
            onCancel: { [weak self] in self?.cancelOnboarding() }
        )
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        // Use only the chevron on the next screen's back button so it
        // doesn't mid-push swap "FreeStyle Libre 3" -> "Back".
        vc.navigationItem.backButtonDisplayMode = .minimal
        return vc
    }

    private func pushScanSensorView() {
        let view = LibreLoopScanSensorView(
            onScan: { [weak self] in self?.startScan(mode: .fresh) },
            onShowHelp: { [weak self] in self?.presentScanHelp() },
            onShowRecovery: { [weak self] in self?.pushRecoveryView() }
        )
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        // SwiftUI's .navigationTitle propagates to navigationItem.title
        // only on the next update cycle, which lands after the push
        // animation begins -- the title pops in late. Setting it on the
        // VC at creation makes it present from the start of the push.
        vc.title = "FreeStyle Libre 3"
        vc.navigationItem.backButtonDisplayMode = .minimal
        pushViewController(vc, animated: true)
    }

    private func pushRecoveryView() {
        let view = LibreLoopRecoveryView(
            onContinue: { [weak self] receiverID in
                self?.startScan(mode: .recovery(receiverID: receiverID))
            }
        )
        .environment(\.appName, Bundle.main.bundleDisplayName)
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        vc.title = "Recovery"
        pushViewController(vc, animated: true)
    }

    private func presentApplyHelp() {
        let view = LibreLoopApplyHelpPagerView(onDone: { [weak self] in
            self?.dismiss(animated: true)
        })
        let host = DismissibleHostingController(content: view, colorPalette: colorPalette)
        present(host, animated: true)
    }

    private func presentScanHelp() {
        let view = LibreLoopScanHelpPagerView(onDone: { [weak self] in
            self?.dismiss(animated: true)
        })
        let host = DismissibleHostingController(content: view, colorPalette: colorPalette)
        present(host, animated: true)
    }

    private func startScan(mode: LibreLoopPairingService.Mode) {
        // Create the manager up front so the pairing view model has something
        // to write into; if the user cancels we tear it back down.
        let manager = LibreLoopCGMManager()
        self.cgmManager = manager
        let viewModel = LibreLoopPairingViewModel(cgmManager: manager, mode: mode)
        let view = LibreLoopPairingProgressView(
            viewModel: viewModel,
            onDone: { [weak self] in self?.completeSetupWithExistingManager() },
            onCancel: { [weak self] in self?.abortPairing() },
            onRetry: { [weak self] in self?.retryPairing() }
        )
        let host = DismissibleHostingController(content: view, colorPalette: colorPalette)
        pushViewController(host, animated: true)
    }

    private func completeSetupWithExistingManager() {
        guard let manager = cgmManager else {
            cancelOnboarding()
            return
        }
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func abortPairing() {
        cgmManager = nil
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func retryPairing() {
        popViewController(animated: true)
    }

    private func cancelOnboarding() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func completeSetup() {
        let manager = LibreLoopCGMManager()
        self.cgmManager = manager
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    // MARK: - Settings

    private func settingsViewController() -> UIViewController {
        let view = LibreLoopSettingsView(
            viewModel: LibreLoopSettingsViewModel(cgmManager: cgmManager!),
            didFinish: { [weak self] in
                guard let self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            },
            replaceSensor: { [weak self] in self?.startReplacementPairing() },
            deleteCGM: { [weak self] in
                self?.cgmManager?.notifyDelegateOfDeletion {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.completionDelegate?.completionNotifyingDidComplete(self)
                        self.dismiss(animated: true)
                    }
                }
            }
        )
        .environmentObject(displayGlucosePreference)
        .environment(\.appName, Bundle.main.bundleDisplayName)
        return DismissibleHostingController(content: view, colorPalette: colorPalette)
    }

    // MARK: - Replacement pairing

    private var isReplacing = false

    private func startReplacementPairing() {
        guard let manager = cgmManager else { return }
        isReplacing = true
        manager.discardSensor()
        pushReplacementApplyView()
    }

    private func pushReplacementApplyView() {
        let view = LibreLoopApplySensorView(
            onNext: { [weak self] in self?.pushReplacementScanView() },
            onShowHelp: { [weak self] in self?.presentApplyHelp() },
            onCancel: { [weak self] in self?.cancelReplacement() }
        )
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        vc.title = "FreeStyle Libre 3"
        vc.navigationItem.backButtonDisplayMode = .minimal
        pushViewController(vc, animated: true)
    }

    private func pushReplacementScanView() {
        let view = LibreLoopScanSensorView(
            onScan: { [weak self] in self?.startReplacementScan(mode: .fresh) },
            onShowHelp: { [weak self] in self?.presentScanHelp() },
            onShowRecovery: { [weak self] in self?.pushReplacementRecoveryView() }
        )
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        vc.title = "FreeStyle Libre 3"
        vc.navigationItem.backButtonDisplayMode = .minimal
        pushViewController(vc, animated: true)
    }

    private func pushReplacementRecoveryView() {
        let view = LibreLoopRecoveryView(
            onContinue: { [weak self] receiverID in
                self?.startReplacementScan(mode: .recovery(receiverID: receiverID))
            }
        )
        .environment(\.appName, Bundle.main.bundleDisplayName)
        let vc = DismissibleHostingController(content: view, colorPalette: colorPalette)
        vc.title = "Recovery"
        pushViewController(vc, animated: true)
    }

    private func startReplacementScan(mode: LibreLoopPairingService.Mode) {
        guard let manager = cgmManager else { return }
        let viewModel = LibreLoopPairingViewModel(cgmManager: manager, mode: mode)
        let view = LibreLoopPairingProgressView(
            viewModel: viewModel,
            onDone: { [weak self] in self?.finishReplacement() },
            onCancel: { [weak self] in self?.cancelReplacement() },
            onRetry: { [weak self] in self?.popViewController(animated: true) }
        )
        let host = DismissibleHostingController(content: view, colorPalette: colorPalette)
        pushViewController(host, animated: true)
    }

    private func finishReplacement() {
        isReplacing = false
        popToRootViewController(animated: true)
    }

    private func cancelReplacement() {
        isReplacing = false
        popToRootViewController(animated: true)
    }
}

extension Bundle {
    /// The host app's display name (Loop, Trio, a rebrand, …). `Bundle.main`
    /// is the running app, not this plugin, so this resolves to whatever app
    /// embedded LibreLoop. Used to seed `\.appName` for the plugin's views.
    var bundleDisplayName: String {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }
}
