#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lshell — Waybar panel switcher: panel position (top / bottom) and clock timezone.

Usage:
    python3 lshell.py                          # interface with a splash screen
    python3 lshell.py top|bottom|toggle        # apply panel position, no interface
    python3 lshell.py --tz Europe/Kyiv         # set the clock timezone, no interface
    python3 lshell.py -c ~/my/config           # use another config
    python3 lshell.py --no-splash              # skip the splash screen
    python3 lshell.py --no-restart             # only edit the config

No dependencies: Python 3.9+ standard library only.
"""
from __future__ import annotations

import argparse
import os
import re
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
from datetime import datetime
from functools import lru_cache
from pathlib import Path

try:
    from zoneinfo import ZoneInfo, available_timezones
except ImportError:  # Python < 3.9
    ZoneInfo = None
    available_timezones = None

VERSION = "1.1"

ESC = "\x1b"
RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"
TRUECOLOR = os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit")

CYAN = (0, 229, 255)
VIOLET = (150, 110, 255)
PINK = (255, 105, 200)
WHITE = (236, 240, 255)
GRAY = (130, 138, 160)
DARK = (62, 68, 90)
BAR_BG = (34, 42, 70)
GREEN = (80, 250, 123)
RED = (255, 95, 95)


def _q(v: int) -> int:
    return round(v / 255 * 5)


def fg(c) -> str:
    r, g, b = c
    if TRUECOLOR:
        return f"{ESC}[38;2;{r};{g};{b}m"
    return f"{ESC}[38;5;{16 + 36 * _q(r) + 6 * _q(g) + _q(b)}m"


def bg(c) -> str:
    r, g, b = c
    if TRUECOLOR:
        return f"{ESC}[48;2;{r};{g};{b}m"
    return f"{ESC}[48;5;{16 + 36 * _q(r) + 6 * _q(g) + _q(b)}m"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def grad(t: float):
    """'Liquid glass' gradient: cyan → violet → pink."""
    t = min(1.0, max(0.0, t))
    if t < 0.5:
        return lerp(CYAN, VIOLET, t * 2)
    return lerp(VIOLET, PINK, (t - 0.5) * 2)


def gradient_text(text: str) -> str:
    n = max(1, len(text) - 1)
    return "".join(fg(grad(i / n)) + ch for i, ch in enumerate(text)) + RESET


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def vlen(s: str) -> int:
    return len(ANSI_RE.sub("", s))


def pad(s: str, width: int) -> str:
    return s + " " * max(0, width - vlen(s))


def mid(s: str, width: int) -> str:
    free = max(0, width - vlen(s))
    left = free // 2
    return " " * left + s + " " * (free - left)


def center(s: str, cols: int) -> str:
    return " " * max(0, (cols - vlen(s)) // 2) + s



_L = ["██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"]
_S = ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"]
_H = ["██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"]
_E = ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"]
_GLYPHS = {"L": _L, "S": _S, "H": _H, "E": _E}
LOGO = ["".join(_GLYPHS[ch][i] for ch in "LSHELL") for i in range(6)]
LOGO_W = len(LOGO[0])


def paint_logo(visible: int = 6) -> list[str]:
    out = []
    for r, row in enumerate(LOGO):
        if r >= visible:
            out.append("")
            continue
        s = ""
        for x, ch in enumerate(row):
            if ch == " ":
                s += ch
                continue
            col = grad(x / (LOGO_W - 1) * 0.8 + r / 5 * 0.2)
            if ch != "█":  # letter "shadow" is a bit darker
                col = tuple(int(v * 0.55) for v in col)
            s += fg(col) + ch
        out.append(s + RESET)
    return out


def bar(frac: float, width: int = 36) -> str:
    n = int(round(frac * width))
    s = ""
    for i in range(width):
        if i < n:
            s += fg(grad(i / (width - 1))) + "━"
        else:
            s += fg(DARK) + "━"
    return f"{s}{RESET} {BOLD}{int(frac * 100):3d}%{RESET}"


def out(s: str) -> None:
    sys.stdout.write(s)
    sys.stdout.flush()


def render(lines: list[str]) -> None:
    cols, rows = shutil.get_terminal_size((80, 24))
    top = max(0, (rows - len(lines)) // 2)
    frame = ([""] * top + lines)[:rows]
    body = "\n".join(center(l, cols) + f"{ESC}[K" for l in frame)
    out(f"{ESC}[H{body}{ESC}[J")


class Term:
    def __enter__(self):
        self.fd = sys.stdin.fileno()
        self.old = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        out(f"{ESC}[?1049h{ESC}[?25l{ESC}[2J")
        return self

    def __exit__(self, *exc):
        out(f"{ESC}[0m{ESC}[?25h{ESC}[?1049l")
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old)

    def key(self, timeout: float = 0.1, text: bool = False):
        """Return a key name. With text=True, typed text comes back as '\\0' + text."""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return None
        data = os.read(self.fd, 64 if text else 8)
        table = {
            b"\x1b[A": "up", b"\x1bOA": "up",
            b"\x1b[B": "down", b"\x1bOB": "down",
            b"\x1b[C": "right", b"\x1bOC": "right",
            b"\x1b[D": "left", b"\x1bOD": "left",
            b"\x1b": "esc", b"\r": "enter", b"\n": "enter",
            b" ": "space", b"\t": "tab", b"\x03": "esc",
            b"\x7f": "backspace", b"\x08": "backspace",
        }
        if text:
            if data in table and data != b" ":
                return table[data]
            if data.startswith(b"\x1b"):
                return None
            try:
                return "\0" + data.decode("utf-8")
            except UnicodeDecodeError:
                return None
        if data in table:
            return table[data]
        try:
            return data.decode("utf-8").lower()
        except UnicodeDecodeError:
            return None


POS_RE = re.compile(r'("position"\s*:\s*")(\w+)(")')
TZ_RE = re.compile(r'("timezones"\s*:\s*\[)(.*?)(\])', re.S)
CLOCK_RE = re.compile(r'"clock"\s*:\s*\{')
MAX_TZ = 8  # how many timezones stay in the clock's cycling list


def find_config(arg: str | None) -> Path | None:
    if arg:
        p = Path(arg).expanduser()
        return p if p.is_file() else None
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "waybar"
    for name in ("config", "config.jsonc"):
        if (base / name).is_file():
            return base / name
    return None


def backup(path: Path) -> None:
    shutil.copy2(path, path.with_name(path.name + ".bak"))


def read_position(path: Path) -> str | None:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("//"):
            continue
        m = POS_RE.search(line)
        if m:
            return m.group(2)
    return None


def write_position(path: Path, pos: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    found = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("//"):
            continue
        if POS_RE.search(line):
            lines[i] = POS_RE.sub(lambda m: f"{m.group(1)}{pos}{m.group(3)}", line)
            found = True
    if not found:
        for i, line in enumerate(lines):
            if "{" in line and not line.lstrip().startswith("//"):
                lines.insert(i + 1, f'  "position": "{pos}",\n')
                break
    backup(path)
    path.write_text("".join(lines), encoding="utf-8")


def read_timezones(path: Path) -> list[str]:
    m = TZ_RE.search(path.read_text(encoding="utf-8"))
    return re.findall(r'"([^"]+)"', m.group(2)) if m else []


def write_timezone(path: Path, zone: str) -> None:
    """Make `zone` the first (active) entry of the clock's "timezones" list."""
    text = path.read_text(encoding="utf-8")
    m = TZ_RE.search(text)
    if m:
        zones = re.findall(r'"([^"]+)"', m.group(2))
        new = ([zone] + [z for z in zones if z != zone])[:MAX_TZ]
        line_start = text.rfind("\n", 0, m.start()) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        body = "\n" + ",\n".join(f'{indent}  "{z}"' for z in new) + "\n" + indent
        text = text[:m.start(2)] + body + text[m.end(2):]
    else:
        c = CLOCK_RE.search(text)
        if not c:
            raise ValueError('no "clock" module found in the config')
        line_start = text.rfind("\n", 0, c.start()) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        inner = indent + "  "
        insert = f'\n{inner}"timezones": [\n{inner}  "{zone}"\n{inner}],'
        text = text[:c.end()] + insert + text[c.end():]
    backup(path)
    path.write_text(text, encoding="utf-8")


