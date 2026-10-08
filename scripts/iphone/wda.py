#!/usr/bin/env python3
"""
Drive an iPhone from a computer over USB: real taps, swipes, typing, screenshots.

From the "Claude can control your old iPhone" kit (Mr. Paid Social), adapted for Nomorediet:
`apps` lists installed apps, WebDriverAgent is found by itself when WDA_BUNDLE_ID is not set
(SideStore adds a suffix to bundle ids), and process handling also works on Windows.

Talks straight to WebDriverAgent's HTTP API through a usbmux port-forward.
Standard library only. Run it with any python3.

    wda.py devices                  list the iPhones usbmux can see (proves the cable)
    wda.py up                       bring everything up (idempotent), open the lock screen, report
    wda.py down                     stop the runner + port-forward
    wda.py app                      what is in the foreground right now
    wda.py home                     go to the home screen (verified)
    wda.py unlock                   get past the lock screen via XCTest, never a swipe (no-passcode phone)
    wda.py apps [filter]            installed apps (bundle id + name), e.g. `apps piatto`
    wda.py launch <bundle-id>       e.g. com.apple.calculator, app.piatto.ios (or `launch nomorediet`)
    wda.py open <url>               open a URL or URL scheme on the phone (http://..., shortcuts://...)
    wda.py els [--all]              compact list of on-screen elements (names + centres)
    wda.py tap-el "<name>"          tap by accessibility id (preferred)
    wda.py tap <x> <y>              tap a point (POINTS: an iPhone 16 Pro screen is 402 x 874)
    wda.py swipe <x1> <y1> <x2> <y2> [--dur 0.15]
    wda.py type "<text>"            types into whatever has focus
    wda.py shot <out.png> [--small] screenshot (--small also writes a 340px .jpg)

CONFIG (environment variables, all optional)
    IPHONE_UDID       the phone to drive; default = the first device `pymobiledevice3 usbmux list` shows
    WDA_BUNDLE_ID     the bundle id you built WebDriverAgent with (default com.example.WebDriverAgentRunner)
    WDA_RUNNER_APP    path to WebDriverAgentRunner-Runner.app (default: the build-wda.sh output)
    PYMOBILEDEVICE3   path to the pymobiledevice3 CLI if it is not on PATH

RULES
  * A zero exit code is NOT evidence. WDA and the pymobiledevice3 CLI both report
    success for gestures that did nothing. After anything that matters, run `app`
    or `shot` and look.
  * Accessibility first: `els` then `tap-el`. Coordinates only when an element has
    no name. Coordinates are POINTS, not screenshot pixels (x3 on a 16 Pro).
  * Never type a passcode or a password. A phone with no passcode is unlocked by `up` and
    `unlock` (through XCTest, never a swipe); a phone WITH one is a human's to unlock. Logins
    belong to a human.
  * Posting or sending anything needs a human's approval of that specific post.

WHY NOT the `pymobiledevice3 developer wda ...` CLI: every call without --session-id
opens a new WDA session (~3 s each) and a session bound to an app re-activates that
app, so `press home` followed by any other command lands you back where you started.
One cached, app-less session over HTTP is ~10x faster and does what it says.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PORT = 8100
BASE = f"http://localhost:{PORT}"
TMP = tempfile.gettempdir()
SESSION_FILE = os.path.join(TMP, "iphone-wda-session")
STATE_FILE = os.path.join(TMP, "iphone-wda-udid")      # the phone `up` last started, so `down` still works after an unplug
RUNNER_LOG = os.path.join(TMP, "wda-runner.log")
FORWARD_LOG = os.path.join(TMP, "wda-forward.log")
SPRINGBOARD = "com.apple.springboard"
WINDOWS = os.name == "nt"

BUNDLE = os.environ.get("WDA_BUNDLE_ID", "")
RUNNER = f"{BUNDLE}.xctrunner" if BUNDLE else ""    # empty: found among the installed apps by `up`
RUNNER_APP = os.path.expanduser(os.environ.get(
    "WDA_RUNNER_APP",
    "~/Developer/wda-build/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"))


def find_pmd3():
    for cand in (os.environ.get("PYMOBILEDEVICE3"),
                 shutil.which("pymobiledevice3"),
                 shutil.which("pymobiledevice3.exe"),
                 os.path.expanduser("~/Library/Python/3.14/bin/pymobiledevice3"),
                 os.path.expanduser("~/Library/Python/3.13/bin/pymobiledevice3"),
                 os.path.expanduser("~/Library/Python/3.12/bin/pymobiledevice3")):
        if cand and os.path.exists(cand):
            return cand
    sys.exit("pymobiledevice3 not found. Install it: python3 -m pip install -U pymobiledevice3 "
             "(then put its bin folder on PATH or set PYMOBILEDEVICE3=/path/to/pymobiledevice3)")


PMD3 = find_pmd3()
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


def pmd3(*args, timeout=30):
    try:
        r = subprocess.run([PMD3, *args], capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return None, ""


def list_devices():
    rc, out = pmd3("usbmux", "list", "--usb", timeout=20)
    try:
        start = out.index("[")
        return json.loads(out[start:])
    except (ValueError, json.JSONDecodeError):
        return []


def resolve_udid():
    udid = os.environ.get("IPHONE_UDID")
    if udid:
        return udid
    devs = list_devices()
    if devs:
        d = devs[0]
        return d.get("UniqueDeviceID") or d.get("Identifier")
    try:
        return open(STATE_FILE).read().strip() or None
    except OSError:
        return None


UDID = resolve_udid()
# Process patterns are scoped to this UDID + port so a second device's runner or forwarder
# is never mistaken for ours, and `down` never kills someone else's. With no UDID at all
# (nothing plugged in, nothing remembered) `down` falls back to the port-wide patterns.
HOST_PAT = f"dvt xcuitest .*{UDID}" if UDID else "dvt xcuitest"
FWD_PAT = f"usbmux forward {PORT} {PORT} .*{UDID}" if UDID else f"usbmux forward {PORT} {PORT}"


def http(method, path, body=None, timeout=30):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"value": {"error": f"http {e.code}"}}


def ready():
    try:
        return bool(http("GET", "/status", timeout=4)["value"].get("ready"))
    except Exception:
        return False


def new_session():
    # No bundleId on purpose: an app-bound session re-activates its app.
    sid = http("POST", "/session", {"capabilities": {"alwaysMatch": {}}})["sessionId"]
    with open(SESSION_FILE, "w") as fh:
        fh.write(sid)
    return sid


def session():
    try:
        sid = open(SESSION_FILE).read().strip()
        if sid:
            return sid
    except OSError:
        pass
    return new_session()


def in_session(method, path, body=None):
    """Call a session-scoped endpoint, renewing a stale session once."""
    out = http(method, f"/session/{session()}{path}", body)
    err = out.get("value") if isinstance(out.get("value"), dict) else None
    if err and "invalid session" in str(err.get("error", "")).lower():
        out = http(method, f"/session/{new_session()}{path}", body)
    return out


def failed(out):
    v = out.get("value")
    return isinstance(v, dict) and "error" in v


def active(timeout=30):
    return http("GET", "/wda/activeAppInfo", timeout=timeout)["value"].get("bundleId")


def active_or_unknown():
    """For status lines only: a TikTok feed never idles, and activeAppInfo on it can hang."""
    try:
        return active(timeout=10)
    except Exception:
        return "unknown (WDA busy; a TikTok feed in front wedges activeAppInfo)"


def is_locked():
    v = http("GET", "/wda/locked", timeout=8)["value"]
    if not isinstance(v, bool):
        raise RuntimeError(f"/wda/locked did not answer true/false: {v}")
    return v


def passcode_on():
    """lockdown's PasswordProtected: True / False, or None when unknown (e.g. the Trust dialog is up)."""
    _, out = pmd3("lockdown", "info", "--udid", UDID, timeout=20)
    m = re.search(r'"PasswordProtected":\s*(true|false)', out or "")
    return m.group(1) == "true" if m else None


