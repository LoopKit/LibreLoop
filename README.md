# LibreLoop

FreeStyle Libre 3 CGMManager plugin for [Loop](https://github.com/LoopKit/Loop), built on the reverse-engineered Libre 3 protocol via [LibreCRKit](https://github.com/airedev326/LibreCRKit).

## Status

Working end-to-end on iOS. The plugin pairs with a Libre 3 sensor via NFC, maintains a BLE session, and delivers glucose readings to Loop every 5 minutes. Sensor lifecycle, reconnect-on-restart, and historical backfill are all functional.

**What works:**
- NFC pairing and first-pair credential storage
- Automatic BLE reconnect after app restart or sensor re-advertisement (using persisted receiverID — no re-pairing required)
- 5-minute glucose readings via the historical data plane
- Clinical (real-time) readings forwarded when available
- Historical backfill on reconnect
- Sensor end-of-life tracking: HUD lifecycle bar in the last 24 h, critical badge under 2 h, alert on expiry
- Recent Readings list with tappable sample detail
- Loop HUD and status screen matching the G7 layout

**Known limitations / not yet done:**
- No glucose trend arrow (LibreCRKit does not yet expose trend)
- No sensor warm-up countdown (Libre 3 warm-up is ~60 min)
- No support for the Libre 3 Plus (14-day sensor)
- Alerting is handled entirely by Loop — see the safety note below

## Safety: Glucose Alerting

Because this integration talks directly to the sensor over BLE — bypassing the official Abbott FreeStyle Libre 3 app — **the Abbott app's alerts are not active while LibreLoop is in use.** Loop's own glucose alerting system is the only source of low/high alarms.

Before using LibreLoop, ensure that Loop is configured with reliable glucose alerting:

- Set urgent-low, low, and high glucose alerts in Loop's **Alert Management** settings.
- Choose **Critical Alerts** for urgent-low alarms so they break through Do Not Disturb and silent mode.
- Tell caregivers or followers to enable a remote-monitoring solution (e.g., Nightscout, Tidepool) so someone other than the wearer can act if an alarm is missed.

Do not use LibreLoop without at least one independent alerting path active.

## Structure

- `LibreLoop/` — Core framework. CGMManager, BLE session coordinator, pairing service, sensor monitor.
- `LibreLoopUI/` — UI framework. SwiftUI onboarding and status/settings screens.
- `LibreLoopPlugin/` — Plugin bundle (`.loopplugin`) loaded dynamically by Loop.
- `LibreLoopTests/` — Unit tests.
- `Scripts/generate_project.rb` — Regenerates `LibreLoop.xcodeproj` from scratch.

## Building

LibreLoop is developed as part of the [LoopWorkspace](https://github.com/LoopKit/LoopWorkspace) monorepo. Clone the workspace and build the Loop scheme; LibreLoopPlugin is included in the scheme and embedded automatically.

## License

MIT