def waybar_running() -> bool:
    if not shutil.which("pgrep"):
        return False
    return subprocess.run(["pgrep", "-x", "waybar"], stdout=subprocess.DEVNULL).returncode == 0


def restart_waybar(cfg: Path, custom_cfg: bool) -> tuple[bool, str]:
    if not shutil.which("waybar"):
        return False, "waybar not found in PATH"
    if shutil.which("pkill"):
        subprocess.run(["pkill", "-x", "waybar"], stderr=subprocess.DEVNULL)
        for _ in range(30):
            if not waybar_running():
                break
            time.sleep(0.05)
    cmd = ["waybar"]
    if custom_cfg:
        cmd += ["-c", str(cfg)]
        style = cfg.with_name("style.css")
        if style.is_file():
            cmd += ["-s", str(style)]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(0.5)
    if waybar_running():
        return True, "Waybar restarted"
    return False, "Waybar failed to start — run waybar in a terminal to check the config"


ALIASES = {"europe/kyiv": "europe/kiev", "europe/kiev": "europe/kyiv"}


@lru_cache(maxsize=1)
def all_zones() -> tuple[str, ...]:
    zones: set[str] = set()
    if available_timezones:
        try:
            zones = set(available_timezones())
        except Exception:
            zones = set()
    if not zones:
        root = Path("/usr/share/zoneinfo")
        if root.is_dir():
            for p in root.rglob("*"):
                if p.is_file():
                    zones.add(p.relative_to(root).as_posix())
    skip = ("posix/", "right/", "Etc/", "SystemV/")
    return tuple(sorted(z for z in zones
                        if "/" in z and not z.startswith(skip) and "." not in z.rsplit("/", 1)[-1]))