def unlock(clear_lock_screen=False):
    """Get past the lock screen of a passcode-free phone; leaves the home screen in front.
    Returns (ok, message).

    `/wda/homescreen` has XCTest bring SpringBoard forward, and on a passcode-free phone that
    unlocks through the OS's own path. NEVER swipe a locked screen instead: on an iPhone 16 Pro
    (iOS 26) every synthesized swipe that dismissed a locked screen left the phone WEDGED (a dim
    layer over everything, every tap dead) until the next lock or a reboot. `/wda/unlock` (two
    Home presses) is the fallback for home-button phones.

    clear_lock_screen: also press Home when /wda/locked reads false but SpringBoard is in front.
    After a reboot the lock screen shows in exactly that state, and Home clears it. Off for the
    idempotent `up`, so a Spotlight or App Library step in progress is never disturbed."""
    if not is_locked():
        if clear_lock_screen and active(timeout=10) == SPRINGBOARD:
            out = http("POST", "/wda/homescreen", {}, timeout=40)
            if failed(out):
                return False, f"FAILED: could not bring the home screen forward: {json.dumps(out['value'])[:200]}"
        return True, "already unlocked"
    for path in ("/wda/homescreen", "/wda/unlock"):
        try:
            http("POST", path, {}, timeout=40)
        except Exception:
            pass  # is_locked() is the judge
        time.sleep(1.0)
        if not is_locked():
            return True, "unlocked"
    pw = passcode_on()
    if pw:
        return False, "BLOCKED: still locked, and the phone has a passcode. Only a human unlocks it."
    return False, (f"FAILED: still locked (passcode {'off' if pw is False else 'state unknown'}). "
                   "Look with `wda.py shot`. Do not swipe the lock screen (it wedges the phone); a "
                   "reboot comes back unlocked: `pymobiledevice3 diagnostics restart`, then `wda.py up`.")


