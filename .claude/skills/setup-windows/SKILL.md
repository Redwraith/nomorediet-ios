---
name: setup-windows
description: Prepare this Windows PC to install and test Nomorediet on the iPhone plugged in by USB - iTunes drivers, Impactor, the latest Nomorediet.ipa, Python with pymobiledevice3 - then install the app with Impactor so it keeps the Apple Health permission. Use when the user asks to set up the PC, install or reinstall Nomorediet (or SideStore) on the phone, or says SideStore shows "app non più disponibile" (expired 7-day certificate).
---

# Windows setup for Nomorediet on iPhone

Runs on the user's Windows PC (PowerShell). Do each step, check it worked, then move on.

## 1. Look at the machine first

```powershell
[System.Environment]::OSVersion.VersionString; $env:PROCESSOR_ARCHITECTURE
winget --version
Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
py -0p 2>$null
```

## 2. Install what is missing

Everything at once (idempotent; downloads into `%USERPROFILE%\Downloads\Nomorediet`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\installa.ps1
```

Or step by step:
- iTunes (Apple Mobile Device drivers): `winget install --id Apple.iTunes -e`
- Python 3.12 + pymobiledevice3: `winget install --id Python.Python.3.12 -e` then `py -3.12 -m pip install --upgrade pymobiledevice3`
- Impactor: latest Windows asset from https://github.com/khcrysalis/PlumeImpactor/releases
- Nomorediet: https://github.com/Redwraith/nomorediet-ios/releases/download/piatto-ios/Nomorediet.ipa

## 3. Check the phone is visible

```powershell
py -3.12 -m pymobiledevice3 usbmux list
```

Empty list: cable (a data cable, not charge-only), "Autorizza questo computer" on the phone, Apple Mobile
Device Service running. Never type the phone passcode: ask the user to unlock and trust.

## 4. Install Nomorediet with Impactor (keeps Apple Health)

SideStore strips the HealthKit entitlement; Impactor keeps the entitlements found in the app
(it only drops iCloud, In-App Purchase, Sign in with Apple and a few others for free accounts).
Impactor appends the team id to the bundle id exactly like SideStore (`app.piatto.ios.<TEAM>`), so it
replaces the existing app and **keeps its data**. Never delete the old app to "start clean".

1. Open Impactor. The user signs in with their own Apple ID (the same one used by SideStore). Never type
   the Apple ID password or 2FA code yourself: the user does it.
2. Drag `Nomorediet.ipa` in, Install.
3. On the phone (the user, or iphone-control once WDA runs): Impostazioni > Generali > VPN e gestione
   dispositivi > trust the Apple ID; Impostazioni > Privacy e sicurezza > Modalità sviluppatore if asked.
4. Free Apple ID limits: 3 sideloaded apps at once (SideStore, Nomorediet, Playlist Importer) and 7 days:
   re-install with Impactor before the 7 days end (SideStore cannot refresh apps it did not install).

## 5. Verify

`py -3.12 -m pymobiledevice3 apps list | findstr piatto` shows the app. Then follow the `debug-salute` skill.