def normalize(text: str) -> str:
    return text.strip().replace(" ", "_").lower()


def resolve_zone(text: str) -> str | None:
    """Exact (case-insensitive) match of 'Continent/City' → canonical zone name."""
    t = normalize(text)
    if not t:
        return None
    lookup = {z.lower(): z for z in all_zones()}
    return lookup.get(t) or lookup.get(ALIASES.get(t, ""))


def suggest(text: str, limit: int = 6) -> list[str]:
    t = normalize(text)
    if not t:
        return []
    ranked = []
    for z in all_zones():
        low = z.lower()
        city = low.rsplit("/", 1)[-1]
        if low.startswith(t):
            rank = 0
        elif city.startswith(t):
            rank = 1
        elif t in low:
            rank = 2
        else:
            continue
        ranked.append((rank, len(city), z))
    ranked.sort()
    return [z for _, _, z in ranked[:limit]]


def zone_time(zone: str | None) -> str:
    if not zone or ZoneInfo is None:
        return ""
    try:
        return datetime.now(ZoneInfo(zone)).strftime("%a %H:%M %Z")
    except Exception:
        return ""


NAMES = {"top": "Top", "bottom": "Bottom"}


def short(path: Path) -> str:
    return str(path).replace(str(Path.home()), "~", 1)


def card(pos: str, selected: bool, active: bool, w: int = 30) -> list[str]:
    inner = w - 2
    accent = grad(0.0 if pos == "top" else 1.0)
    b = fg(accent) if selected else fg(DARK)
    tl, h, tr, v, bl, br = ("╔", "═", "╗", "║", "╚", "╝") if selected else ("╭", "─", "╮", "│", "╰", "╯")

    def edge(l, r, m):
        return f"{b}{l}{m * inner}{r}{RESET}"

    def row(content=""):
        return f"{b}{v}{RESET}{mid(content, inner)}{b}{v}{RESET}"

    title = ("▲  " if pos == "top" else "▼  ") + NAMES[pos]
    tcol = (BOLD + fg(accent)) if selected else fg(GRAY)

    pw = inner - 4
    left_p, right_p = " ● 1 2 3", "us  21:11 "
    gap = max(0, pw - len(left_p) - len(right_p))
    dot = fg(accent if selected else GRAY)
    txt = fg(WHITE if selected else GRAY)
    bar_row = f"{bg(BAR_BG)}{dot} ●{txt} 1 2 3{' ' * gap}us  21:11 {RESET}"
    fill = f"{fg(DARK)}{'░' * pw}{RESET}"
    preview = [bar_row] + [fill] * 4 if pos == "top" else [fill] * 4 + [bar_row]

    if active:
        badge = f"{fg(GREEN)}● active{RESET}"
    elif selected:
        badge = f"{fg(accent)}Enter — apply{RESET}"
    else:
        badge = ""

    return ([edge(tl, tr, h), row(f"{tcol}{title}{RESET}"), row()]
            + [row(p) for p in preview]
            + [row(badge), edge(bl, br, h)])