def detach(args, log):
    fh = open(log, "w")
    if WINDOWS:
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        subprocess.Popen([PMD3, *args], stdout=fh, stderr=subprocess.STDOUT, creationflags=flags)
    else:
        subprocess.Popen([PMD3, *args], stdout=fh, stderr=subprocess.STDOUT, start_new_session=True)


def _windows_pids(pattern):
    """Process ids whose command line matches the regex (Windows has no pgrep)."""
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $env:WDA_PAT -and "
          "$_.CommandLine -notmatch 'Get-CimInstance' } | ForEach-Object { $_.ProcessId }")
    r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True,
                       env={**os.environ, "WDA_PAT": pattern})
    return [int(x) for x in r.stdout.split() if x.isdigit() and int(x) != os.getpid()]


def running(pattern):
    if WINDOWS:
        return bool(_windows_pids(pattern))
    return subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0


def kill(pattern):
    if WINDOWS:
        for pid in _windows_pids(pattern):
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    else:
        subprocess.run(["pkill", "-f", pattern])


def installed_apps():
    """{bundle id: name} of the user apps on the phone."""
    rc, out = pmd3("apps", "list", "--udid", UDID, timeout=90)
    try:
        apps = json.loads(out[out.index("{"):])
    except (ValueError, json.JSONDecodeError):
        return {}
    return {bid: (info or {}).get("CFBundleDisplayName") or (info or {}).get("CFBundleName") or ""
            for bid, info in apps.items()}


def find_runner(apps):
    """The WebDriverAgent runner's bundle id: as built (WDA_BUNDLE_ID), or as SideStore renamed it."""
    if RUNNER and RUNNER in apps:
        return RUNNER
    found = sorted(b for b in apps if "webdriveragentrunner" in b.lower() and "xctrunner" in b.lower())
    return found[0] if found else ""


