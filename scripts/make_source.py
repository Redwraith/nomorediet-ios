#!/usr/bin/env python3
"""Writes the SideStore/AltStore source (apps.json) for Nomorediet's over-the-air updates.

Usage: make_source.py <existing apps.json or ""> <version> <build> <ipa path> <download url> <icon url> <notes file>
Keeps the previous versions (newest first, max 10) so SideStore can show the history.
"""
import json, os, sys, datetime

existing, version, build, ipa, url, icon, notes_file = sys.argv[1:8]
source = {}
if existing and os.path.exists(existing):
    with open(existing) as f:
        source = json.load(f)
notes = open(notes_file).read().strip() if os.path.exists(notes_file) else ""
entry = {
    "version": version,
    "buildVersion": build,
    "date": datetime.date.today().isoformat(),
    "localizedDescription": notes or f"Nomorediet {version}",
    "downloadURL": url,
    "size": os.path.getsize(ipa),
    "minOSVersion": "18.0",
}
app = (source.get("apps") or [{}])[0]
versions = [v for v in app.get("versions", []) if v.get("buildVersion") != build]
app.update({
    "name": "Nomorediet",
    "bundleIdentifier": "app.piatto.ios",
    "developerName": "Nomorediet",
    "subtitle": "Diario alimentare, peso e allenamento",
    "localizedDescription": "Diario alimentare con riconoscimento dei pasti da foto, voce e testo, database di oltre 170.000 alimenti, peso, grafici e scheda di allenamento.",
    "iconURL": icon,
    "tintColor": "4DB880",
    "category": "lifestyle",
    "versions": [entry] + versions[:9],
    "appPermissions": {"entitlements": [], "privacy": {}},
})
source.update({
    "name": "Nomorediet",
    "identifier": "app.piatto.ios.source",
    "subtitle": "Aggiornamenti di Nomorediet",
    "iconURL": icon,
    "apps": [app],
    "news": source.get("news", []),
})
json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