def key_hint(k: str) -> str:
    return f"{BOLD}{fg(CYAN)}{k}{RESET}"


def build_main(state: dict) -> list[str]:
    cols, rows = shutil.get_terminal_size((80, 24))
    sel, active = state["sel"], state["active"]
    lines: list[str] = []

    if rows >= 30 and cols >= LOGO_W + 4:
        lines += paint_logo()
        lines += [f"{fg(GRAY)}Liquid Shell · panel switcher · v{VERSION}{RESET}", ""]
    else:
        lines += [f"{BOLD}{gradient_text('LSHELL')}{RESET} {fg(GRAY)}· panel{RESET}", ""]

    lines += [f"{BOLD}Waybar panel position{RESET}", f"{fg(GRAY)}{short(state['path'])}{RESET}", ""]

    if cols >= 66:
        a, b = card("top", sel == "top", active == "top"), card("bottom", sel == "bottom", active == "bottom")
        lines += [f"{x}    {y}" for x, y in zip(a, b)]
    else:
        for pos in ("top", "bottom"):
            accent = grad(0.0 if pos == "top" else 1.0)
            mark = f"{fg(accent)}❯{RESET}" if sel == pos else " "
            name = (BOLD + fg(accent) if sel == pos else fg(GRAY)) + ("▲ " if pos == "top" else "▼ ") + NAMES[pos] + RESET
            badge = f"  {fg(GREEN)}● active{RESET}" if active == pos else ""
            lines.append(f"{mark} {name}{badge}")

    tz = state["tz"]
    tz_text = f"{fg(CYAN)}{tz}{RESET} {fg(GRAY)}{zone_time(tz)}{RESET}" if tz else f"{fg(GRAY)}system local time{RESET}"
    lines += ["", f"{BOLD}Clock timezone{RESET}  {tz_text}"]

    kind, text = state["msg"]
    colour = {"ok": GREEN, "err": RED, "info": GRAY}[kind]
    lines += ["", f"{fg(colour)}{text}{RESET}" if text else "", ""]
    lines.append(f"{key_hint('←/→')} {fg(GRAY)}select{RESET}   {key_hint('Enter')} {fg(GRAY)}apply{RESET}   "
                 f"{key_hint('T')}{fg(GRAY)}/{RESET}{key_hint('B')} {fg(GRAY)}top/bottom{RESET}   "
                 f"{key_hint('C')} {fg(GRAY)}timezone{RESET}   "
                 f"{key_hint('Q')} {fg(GRAY)}quit{RESET}")
    return lines


def build_tz(state: dict) -> list[str]:
    W = 46
    buf = state["buf"]
    sug = suggest(buf, 6)
    pick = min(state["pick"], max(0, len(sug) - 1))

    lines = [f"{BOLD}{gradient_text('LSHELL')}{RESET} {fg(GRAY)}· clock timezone{RESET}", "",
             f"{BOLD}Type Continent/City{RESET}",
             f"{fg(GRAY)}e.g. Europe/Kyiv · America/New_York · Asia/Tokyo{RESET}", ""]

    caret = f"{fg(CYAN)}❯{RESET} {BOLD}{buf}{RESET}{fg(CYAN)}▌{RESET}"
    body = [pad(caret, W), f"{fg(DARK)}{'─' * W}{RESET}"]

    items: list[str] = []
    for i, z in enumerate(sug):
        t = zone_time(z)
        if i == pick:
            label = f"{fg(CYAN)}❯{RESET} {BOLD}{fg(CYAN)}{z}{RESET}"
        else:
            label = f"  {fg(WHITE)}{z}{RESET}"
        items.append(pad(label, W - 14) + fg(GRAY) + t.rjust(14) + RESET)
    if not buf:
        items = [pad(f"{fg(GRAY)}Start typing a city or a continent…{RESET}", W)]
    elif not sug:
        items = [pad(f"{fg(RED)}No matching timezone{RESET}", W)]
    items += [" " * W] * (6 - len(items))
    body += items

    lines += body

    kind, text = state["msg"]
    colour = {"ok": GREEN, "err": RED, "info": GRAY}[kind]
    lines += ["", f"{fg(colour)}{text}{RESET}" if text else "", ""]
    lines.append(f"{key_hint('Enter')} {fg(GRAY)}apply{RESET}   {key_hint('Tab')} {fg(GRAY)}complete{RESET}   "
                 f"{key_hint('↑/↓')} {fg(GRAY)}pick{RESET}   {key_hint('Esc')} {fg(GRAY)}back{RESET}")
    return lines