def start_forwarder():
    detach(["usbmux", "forward", str(PORT), str(PORT), "--serial", UDID], FORWARD_LOG)
    time.sleep(3)


def start_host():
    detach(["developer", "dvt", "xcuitest", RUNNER, "--udid", UDID], RUNNER_LOG)


def cmd_apps(filt):
    apps = installed_apps()
    if not apps:
        print("could not list the apps (is the phone on the cable and trusted?)")
        return 1
    for bid, name in sorted(apps.items()):
        if not filt or filt.lower() in bid.lower() or filt.lower() in name.lower():
            print(f"{bid:<55} {name}")
    return 0


def resolve_app(target):
    """A bundle id, or part of an app's name or id (`nomorediet`, `piatto`): SideStore renames bundle ids."""
    apps = installed_apps()
    if target in apps:
        return target
    hits = [b for b, n in apps.items() if target.lower() in b.lower() or target.lower() == n.lower()]
    return sorted(hits, key=len)[0] if hits else target


def stop_wda():
    """Stop WDA on the phone AND its Mac-side test host. Returns True once it is really gone."""
    try:
        # GET, not POST (FBWebServer.m registers `get:@"/wda/shutdown"`); the body is plain text.
        urllib.request.urlopen(BASE + "/wda/shutdown", timeout=8).read()
    except Exception:
        pass
    kill(HOST_PAT)
    try:
        os.remove(SESSION_FILE)
    except OSError:
        pass
    for _ in range(20):
        if not ready():
            return True
        time.sleep(1)
    return False


def cmd_devices():
    devs = list_devices()
    if not devs:
        print("no iPhone on USB. Data cable (not charge-only)? Plugged straight into the Mac? Trusted?")
        return 2
    for d in devs:
        print(f"{d.get('UniqueDeviceID') or d.get('Identifier')}  {d.get('DeviceName')}  "
              f"iOS {d.get('ProductVersion')}  {d.get('ProductType')}")
    return 0


def cmd_up():
    if not UDID:
        print("BLOCKED: no iPhone on USB (data cable? plugged into the Mac?). Try: wda.py devices")
        return 2
    if ready() and running(FWD_PAT) and running(HOST_PAT):
        return report_up("already up")
    # A changed or removed passcode wipes trust, and `lockdown info` then HANGS on the
    # phone's Trust dialog instead of failing -- hence the hard timeout.
    rc, out = pmd3("lockdown", "info", "--udid", UDID, timeout=20)
    if rc is None:
        print("BLOCKED: the phone is showing 'Trust This Computer?'. A human taps Trust.")
        return 2
    if '"DeviceName"' not in out:
        print("BLOCKED: no paired iPhone on USB (data cable? plugged into the Mac?).")
        return 2
    rc, out = pmd3("mounter", "list", "--udid", UDID, timeout=40)
    if "Personalized" not in (out or ""):
        print("mounting DeveloperDiskImage…")
        pmd3("mounter", "auto-mount", "--udid", UDID, timeout=180)
    if not running(FWD_PAT):
        start_forwarder()
    if ready() and not running(HOST_PAT):
        # Checked only now that the forwarder exists: without it an orphan is invisible.
        # WDA answering with no Mac-side test host is an ORPHAN: iOS reaps it within about a
        # minute. Trusting one produces a fake "cold start".
        print("found an orphaned WDA (no test host attached): restarting it cleanly…")
        if not stop_wda():
            print("FAILED: the orphaned WDA would not shut down.")
            return 1
    global RUNNER
    if not ready():
        RUNNER = find_runner(installed_apps())
        if not RUNNER:
            # devicectl would need Apple's separate CoreDevice pairing; this uses lockdown.
            if not os.path.exists(RUNNER_APP):
                print(f"FAILED: WebDriverAgent is not on the phone and {RUNNER_APP} does not exist. "
                      "Run build-wda.sh first (or set WDA_RUNNER_APP).")
                return 1
            if not BUNDLE:
                print("FAILED: WebDriverAgent is not on the phone. Install it (SideStore on a PC, or build-wda.sh "
                      "on a Mac and set WDA_BUNDLE_ID).")
                return 1
            print("installing WebDriverAgent…")
            pmd3("apps", "install", RUNNER_APP, "--udid", UDID, timeout=300)
            RUNNER = f"{BUNDLE}.xctrunner"
        for attempt in (1, 2):
            if not running(HOST_PAT):
                start_host()
            for _ in range(30):
                if ready():
                    break
                time.sleep(2)
            if ready() or attempt == 2:
                break
            # Right after a reboot the first runner can die with "DTX capability handshake timed
            # out" in the runner log; a second start works.
            print("runner did not come up (fresh boot?): retrying once…")
            kill(HOST_PAT)
            time.sleep(20)
    if not (ready() and running(HOST_PAT)):
        why = " The phone has a passcode: if it is locked, unlock it by hand." if passcode_on() else ""
        print(f"FAILED: WDA never came up with its host attached, two tries. See {RUNNER_LOG}.{why} "
              f"Bundle id right? (runner {RUNNER or 'not found'}, WDA_BUNDLE_ID={BUNDLE or 'not set'})")
        return 1
    new_session()
    with open(STATE_FILE, "w") as fh:
        fh.write(UDID)
    return report_up("up", fresh=True)


