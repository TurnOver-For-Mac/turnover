#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
r"""Run a key-driver scenario and check what TurnOver said (SHAKE-OUT-PLAN.md, 8 Oct 2026).

  scenario.py <file.txt> [--mask 0|1]      (mask 1: spoken words masked in the report; default 1)

A scenario file:
  app: Mail                      the app that must be in front (opened with `open -a` if not running)
  open: /path/or/arg             optional: what to open with the app (a scratch file)
  style: windows                 optional: run in this keyboard style (switched with Command Control Comma, then K, and back after)
  press: down down               keys for the drive tool, as its arguments
  wait: 1.5                      seconds
  expect: ^.*, \d+ of \d+$       a regex one of the speech lines since the last press must match
  expect-script: list_downArrow  a script that must have run since the last press
  expect-not: new line           a regex no speech line since the last press may match
  expect-log: typed key          a regex one of TurnOver's log lines since the last press must match
  shell: kill -STOP $(pgrep -x TextEdit)   a command (chaos cases); output shown, not checked
  # comments and blank lines are ignored
Exit 0 when every expectation held, 1 otherwise, 3 if the user is active, 4 if the app is not in front.
"""
import sys, os, re, subprocess, time, glob
T = os.environ.get("TURNOVER_TOOLS") or os.path.expanduser("~/Library/Developer/TurnOver/tools")   # the built tools; sources in the repo (Tools/drivers)
LOGS = os.path.expanduser("~/Library/Application Support/TurnOver/logs")
args = sys.argv[1:]
mask = "1"
if "--mask" in args: i = args.index("--mask"); mask = args[i + 1]; del args[i:i + 2]
path = args[0]

def idle():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 999
def front():
    r = subprocess.run(["osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true'], capture_output=True, text=True)
    return r.stdout.strip()
def turnover_toggled_within(seconds):
    """True if TurnOver's newest log says it posted the VoiceOver toggle in the last `seconds` (the log's timestamps
    are seconds since launch; the launch time is in the file's name, UTC)."""
    try:
        f = newest_log()
        m = re.search(r"turnover-(\d{4})-(\d{2})-(\d{2})T(\d{2})(\d{2})(\d{2})Z\.log$", f)
        if not m: return False
        import calendar
        start = calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0))
        last = None
        for line in open(f, errors="replace"):
            if "hand-over: posted toggle shortcut" in line:
                t = re.match(r"\[\s*([0-9.]+)\]", line)
                if t: last = start + float(t.group(1))
        return last is not None and time.time() - last < seconds
    except Exception:
        return False

def newest_log():
    return max(glob.glob(os.path.join(LOGS, "*.log")), key=os.path.getmtime)
def masked(s):
    if mask != "1": return s
    return re.sub(r"[A-Za-zÀ-ɏ؀-ۿ]+", "x", s)

steps = []
app = None; opener = None; style = None; launcher = None
for raw in open(path):
    line = raw.strip()
    if not line or line.startswith("#"): continue
    k, _, v = line.partition(":")
    k = k.strip(); v = v.strip()
    if k == "app": app = v
    elif k == "open": opener = v
    elif k == "mask": mask = v      # mask: 0 for the test's own files (Day 2, 10 Oct 2026); the default masks
    elif k == "launch": launcher = v  # launch: what `open -a` needs when the process name differs (UlyssesMac.app → Ulysses)
    elif k == "style": style = v   # mac or windows: switched with Command Control Comma, then K before the run, and back after
    else: steps.append((k, v))
if not app: print("no app:"); sys.exit(2)

our_last = float(open("/tmp/to-drive-at").read()) if os.path.exists("/tmp/to-drive-at") else 0
since = time.time() - our_last
i = idle()
if i < 25 and since - i > 3: print(f"USER ACTIVE ({int(i)} s idle, ours {int(since)} s ago)"); sys.exit(3)
# A scenario with something to open opens it every time (the app may be in front with no window left after the
# previous scenario's Command W: TurnOver E was "unbound" and nothing had the caret, 8 Oct 2026).
if opener or front() != app:
    # An app that isn't on this Mac (Excel went, 25 Oct 2026): exit 7, which day-test.sh treats as a skip, not a stop.
    r = subprocess.run(["open", "-a", launcher or app] + ([opener] if opener else []), capture_output=True, text=True)
    if r.returncode != 0 and "Unable to find" in (r.stderr + r.stdout): print(f"not installed here: {app}"); sys.exit(7)
    time.sleep(4 if front() != app else 2.5)
    # A cold start can take longer (Word and Excel on 16 Oct 2026 weren't in front after 4 s): up to 12 s more.
    for _ in range(24):
        if front() == app: break
        time.sleep(0.5)
    if front() != app: print(f"FRONT IS {front()}, not {app}"); sys.exit(4)
    # Opening an app VoiceOver reads makes TurnOver switch VoiceOver on, with keys: that activity is the test's, not
    # the user's (12 Oct 2026: the run stopped at once, "user active, 0 s idle").
    open("/tmp/to-drive-at", "w").write(str(int(time.time())))