def draw_splash(visible: int, label: str, frac: float) -> None:
    cols, rows = shutil.get_terminal_size((80, 24))
    if cols >= LOGO_W + 2 and rows >= 14:
        lines = paint_logo(visible)
        lines += ["", f"{fg(GRAY)}Liquid Shell{RESET}" if visible == 6 else ""]
    else:
        lines = [gradient_text("LSHELL"), ""]
    lines += ["", f"{fg(GRAY)}{label}{RESET}", bar(frac)]
    render(lines)


def splash(steps) -> None:
    for k in range(1, 7):
        draw_splash(k, "", 0.0)
        time.sleep(0.07)
    total = len(steps)
    for i, (label, fn) in enumerate(steps):
        fn()
        for f in range(1, 9):
            draw_splash(6, label, (i + f / 8) / total)
            time.sleep(0.03)
    draw_splash(6, "Done", 1.0)
    time.sleep(0.35)


def run_ui(cfg: Path, args) -> int:
    info: dict = {"active": None, "tz": None}

    def read():
        info["active"] = read_position(cfg)
        zones = read_timezones(cfg)
        info["tz"] = zones[0] if zones else None

    steps = [
        ("Looking for the Waybar config…", lambda: time.sleep(0.12)),
        ("Reading panel position and timezone…", read),
        ("Checking the Waybar process…", lambda: info.update(running=waybar_running())),
        ("Starting the interface…", lambda: time.sleep(0.12)),
    ]
    custom = bool(args.config)

    with Term() as term:
        if not args.no_splash:
            splash(steps)
        else:
            read()

        active = info["active"]
        state = {
            "mode": "main",
            "sel": active if active in NAMES else "top",
            "active": active,
            "tz": info["tz"],
            "path": cfg,
            "buf": "",
            "pick": 0,
            "msg": ("info", "" if active in NAMES else f"The config says position “{active}” — pick top or bottom"),
        }

        def redraw():
            render(build_tz(state) if state["mode"] == "tz" else build_main(state))

        def finish(summary: str):
            if args.no_restart:
                state["msg"] = ("ok", f"✓ {summary} (restart waybar to apply)")
                return
            state["msg"] = ("info", "Applying…")
            redraw()
            ok, text = restart_waybar(cfg, custom)
            state["msg"] = ("ok", f"✓ {summary} · {text}") if ok else ("err", f"✗ {text}")

        last = None
        dirty = True
        while True:
            size = shutil.get_terminal_size()
            if dirty or size != last:
                redraw()
                dirty, last = False, size

            # ── timezone input screen ──
            if state["mode"] == "tz":
                k = term.key(0.1, text=True)
                if k is None:
                    continue
                dirty = True
                sug = suggest(state["buf"], 6)
                pick = min(state["pick"], max(0, len(sug) - 1))
                if k == "esc":
                    state.update(mode="main", buf="", pick=0, msg=("info", ""))
                elif k == "backspace":
                    state["buf"], state["pick"] = state["buf"][:-1], 0
                elif k == "tab":
                    if sug:
                        state["buf"], state["pick"] = sug[pick], 0
                elif k == "up":
                    state["pick"] = max(0, pick - 1)
                elif k == "down":
                    state["pick"] = min(len(sug) - 1, pick + 1) if sug else 0
                elif k == "enter":
                    zone = resolve_zone(state["buf"])
                    if zone is None and sug:
                        zone = sug[pick]
                    if zone is None:
                        state["msg"] = ("err", "✗ Unknown timezone — use the Continent/City form")
                        continue
                    state.update(mode="main", buf="", pick=0)
                    if state["tz"] == zone:
                        state["msg"] = ("info", f"Timezone is already {zone}")
                        continue
                    try:
                        write_timezone(cfg, zone)
                    except (OSError, ValueError) as e:
                        state["msg"] = ("err", f"✗ Could not write the config: {e}")
                        continue
                    state["tz"] = zone
                    finish(f"Timezone is now {zone}")
                elif k.startswith("\0"):
                    typed = "".join(ch for ch in k[1:] if ch.isprintable())
                    if typed:
                        state["buf"] = (state["buf"] + typed)[:40]
                        state["pick"] = 0
                        state["msg"] = ("info", "")
                continue

            # ── main screen ──
            k = term.key(0.1)
            if k is None:
                continue
            if k in ("q", "esc"):
                break
            if k == "c":
                state.update(mode="tz", buf="", pick=0, msg=("info", ""))
                dirty = True
            elif k in ("left", "up", "h", "k", "t") and state["sel"] != "top":
                state["sel"], dirty = "top", True
            elif k in ("right", "down", "l", "j", "b") and state["sel"] != "bottom":
                state["sel"], dirty = "bottom", True
            elif k in ("tab", "space"):
                state["sel"] = "bottom" if state["sel"] == "top" else "top"
                dirty = True
            elif k == "enter":
                dirty = True
                sel = state["sel"]
                if sel == state["active"]:
                    state["msg"] = ("info", f"The panel is already at the {NAMES[sel].lower()}")
                    continue
                try:
                    write_position(cfg, sel)
                except OSError as e:
                    state["msg"] = ("err", f"✗ Could not write the config: {e}")
                    continue
                state["active"] = sel
                finish(f"Panel is now at the {NAMES[sel].lower()}")
    return 0


