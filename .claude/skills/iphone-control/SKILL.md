---
name: iphone-control
description: Drive the iPhone plugged into this computer over USB (real taps, swipes, typing, screenshots) through WebDriverAgent, using scripts/iphone/wda.py. Use whenever the user asks to test Nomorediet on the phone ("prova l'app sull'iPhone", "controlla che funzioni"), open an app on the phone, tap something, type into the phone, read what is on the phone's screen, or post a video from the phone's own apps (Instagram, TikTok, Edits). Never taps Share, Post, Send, Delete or Save-to-diary without the user's approval of that specific action in the current conversation.
---

# iPhone control over USB

The phone is plugged into this computer (a Mac, or a Windows PC with the experimental setup in scripts/iphone/README.md) with a data cable. `scripts/iphone/wda.py` talks to
WebDriverAgent on the phone over an HTTP port-forward. Every command below is a shell call.

## Commands

```
python3 scripts/iphone/wda.py devices              # is the phone on the cable?
python3 scripts/iphone/wda.py up                   # start (idempotent), opens the lock screen. Prints BLOCKED with the reason if it cannot.
python3 scripts/iphone/wda.py unlock               # locked phone with no passcode: opens it. Never swipe it open yourself.
python3 scripts/iphone/wda.py app                  # foreground bundle id
python3 scripts/iphone/wda.py apps piatto            # installed apps matching a filter (SideStore renames bundle ids)
python3 scripts/iphone/wda.py launch nomorediet        # a bundle id, or part of the app's id or name
python3 scripts/iphone/wda.py launch com.burbn.instagram
python3 scripts/iphone/wda.py open "http://192.168.1.20:8000/"   # a URL, or a URL scheme
python3 scripts/iphone/wda.py els                  # the on-screen elements: type, name, label, centre in points
python3 scripts/iphone/wda.py tap-el "share-sheet-share-button"
python3 scripts/iphone/wda.py tap 201 437          # points, not pixels
python3 scripts/iphone/wda.py swipe 201 700 201 300
python3 scripts/iphone/wda.py type "the caption"
python3 scripts/iphone/wda.py shot /tmp/now.png --small
python3 scripts/iphone/wda.py home
python3 scripts/iphone/wda.py down
```

## Rules (not optional)

1. **Accessibility first.** Run `els`, find the control by name, tap it with `tap-el`. Use
   `tap x y` only when a control has no name. Coordinates are POINTS (402 x 874 on an
   iPhone 16 Pro), never the screenshot's pixels (3x bigger).
2. **A zero exit code is not evidence.** WDA reports success for taps that landed on nothing.
   After every step that matters, take a `shot` and read it, or run `els` and confirm the
   next screen's controls are there. Save those screenshots; they are the receipt.
3. **Never tap a publishing or destructive control on your own.** Share, Post, Send, Delete,
   Discard, Remove, Unfollow, Sign out: stop on the screen before it, show the user the
   screenshot, and only tap it when they say yes to that specific post in this conversation.
4. **Never type a passcode or a password.** A locked phone with no passcode is not a stop:
   `wda.py unlock` (and `up`) open it through XCTest. Never swipe the lock screen yourself; that
   leaves every tap dead until a reboot. If `unlock` prints BLOCKED (a passcode), or an app wants a
   login, stop and say so. Those belong to the human.
5. **Leave the app the way you found it.** Never discard someone's unfinished draft to "reset".
   If Instagram opens on "Continue editing your draft?", stop and ask.
6. **One driver at a time.** If another process is already driving the phone, wait.
7. **Names change.** Instagram renames controls between versions. When a name from an older
   run is missing, run `els` and read the real one instead of guessing coordinates.

## Posting a reel from Instagram (the flow that worked, September 2026)

1. The video has to be in the Photos library first (AirDrop it to the phone, or serve it over
   HTTP and save it through Safari > Files > Share > Save Video). The reel picker only reads Photos.
2. `launch com.burbn.instagram` > `els` > `tap-el create` (top-left "+", label "Create a post, story or live video").
3. If a "Continue editing your draft?" sheet appears: stop and ask the user.
4. Gallery ("New reel"): tiles are `gallery-video-cell-0`, `-1`, ... with a label like
   `Video thumbnail, video duration: 0:52, WEDNESDAY, SEPTEMBER 23, 2026`. Pick by duration and
   date, not by position: the order shifts whenever a new file lands.
5. Editor: `tap-el sundial-right-chevron-next-button`. Change nothing else.
6. Share screen: `tap-el caption-cell-text-view`, then `type` the caption, then `els` and confirm
   the TextView's value starts with the caption. **Stop here. Screenshot. Show the user.**
7. Only after the user's yes: `tap-el share-sheet-share-button`. Instagram uploads in the
   background; confirm on the profile (or through a read-only API call) before saying it is live.

## Testing Nomorediet on the phone

The app is installed through SideStore or Impactor, so its bundle id is `app.piatto.ios` plus the team suffix:
use `launch nomorediet` (or `apps piatto` to see the real id). Save every screenshot of a run
in `iphone-runs/<date>-<what>/` (ignored by git) and show the important ones to the user.

Stable accessibility ids (set in the SwiftUI code with `.accessibilityIdentifier`, version 4.11):

| Screen | id | What it is |
|---|---|---|
| Tab bar | `tab-oggi`, `tab-progressi`, `tab-allenamento`, `tab-coach`, `tab-profilo` | the five tabs (labels Oggi, Progressi, … work too) |
| Oggi | `say-meal-text` | "Cosa hai mangiato?" text field |
| Oggi | `say-meal-mic` | hold to speak (a long press: `tap` is not enough, use a swipe of 0 px with duration, or type instead) |
| Oggi | `say-meal-send` | analyse with the chosen AI and add to the right meals |
| Aggiungi alimento | `scan-text`, `scan-text-search` | read the product name from the pack |
| Allenamento | `workout-prev`, `workout-next`, `workout-start` | "Oggi tocca" card |
| Allenamento | `rest-start-<label>`, `workout-finish` | rest timer of a jump set, end the workout |
| Profilo | `gemini-login` | sign in with Google and connect Gemini |
| Importa da Salute | `health-export-pick` | pick export.zip / export.xml |

Shake gesture (debug panel): not available through WDA; open it with `open "nomorediet://debug"`.
