import Foundation
import SwiftUI
import HealthKit
import LoopAlgorithm
import LoopKit
import LoopKitUI
import LibreLoop

extension LibreLoopCGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? {
        UIImage(named: "FSL3-sensor", in: Bundle(for: LibreLoopSettingsViewModel.self), compatibleWith: nil)
    }

    public static func setupViewController(
        bluetoothProvider: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .userInteractionRequired(LibreLoopUICoordinator(cgmManager: nil, colorPalette: colorPalette, displayGlucosePreference: displayGlucosePreference))
    }

    public func settingsViewController(
        bluetoothProvider: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> CGMManagerViewController {
        LibreLoopUICoordinator(cgmManager: self, colorPalette: colorPalette, displayGlucosePreference: displayGlucosePreference)
    }

    public var smallImage: UIImage? {
        UIImage(named: "FSL3-sensor", in: Bundle(for: LibreLoopSettingsViewModel.self), compatibleWith: nil)
    }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        // States are aligned with G7's conventions: .normalCGM for benign
        // "no data yet / sensor is doing its thing" cases (initializing,
        // warmup, expired); .warning for situations that hint at a real
        // problem (signal loss).
        switch sensorLifecycle {
        case .initializing:
            // No icon -- the empty image name resolves to no UIImage and
            // keeps the pill text-only.
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Initializing", comment: "CGM status highlight: waiting for first reading"),
                imageName: "",
                state: .normalCGM
            )
        case .warmup:
            // Match G7: pill is two-line state only, no countdown.
            // Countdown lives on the lifecycle bar / status page.
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nWarmup", comment: "CGM status highlight: sensor warming up"),
                imageName: "clock",
                state: .normalCGM
            )
        case .pairingWarmup:
            // Initial warmup complete; sensor still flagging readings as
            // not actionable. Distinct label from .warmup so users past
            // the 60-min mark don't see "Warmup" indefinitely.
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nStabilizing", comment: "CGM status highlight: sensor stabilizing after pairing"),
                imageName: "clock",
                state: .normalCGM
            )
        case .expired:
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nExpired", comment: "CGM status highlight: sensor expired"),
                imageName: "clock",
                state: .normalCGM
            )
        case .signalLost:
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Signal\nLoss", comment: "CGM status highlight: signal loss"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .failed:
            // Use the circle glyph (matching .signalLost and G7's failed state)
            // so the pill icon doesn't duplicate the critical-state warning
            // triangle Loop already renders.
            return LibreLoopStatusHighlight(
                localizedMessage: LocalizedString("Replace\nSensor", comment: "CGM status highlight: sensor failed, replace it"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .noSensor, .active:
            return nil
        }
    }

    public var cgmStatusBadge: DeviceStatusBadge? {
        switch sensorLifecycle {
        case .active(let remaining, _) where remaining < TimeInterval(2 * 3600):
            return LibreLoopStatusBadge(image: UIImage(systemName: "clock"), state: .critical)
        case .expired:
            return LibreLoopStatusBadge(image: UIImage(systemName: "exclamationmark.triangle.fill"), state: .critical)
        default:
            // No badge for .failed — the "Replace Sensor" highlight already
            // conveys it; a second triangle badge is redundant.
            return nil
        }
    }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        switch sensorLifecycle {
        case .warmup(let progress, _):
            return LibreLoopLifecycleProgress(percentComplete: progress, progressState: .warning)
        case .active(let remaining, let total):
            // Mirror G7: only surface the HUD bar once we're inside 24h.
            // Earlier in the sensor session the user doesn't need a
            // persistent reminder competing for HUD attention.
            guard remaining < TimeInterval(24 * 3600) else { return nil }
            let percent = 1 - (remaining / total)
            let state: DeviceLifecycleProgressState = remaining < TimeInterval(2 * 3600) ? .critical : .warning
            return LibreLoopLifecycleProgress(percentComplete: percent, progressState: state)
        case .expired:
            return LibreLoopLifecycleProgress(percentComplete: 1, progressState: .critical)
        default:
            return nil
        }
    }

    public func glucoseRangeCategory(for glucose: LoopKit.GlucoseSampleValue) -> LoopKit.GlucoseRangeCategory? { nil }

    public func unitDidChange(to displayGlucoseUnit: HKUnit) { }
}

private struct LibreLoopLifecycleProgress: DeviceLifecycleProgress {
    var percentComplete: Double
    var progressState: DeviceLifecycleProgressState
}

private struct LibreLoopStatusBadge: DeviceStatusBadge {
    var image: UIImage?
    var state: DeviceStatusBadgeState
}

private struct LibreLoopStatusHighlight: DeviceStatusHighlight {
    var localizedMessage: String
    var imageName: String
    var state: DeviceStatusHighlightState
}

/// Module-scoped localization for LibreLoopUI: looks strings up in the plugin's
/// own bundle rather than the host app's global table (mirrors
/// G7SensorKitUI.LocalizedString). Internal so it never collides with the core
/// LibreLoop module's same-named helper.
func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    let bundle = Bundle(for: LibreLoopSettingsViewModel.self)
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}
