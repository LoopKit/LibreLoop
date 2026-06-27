import Foundation
import LoopKit

/// Sensor end-of-life alert schedule. Routes through LoopKit's Alert
/// system (no direct UNUserNotificationCenter); the AlertManager handles
/// scheduling and persistence so the alerts fire even if the app has
/// been suspended or relaunched.
///
///   - `warning24h` (.active): day-before reminder. Routed as `.active`
///     so iOS Focus/Sleep modes naturally suppress it overnight and
///     surface it once the user is available.
///   - `warning2h` (.timeSensitive): hard reminder — the loop is about
///     to go dark, the user needs to know even at 3am.
///   - `sessionEnded` (.timeSensitive): fires at predicted T-0. Sensor
///     may run a few minutes long or die early; either way, the user
///     needs to know CGM is offline.
///
/// Glucose-level alerts (low/high/urgent-low) are intentionally NOT here.
/// Those are Loop's responsibility once we build the Loop-side config.
enum LibreLoopExpiryAlerts {
    static let warning24hIdentifier: Alert.AlertIdentifier = "sensorExpiry.warning24h"
    static let warning2hIdentifier: Alert.AlertIdentifier = "sensorExpiry.warning2h"
    static let sessionEndedIdentifier: Alert.AlertIdentifier = "sensorExpiry.sessionEnded"

    static let allIdentifiers: [Alert.AlertIdentifier] = [
        warning24hIdentifier, warning2hIdentifier, sessionEndedIdentifier
    ]

    /// Build the three scheduled alerts. Alerts whose trigger time is
    /// already in the past are dropped (e.g. we paired a sensor that's
    /// already 13 days old, or restored state past the 24h warning).
    static func scheduledAlerts(
        managerIdentifier: String,
        sensorActivatedAt: Date,
        now: Date = Date(),
        lifetime: TimeInterval = LibreLoopSensorLifecycle.activeDuration
    ) -> [Alert] {
        let expiresAt = sensorActivatedAt.addingTimeInterval(lifetime)
        let timeString = expirationTimeString(expiresAt)
        let fullString = expirationFullString(expiresAt)

        var alerts: [Alert] = []
        let ok = LocalizedString("OK", comment: "Alert acknowledge button")

        let warn24h = expiresAt.addingTimeInterval(-24 * 60 * 60)
        if warn24h > now {
            let content = Alert.Content(
                title: LocalizedString("Sensor ends tomorrow", comment: "24h sensor-expiry alert title"),
                body: String(format: LocalizedString("Your FreeStyle Libre 3 sensor expires %@. Replace it before then to avoid a CGM interruption.", comment: "24h sensor-expiry alert body (expiry date/time)"), fullString),
                acknowledgeActionButtonLabel: ok
            )
            alerts.append(Alert(
                identifier: .init(managerIdentifier: managerIdentifier, alertIdentifier: warning24hIdentifier),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .delayed(interval: warn24h.timeIntervalSince(now)),
                interruptionLevel: .active
            ))
        }

        let warn2h = expiresAt.addingTimeInterval(-2 * 60 * 60)
        if warn2h > now {
            let content = Alert.Content(
                title: LocalizedString("Sensor ends in 2 hours", comment: "2h sensor-expiry alert title"),
                body: String(format: LocalizedString("Your FreeStyle Libre 3 sensor expires at %@. Replace it now to avoid a CGM interruption.", comment: "2h sensor-expiry alert body (expiry time)"), timeString),
                acknowledgeActionButtonLabel: ok
            )
            alerts.append(Alert(
                identifier: .init(managerIdentifier: managerIdentifier, alertIdentifier: warning2hIdentifier),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .delayed(interval: warn2h.timeIntervalSince(now)),
                interruptionLevel: .timeSensitive
            ))
        }

        if expiresAt > now {
            let content = Alert.Content(
                title: LocalizedString("Sensor session ended", comment: "Sensor expired alert title"),
                body: LocalizedString("Your FreeStyle Libre 3 sensor has expired. Replace it to resume CGM readings.", comment: "Sensor expired alert body"),
                acknowledgeActionButtonLabel: ok
            )
            alerts.append(Alert(
                identifier: .init(managerIdentifier: managerIdentifier, alertIdentifier: sessionEndedIdentifier),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .delayed(interval: expiresAt.timeIntervalSince(now)),
                interruptionLevel: .timeSensitive
            ))
        }

        return alerts
    }

    private static func expirationTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func expirationFullString(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }
}