def report_up(state, fresh=False):
    """`up` means ready to drive, which on a passcode-free phone includes the lock screen."""
    try:
        # Fresh start = WDA was not running, typically after a reboot: clear the lock screen then.
        ok, msg = unlock(clear_lock_screen=fresh)
    except Exception as e:
        print(f"{state}, but the lock check failed: {e}")
        return 1
    if not ok:
        print(f"{state}, but {msg}")
        return 2
    print(f"{state}. screen: {msg}. foreground: {active_or_unknown()}")
    return 0


def cmd_unlock():
    """Get past the lock screen through XCTest, never a swipe. Only possible on a phone with NO
    passcode; with a passcode this reports BLOCKED."""
    try:
        ok, msg = unlock(clear_lock_screen=True)
    except Exception as e:
        print(f"FAILED: could not read or change the lock state: {e}")
        return 1
    print(f"{msg}. foreground: {active_or_unknown()}" if ok else msg)
    return 0 if ok else 2


def cmd_home():
    http("POST", "/wda/homescreen")
    time.sleep(1.0)
    if active() != SPRINGBOARD and not is_locked():
        # Spotlight and some sheets ignore the button on a Face ID phone: do the edge swipe.
        # Never on a locked screen: a swipe that unlocks the phone wedges it (see unlock()).
        in_session("POST", "/wda/dragfromtoforduration",
                   {"fromX": 201, "fromY": 872, "toX": 201, "toY": 420, "duration": 0.08})
        time.sleep(1.2)
    fg = active()
    print(f"foreground: {fg}")
    return 0 if fg == SPRINGBOARD else 1