SETTINGS = os.path.expanduser("~/Library/Application Support/TurnOver/settings.json")
def current_style():
    # Read again on a failure rather than guessing "mac": a guess left the Mac in the Windows style after a run
    # (12 Oct 2026: the end switch thought it was already back and sent nothing).
    import json
    for _ in range(5):
        try: return json.load(open(SETTINGS))["general"]["keyboardStyle"]
        except Exception: time.sleep(0.3)
    return "unknown"
started_style = current_style()
def switch_style(to):
    time.sleep(1.0)   # let TurnOver finish saving whatever the last key changed
    if current_style() == to: return
    # K goes round three styles since build 22 (mac, windows, jaws): pressed until the wanted one comes, up to three
    # times. One press from windows landed on jaws and stopped seven parts of the pass (25 Oct 2026).
    for _ in range(3):
        subprocess.run([os.path.join(T, "drive"), "control+command+,", "k", "clearmods"])
        open("/tmp/to-drive-at", "w").write(str(int(time.time())))   # the switch is the test's key, not the user's (11 Oct 2026)
        time.sleep(1.2)
        if current_style() == to: return
    print(f"could not switch to the {to} style"); sys.exit(5)
if style: switch_style(style)
log = newest_log()
def log_len(): return sum(1 for _ in open(log, errors="replace"))
mark = log_len()
failures = 0; passed = 0
def slice_since(mark):
    lines = open(log, errors="replace").read().split("\n")[mark:]
    return lines
for k, v in steps:
    if k == "press":
        # Before every key, not only the first: another app can come to the front mid-run (a test Chrome did,
        # 10 Oct 2026), and the user can come back.
        if front() != app: print(f"FRONT IS {front()}, not {app}: nothing more is sent"); sys.exit(4)
        i = idle(); since = time.time() - float(open("/tmp/to-drive-at").read() or 0) if os.path.exists("/tmp/to-drive-at") else 999
        # TurnOver's own hand-over presses the VoiceOver toggle keys, which reset the idle clock as if the user had:
        # the runs on 16 Oct 2026 stopped three times on it. Its log line says when; within 2.5 s of it, the
        # activity is TurnOver's, not theirs.
        if i < 25 and since - i > 3 and turnover_toggled_within(2.5): since = i
        if i < 25 and since - i > 3: print(f"USER ACTIVE ({int(i)} s idle): nothing more is sent"); sys.exit(3)
        mark = log_len()
        subprocess.run([os.path.join(T, "drive")] + v.split())
        open("/tmp/to-drive-at", "w").write(str(int(time.time())))
        time.sleep(0.6)
    elif k == "wait":
        time.sleep(float(v))
    elif k == "shell":
        # A command for the chaos cases (kill -STOP an app, kill TurnOver): its output is shown, never checked.
        r = subprocess.run(v, shell=True, capture_output=True, text=True)
        print(f"  shell: {v} → {(r.stdout + r.stderr).strip()[:100]}")
    elif k in ("expect", "expect-not", "expect-script", "expect-log"):
        lines = slice_since(mark)
        said = [re.sub(r"^\[\s*[\d.]+\] IO say(?: \[[^\]]*\])?: ", "", l) for l in lines if " IO say" in l]
        # The edge tone, which has no words (VoiceOver's boundary sound), counts as an answer: "(edge)".
        said += ["(edge)" for l in lines if " IO review: edge" in l or " IO edge: " in l]   # the text's edge too (12 Oct 2026)
        scripts = [re.search(r"→ (\S+)", l).group(1) for l in lines if "IO input kb" in l and "→" in l]
        # "Pass next key" means the next key goes to the app as typed: stop before anything else is sent, the style
        # switch included (it typed a control character into Byword, 10 Oct 2026).
        if any(re.search(r"pass next key", s) for s in said):
            print("  STOP: TurnOver is passing the next key to the app; nothing more is sent"); sys.exit(6)
        if k == "expect":
            ok = any(re.search(v, s) for s in said)
        elif k == "expect-not":
            ok = not any(re.search(v, s) for s in said)
        elif k == "expect-log":
            ok = any(re.search(v, l) for l in lines)
        else:
            ok = any(re.fullmatch(v, sc) for sc in scripts)   # a name, or a regex such as chat_(toMessages|noChat.*)
        if ok:
            passed += 1; print(f"  ok   {k}: {v}")
            if os.environ.get("SHOW") == "1" and k == "expect":
                for s in said[:4]: print(f"       said: {masked(s)[:140]}")
        else:
            failures += 1
            print(f"  FAIL {k}: {v}")
            for s in said[:6]: print(f"       said: {masked(s)[:120]}")
            if k == "expect-script": print(f"       scripts: {scripts}")
if style: switch_style(started_style)
print(f"{os.path.basename(path)}: {passed} passed, {failures} failed" + (f" ({style} style)" if style else ""))
sys.exit(1 if failures else 0)