# ───────────────────────── entry point ─────────────────────────

def run_cli(cfg: Path, args) -> int:
    notes: list[str] = []
    changed = False

    if args.tz:
        zone = resolve_zone(args.tz)
        if zone is None:
            near = suggest(args.tz, 5)
            hint = f" Did you mean: {', '.join(near)}?" if near else " Use the Continent/City form, e.g. Europe/Kyiv."
            print(f"Unknown timezone “{args.tz}”.{hint}", file=sys.stderr)
            return 1
        zones = read_timezones(cfg)
        if zones[:1] == [zone]:
            notes.append(f"Timezone is already {zone}")
        else:
            try:
                write_timezone(cfg, zone)
            except (OSError, ValueError) as e:
                print(f"Could not write the config: {e}", file=sys.stderr)
                return 1
            changed = True
            notes.append(f"Timezone is now {zone}")

    if args.position:
        cur = read_position(cfg)
        pos = args.position
        if pos == "toggle":
            pos = "bottom" if cur != "bottom" else "top"
        if pos == cur:
            notes.append(f"The panel is already at the {NAMES[pos].lower()}")
        else:
            try:
                write_position(cfg, pos)
            except OSError as e:
                print(f"Could not write the config: {e}", file=sys.stderr)
                return 1
            changed = True
            notes.append(f"Panel is now at the {NAMES[pos].lower()}")

    ok = True
    if changed and not args.no_restart:
        ok, text = restart_waybar(cfg, bool(args.config))
        notes.append(text)
    print(" · ".join(notes))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Waybar panel switcher: position (top / bottom) and clock timezone.")
    ap.add_argument("position", nargs="?", choices=["top", "bottom", "toggle"],
                    help="apply the panel position right away, without the interface")
    ap.add_argument("--tz", metavar="CONTINENT/CITY",
                    help="set the clock timezone, e.g. Europe/Kyiv or America/New_York")
    ap.add_argument("-c", "--config", help="path to the waybar config (default: ~/.config/waybar/config)")
    ap.add_argument("--no-splash", action="store_true", help="skip the splash screen")
    ap.add_argument("--no-restart", action="store_true", help="do not restart waybar after changes")
    args = ap.parse_args()

    cfg = find_config(args.config)
    if cfg is None:
        print("Could not find the waybar config. Pass a path: lshell.py -c /path/to/config", file=sys.stderr)
        return 1

    if args.position or args.tz:
        return run_cli(cfg, args)

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("The interface needs a terminal. Without one use: lshell.py top|bottom|toggle or --tz Europe/Kyiv",
              file=sys.stderr)
        return 1

    try:
        return run_ui(cfg, args)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