def cmd_els(show_all):
    def walk(n, acc):
        name, label = n.get("name"), n.get("label")
        if (show_all or n.get("isVisible") == "1") and (name or label):
            r = n.get("rect", {})
            cx = r.get("x", 0) + r.get("width", 0) // 2
            cy = r.get("y", 0) + r.get("height", 0) // 2
            kind = (n.get("type") or "").replace("XCUIElementType", "")
            acc.append(f"{kind:<14} {str(name)[:38]:<38} "
                       f"{str(label)[:26] if label != name else '':<26} @{cx},{cy}"
                       + (f"  ={str(n.get('value'))[:24]}" if n.get("value") else ""))
        for c in n.get("children", []) or []:
            walk(c, acc)
    src = http("GET", "/source?format=json", timeout=90)["value"]
    rows = []
    walk(src, rows)
    print(f"# foreground: {active()}   ({len(rows)} elements; type / name / label / centre in POINTS)")
    print("\n".join(rows))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    cmd, a = argv[1], argv[2:]
    if cmd == "devices":
        return cmd_devices()
    if cmd == "up":
        return cmd_up()
    if cmd == "apps":
        return cmd_apps(a[0] if a else "")
    if cmd == "down":
        gone = stop_wda()
        kill(FWD_PAT)
        try:
            os.remove(STATE_FILE)
        except OSError:
            pass
        print("down" if gone else "FAILED: WDA is still answering after shutdown + host kill")
        return 0 if gone else 1
    if not ready():
        print("WDA is not up. Run: wda.py up")
        return 1
    if not running(FWD_PAT):
        # WDA answers on the port, but not through a forwarder for THIS phone: with two phones
        # around, every tap below would land on the other one.
        if running(f"usbmux forward {PORT} {PORT}"):
            print(f"BLOCKED: port {PORT} is forwarded to a different phone than {UDID}. "
                  "Run `wda.py down` for that phone first (IPHONE_UDID=<its udid>).")
        else:
            print("BLOCKED: WDA answers but no forwarder for this phone is running. Run: wda.py up")
        return 2

    if cmd == "app":
        print(json.dumps(http("GET", "/wda/activeAppInfo")["value"], indent=2))
        return 0
    if cmd == "home":
        return cmd_home()
    if cmd == "unlock":
        return cmd_unlock()
    if cmd == "els":
        return cmd_els("--all" in a)
    if cmd == "launch":
        out = in_session("POST", "/wda/apps/launch", {"bundleId": resolve_app(a[0])})
    elif cmd == "open":
        # XCTest's openURL: http(s) links open in Safari, URL schemes open their app.
        out = in_session("POST", "/url", {"url": a[0]})
    elif cmd == "tap-el":
        # An element id is only valid inside the session that found it, so a renewal between
        # lookup and click would click a dead id. Pin one session for both; retry the PAIR once.
        for attempt in (1, 2):
            sid = session() if attempt == 1 else new_session()
            found = http("POST", f"/session/{sid}/elements", {"using": "accessibility id", "value": a[0]})
            els = found.get("value")
            if isinstance(els, list) and els:
                eid = els[0].get("ELEMENT") or next(iter(els[0].values()))
                out = http("POST", f"/session/{sid}/element/{eid}/click")
                if not (failed(out) and "invalid session" in str(out["value"].get("error", "")).lower()):
                    break
            elif isinstance(els, list):
                print(f"no element with accessibility id {a[0]!r}: run `els`")
                return 1
            out = found
    elif cmd == "tap":
        out = in_session("POST", "/wda/tap", {"x": float(a[0]), "y": float(a[1])})
    elif cmd == "swipe":
        dur = float(a[a.index("--dur") + 1]) if "--dur" in a else 0.15
        x1, y1, x2, y2 = (float(v) for v in a[:4])
        out = in_session("POST", "/wda/dragfromtoforduration",
                         {"fromX": x1, "fromY": y1, "toX": x2, "toY": y2, "duration": dur})
    elif cmd == "type":
        out = in_session("POST", "/wda/keys", {"value": list(a[0])})
    elif cmd == "shot":
        png = base64.b64decode(http("GET", "/screenshot", timeout=60)["value"])
        with open(a[0], "wb") as fh:
            fh.write(png)
        print(f"wrote {a[0]} ({len(png)} bytes)")
        if "--small" in a and os.path.exists(FFMPEG):
            small = os.path.splitext(a[0])[0] + ".small.jpg"
            subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", a[0],
                            "-vf", "scale=340:-1", small])
            print(f"wrote {small}")
        return 0
    else:
        print(f"unknown command {cmd!r}")
        return 2

    if failed(out):
        print("FAILED:", json.dumps(out["value"])[:300])
        return 1
    print(f"ok. foreground: {active()}   (verify with `shot`: ok is not proof)")
    return 0


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # `wda.py els | head` must not traceback
    sys.exit(main(sys.argv))
