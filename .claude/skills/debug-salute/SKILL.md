---
name: debug-salute
description: Debug and test Nomorediet's Apple Health sync on the iPhone plugged into this PC - connect Health (steps and weight), run a sync, read the app's own logs and the device syslog, and fix the Swift code when something is wrong. Use when the user says Salute / Apple Health / passi / peso do not sync, the Health import shows no data, or asks to test the Health part of the app.
---

# Debug Apple Health in Nomorediet

Code: `ios/Piatto/HealthBridge.swift` (HealthKit, direct), `ios/Piatto/ShortcutHealth.swift` (Shortcuts bridge,
`SendHealthIntent`), `ios/Piatto/HealthExport.swift` (Health's export.zip / export.xml import),
`ios/Piatto/Sync.swift` (`importHealth`, `syncHealth`, `applyHealth`), UI in `ios/Piatto/ProfileView.swift`
(`HealthStatusRow`). The app writes every Health step to its debug log (category `health`).

## 1. Which path is the phone on?

Open the app (iphone-control: `wda.py launch nomorediet`, `tap-el tab-profilo`) and read the line under
"Apple Salute":
- `Collegata ✓` → HealthKit works (installed with Impactor). Go to 2.
- `Non collegata: Missing com.apple.developer.healthkit entitlement` → installed by SideStore, which strips
  HealthKit. Reinstall with Impactor (`setup-windows` skill), or use the Shortcuts bridge / export import.
- `Non ancora letta` → the "Apple Salute" toggle in Profilo is off.

## 2. Connect and sync (HealthKit)

1. Profilo > "Collega Apple Salute". iOS shows the Health sheet: the user turns on at least **Passi** and
   **Peso** (they decide; never toggle Health permissions for them), then "Consenti".
2. "Sincronizza adesso". Within a few seconds: steps chart in Progressi, weight entries marked "Salute".
3. Debug panel: `wda.py open "nomorediet://debug"`, screenshot it, read the `health` lines.

## 3. Logs from the device

```powershell
py -3.12 -m pymobiledevice3 syslog live -m Nomorediet
```

Look for HealthKit authorization errors (`Authorization not determined`, `Missing ... entitlement`) and
`[health]` lines from DebugLog. Save what you read in `iphone-runs/<date>-salute/` with the screenshots.

## 4. Export import path

Health app > profile picture > "Esporta tutti i dati sanitari" > share sheet > Nomorediet. Expect the
overlay "Importo i dati di Salute…" and an alert with days and weighings imported. The debug log shows:
`File ricevuto: … MB` → `export.xml estratto, … MB` → `Export letto: N righe Record, M usate`.
A step missing there tells you where it stops (file not delivered / zip / parsing).

## 5. Fixing

Reproduce, fix in Swift, add or adjust a test in `ios/Tests/NomoredietTests.swift`, bump
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ios/project.yml` (both targets), add a line to
`docs/CHANGELOG.md`, commit and push to `main`: GitHub Actions builds, tests and publishes the .ipa and the
SideStore source. Re-install with Impactor and verify on the phone with screenshots before saying it works.
