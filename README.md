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
- No sensor warm-up countdown during a switch-receiver pairing (duration is sensor-reported for fresh activations)
- Alerting is handled entirely by Loop — see the safety note below

## Safety: Glucose Alerting

Because this integration talks directly to the sensor over BLE — bypassing the official Abbott FreeStyle Libre 3 app — **the Abbott app's alerts are not active while LibreLoop is in use.** Loop's own glucose alerting system is the only source of low/high alarms.

Before using LibreLoop, ensure reliable glucose alerting is in place:

- The recommended **[LoopKit/Loop `next-dev`](https://github.com/LoopKit/LoopWorkspace/tree/next-dev)** build ships with urgent-low, low, and high glucose alerts preconfigured by default — including **Critical Alerts** for urgent-low (which break through Do Not Disturb and silent mode). If you use this build, no manual alert setup is required.
- **Do not use LibreLoop with a different version of Loop, or another app entirely (e.g., Trio), until that app provides comparable glucose alerting** — including Critical Alerts for urgent-low that break through Do Not Disturb and silent mode. Without an equivalent alerting system in place, the wearer can miss dangerous lows and highs.
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
