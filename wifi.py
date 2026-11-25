from __future__ import annotations

import argparse
import http.client
import math
import os
import select
import shutil
import socket
import statistics
import subprocess
import sys
import termios
import threading
import time
import tty
import unicodedata
import urllib.parse
import re
from collections import deque
from dataclasses import dataclass

ESC = "\x1b"
RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"
NORM = f"{ESC}[22m"
TRUECOLOR = os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit")

CYAN = (0, 229, 255)
VIOLET = (150, 110, 255)
PINK = (255, 105, 200)
WHITE = (236, 240, 255)
SOFT = (196, 202, 224)
GRAY = (130, 138, 160)
DARK = (62, 68, 90)
SELBG = (36, 48, 94)
GREEN = (80, 250, 123)
YELLOW = (255, 214, 102)
RED = (255, 95, 95)
BG_TOP = (8, 10, 22)
BG_BOT = (24, 13, 42)
PANEL = (15, 19, 37)
KEYBG = (34, 40, 70)
PANEL_ALT = (18, 23, 43)
PANEL_HI = (25, 31, 58)
TINT0 = (38, 66, 138)
TINT1 = (92, 50, 140)

SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


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
    t = min(1.0, max(0.0, t))
    if t < 0.5:
        return lerp(CYAN, VIOLET, t * 2)
    return lerp(VIOLET, PINK, (t - 0.5) * 2)


def gradient_text(text: str) -> str:
    n = max(1, len(text) - 1)
    return "".join(fg(grad(i / n)) + ch for i, ch in enumerate(text)) + RESET


def cw(ch: str) -> int:
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def vlen(s: str) -> int:
    return sum(cw(c) for c in ANSI_RE.sub("", s))


def pad(s: str, width: int) -> str:
    return s + " " * max(0, width - vlen(s))


def center(s: str, cols: int) -> str:
    return " " * max(0, (cols - vlen(s)) // 2) + s


def fit(text: str, width: int) -> str:
    if width <= 0:
        return ""
    if vlen(text) <= width:
        return text
    acc, total = "", 0
    for ch in text:
        w = cw(ch)
        if total + w > width - 1:
            break
        acc += ch
        total += w
    return acc + "…"


def clean(text: str) -> str:
    return "".join(ch if ch.isprintable() else "?" for ch in text)


def out(s: str) -> None:
    sys.stdout.write(s)
    sys.stdout.flush()

def run(args: list[str], timeout: int = 45) -> tuple[int, str, str]:
    env = dict(os.environ, LC_ALL="C.UTF-8")
    try:
        p = subprocess.run(["nmcli", *args], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, "", "nmcli timed out"
    except OSError as e:
        return 127, "", str(e)
    return p.returncode, p.stdout, p.stderr.strip()


def split_terse(line: str) -> list[str]:
    parts, cur, i = [], [], 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and i + 1 < len(line):
            cur.append(line[i + 1])
            i += 2
            continue
        if ch == ":":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return parts


@dataclass
class Net:
    ssid: str
    signal: int
    security: str
    chan: str
    rate: str
    active: bool


def sec_label(s: str) -> str:
    s = s.strip()
    if not s or s == "--":
        return "Open"
    if "802.1X" in s:
        return "802.1X"
    if "WPA3" in s and "WPA2" in s:
        return "WPA2/3"
    if "WPA3" in s:
        return "WPA3"
    if "WPA2" in s:
        return "WPA2"
    if "WPA" in s:
        return "WPA"
    if "WEP" in s:
        return "WEP"
    return s[:8]


def wifi_device() -> str | None:
    rc, o, _ = run(["-t", "-f", "DEVICE,TYPE,STATE", "device"])
    if rc != 0:
        return None
    for line in o.splitlines():
        f = split_terse(line)
        if len(f) >= 2 and f[1] == "wifi":
            return f[0]
    return None


def radio_enabled() -> bool | None:
    rc, o, _ = run(["radio", "wifi"])
    if rc != 0:
        return None
    return o.strip().lower() == "enabled"


def scan(dev: str | None, rescan: bool) -> tuple[list[Net] | None, str]:
    base = ["-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,CHAN,RATE", "device", "wifi", "list"]
    if dev:
        base += ["ifname", dev]
    rc, o, e = run(base + ["--rescan", "yes" if rescan else "no"])
    if rc != 0 and rescan:
        rc, o, e = run(base + ["--rescan", "no"])
    if rc != 0:
        return None, e or "Could not read the network list"
    best: dict[str, Net] = {}
    for line in o.splitlines():
        f = split_terse(line)
        if len(f) < 6:
            continue
        use, ssid, sig, sec, chan, rate = f[:6]
        ssid = clean(ssid)
        if not ssid.strip():
            continue
        try:
            level = int(sig)
        except ValueError:
            level = 0
        net = Net(ssid, level, sec, chan, rate, use.strip() == "*")
        cur = best.get(ssid)
        if (cur is None or (net.active and not cur.active)
                or (net.active == cur.active and net.signal > cur.signal)):
            best[ssid] = net
    nets = sorted(best.values(), key=lambda n: (not n.active, -n.signal, n.ssid.lower()))
    return nets, ""


def saved_profiles() -> dict[str, str]:
    rc, o, _ = run(["-t", "-f", "UUID,TYPE,NAME", "connection", "show"])
    found: dict[str, str] = {}
    if rc != 0:
        return found
    for line in o.splitlines():
        f = (split_terse(line) + ["", "", ""])[:3]
        uuid, kind, name = f
        if kind not in ("802-11-wireless", "wifi"):
            continue
        rc2, o2, _ = run(["-g", "802-11-wireless.ssid", "connection", "show", "uuid", uuid])
        ssid = clean(split_terse(o2.strip())[0]) if rc2 == 0 and o2.strip() else clean(name)
        found.setdefault(ssid, uuid)
    return found


def link_info(dev: str) -> tuple[str, str]:
    rc, o, _ = run(["-t", "-f", "IP4.ADDRESS,IP4.GATEWAY", "device", "show", dev])
    ip = gw = ""
    for line in o.splitlines():
        k, _, v = line.partition(":")
        if k.startswith("IP4.ADDRESS") and not ip:
            ip = v.strip()
        elif k.startswith("IP4.GATEWAY"):
            gw = v.strip()
    return ip, gw


def friendly(err: str) -> tuple[str, bool]:
    e = err.replace("Error:", "").strip()
    low = e.lower()
    if "secrets were required" in low or "no secrets" in low or "802-11-wireless-security" in low:
        return "Wrong password", True
    if "no network with ssid" in low:
        return "Network not found — try rescanning", False
    if "timed out" in low or "timeout" in low:
        return "The connection timed out", False
    if "not authorized" in low or "insufficient privileges" in low:
        return "Not allowed — check your NetworkManager permissions", False
    return (e or "The connection failed"), False


def do_connect(dev: str | None, net_ssid: str, uuid: str | None, password: str | None, hidden: bool):
    ifname = ["ifname", dev] if dev else []
    if uuid and password:
        rc, o, e = run(["connection", "modify", "uuid", uuid, "wifi-sec.key-mgmt", "wpa-psk",
                        "wifi-sec.psk", password])
        if rc == 0:
            rc, o, e = run(["connection", "up", "uuid", uuid] + ifname, 60)
    elif uuid:
        rc, o, e = run(["connection", "up", "uuid", uuid] + ifname, 60)
    else:
        args = ["device", "wifi", "connect", net_ssid]
        if password:
            args += ["password", password]
        if hidden:
            args += ["hidden", "yes"]
        rc, o, e = run(args + ifname, 60)
        if rc != 0:
            stale = saved_profiles().get(net_ssid)
            if stale:
                run(["connection", "delete", "uuid", stale])
    if rc == 0:
        return True, f"Connected to {net_ssid}", False
    text, ask = friendly(e or o)
    return False, text, ask

SPEED_BASE = os.environ.get("LSHELL_SPEED_BASE", "https://speed.cloudflare.com")
SPEED_SECONDS = float(os.environ.get("LSHELL_SPEED_SECONDS", "8"))
UA = "lshell-wifi/1.0"


def read_counters(dev: str) -> tuple[int, int] | None:
    try:
        with open("/proc/net/dev", encoding="utf-8") as f:
            for line in f:
                name, _, rest = line.partition(":")
                if name.strip() == dev:
                    cols = rest.split()
                    return int(cols[0]), int(cols[8])
    except (OSError, ValueError, IndexError):
        pass
    try:
        base = f"/sys/class/net/{dev}/statistics/"
        with open(base + "rx_bytes", encoding="utf-8") as f:
            rx = int(f.read())
        with open(base + "tx_bytes", encoding="utf-8") as f:
            tx = int(f.read())
        return rx, tx
    except (OSError, ValueError):
        return None


def wireless_info(dev: str) -> tuple[int | None, float | None]:
    dbm: int | None = None
    rate: float | None = None
    for cmd in (["iw", "dev", dev, "link"], ["iwconfig", dev]):
        if not shutil.which(cmd[0]):
            continue
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        except (OSError, subprocess.SubprocessError):
            continue
        text = p.stdout + p.stderr
        m = re.search(r"signal:\s*(-?\d+)\s*dBm", text) or re.search(r"Signal level[=:]\s*(-?\d+)", text)
        if m:
            dbm = int(m.group(1))
        m = re.search(r"tx bitrate:\s*([\d.]+)\s*MBit/s", text) or re.search(r"Bit Rate[=:]\s*([\d.]+)\s*Mb/s", text)
        if m:
            rate = float(m.group(1))
        if dbm is not None or rate is not None:
            break
    if dbm is None:
        try:
            with open("/proc/net/wireless", encoding="utf-8") as f:
                for line in f:
                    name, _, rest = line.partition(":")
                    if name.strip() == dev:
                        cols = rest.split()
                        dbm = int(float(cols[2].rstrip(".")))
        except (OSError, ValueError, IndexError):
            pass
    return dbm, rate


class Monitor:
    def __init__(self) -> None:
        self.dev: str | None = None
        self.down = 0.0
        self.up = 0.0
        self.hist_down: deque[float] = deque([0.0] * 48, maxlen=48)
        self.hist_up: deque[float] = deque([0.0] * 48, maxlen=48)
        self.dbm: int | None = None
        self.rate: float | None = None
        self.stop = False

    def start(self) -> None:
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self) -> None:
        last_dev = None
        last = None
        last_t = 0.0
        info_t = 0.0
        while not self.stop:
            dev = self.dev
            now = time.time()
            if not dev:
                time.sleep(0.3)
                continue
            counters = read_counters(dev)
            if counters and last and dev == last_dev and now > last_t:
                dt = now - last_t
                d = max(0.0, (counters[0] - last[0]) * 8 / dt)
                u = max(0.0, (counters[1] - last[1]) * 8 / dt)
                self.down = d * 0.65 + self.down * 0.35
                self.up = u * 0.65 + self.up * 0.35
                self.hist_down.append(self.down)
                self.hist_up.append(self.up)
            elif dev != last_dev:
                self.down = self.up = 0.0
                self.dbm, self.rate = None, None
                info_t = 0.0
            last, last_dev, last_t = counters, dev, now
            if now - info_t > 3.0:
                self.dbm, self.rate = wireless_info(dev)
                info_t = now
            time.sleep(0.5)


def fmt_rate(bps: float) -> tuple[str, str]:
    if bps >= 1e9:
        return f"{bps / 1e9:.2f}", "Gbit/s"
    if bps >= 1e6:
        v = bps / 1e6
        return (f"{v:.1f}" if v < 100 else f"{v:.0f}"), "Mbit/s"
    if bps >= 1e3:
        return f"{bps / 1e3:.0f}", "kbit/s"
    return f"{bps:.0f}", "bit/s"


def fmt_short(bps: float | None) -> str:
    if bps is None:
        return "-"
    return " ".join(fmt_rate(bps))


def fmt_ping(ms: float | None) -> str:
    if ms is None:
        return "-"
    return f"{ms:.1f}" if ms < 10 else f"{ms:.0f}"


def speed_target() -> tuple[str, str, int, str]:
    u = urllib.parse.urlsplit(SPEED_BASE)
    port = u.port or (443 if u.scheme == "https" else 80)
    return u.scheme, u.hostname or "", port, u.path.rstrip("/")


def speed_conn(timeout: float = 8.0):
    scheme, host, port, base = speed_target()
    cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    return cls(host, port, timeout=timeout), base


def measure_latency(state: dict, cancel: threading.Event) -> bool:
    _, host, port, _ = speed_target()
    ip = socket.gethostbyname(host)
    samples: list[float] = []
    for i in range(11):
        if cancel.is_set():
            return False
        t = time.perf_counter()
        s = socket.create_connection((ip, port), timeout=3)
        ms = (time.perf_counter() - t) * 1000
        s.close()
        if i:
            samples.append(ms)
            state["ping"] = statistics.median(samples)
            if len(samples) > 1:
                state["jitter"] = sum(abs(a - b) for a, b in zip(samples, samples[1:])) / (len(samples) - 1)
        time.sleep(0.08)
    return True


def measure_stream(kind: str, seconds: float, state: dict, cancel: threading.Event, workers: int) -> float | None:
    total = [0]
    lock = threading.Lock()
    errors: list[str] = []
    stop = time.perf_counter() + seconds

    def down() -> None:
        conn = None
        try:
            conn, base = speed_conn()
            conn.request("GET", f"{base}/__down?bytes=400000000", headers={"User-Agent": UA})
            resp = conn.getresponse()
            if resp.status != 200:
                raise OSError(f"HTTP {resp.status}")
            while time.perf_counter() < stop and not cancel.is_set():
                chunk = resp.read(131072)
                if not chunk:
                    break
                with lock:
                    total[0] += len(chunk)
        except Exception as e:
            errors.append(str(e))
        finally:
            if conn:
                conn.close()

    def up() -> None:
        conn = None
        try:
            conn, base = speed_conn()
            conn.putrequest("POST", f"{base}/__up")
            conn.putheader("Content-Length", "400000000")
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("User-Agent", UA)
            conn.endheaders()
            block = bytes(65536)
            while time.perf_counter() < stop and not cancel.is_set():
                conn.send(block)
                with lock:
                    total[0] += len(block)
        except Exception as e:
            errors.append(str(e))
        finally:
            if conn:
                conn.close()

    threads = [threading.Thread(target=down if kind == "down" else up, daemon=True) for _ in range(workers)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    points = [(0.0, 0)]
    last_b, last_t = 0, t0
    while any(t.is_alive() for t in threads) and not cancel.is_set():
        time.sleep(0.25)
        now = time.perf_counter()
        b = total[0]
        inst = (b - last_b) * 8 / max(1e-6, now - last_t)
        state["live"] = inst
        state["graph_" + kind].append(inst)
        points.append((now - t0, b))
        last_b, last_t = b, now
        if now >= stop + 1.0:
            break
    if cancel.is_set():
        return None
    if total[0] == 0:
        raise OSError(errors[0] if errors else "No data received")
    warm = min(1.5, seconds * 0.3)
    a = next((p for p in points if p[0] >= warm), points[0])
    z = points[-1]
    return (z[1] - a[1]) * 8 / max(1e-6, z[0] - a[0])


def net_error(e: Exception) -> str:
    if isinstance(e, socket.gaierror):
        return "No internet connection"
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "The test server did not answer in time"
    if isinstance(e, OSError) and e.errno in (101, 111, 113):
        return "Cannot reach the test server"
    text = str(e).strip()
    return (text[:60] if text else "The speed test failed")


def new_speed_state() -> dict:
    return {"phase": "idle", "running": False, "ping": None, "jitter": None, "down": None, "up": None,
            "live": 0.0, "graph_down": [], "graph_up": [], "error": ""}


def speed_worker(state: dict, cancel: threading.Event) -> None:
    try:
        if not measure_latency(state, cancel):
            return
        state["phase"] = "down"
        rate = measure_stream("down", SPEED_SECONDS, state, cancel, 4)
        if rate is None:
            return
        state["down"] = rate
        state["live"] = 0.0
        state["phase"] = "up"
        try:
            rate = measure_stream("up", SPEED_SECONDS * 0.75, state, cancel, 3)
            if rate is None:
                return
            state["up"] = rate
        except Exception:
            state["error"] = "Upload could not be measured"
        state["phase"] = "done"
    except Exception as e:
        state["phase"] = "error"
        state["error"] = net_error(e)
    finally:
        state["running"] = False

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
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return None
        data = os.read(self.fd, 64 if text else 8)
        table = {
            b"\x1b[A": "up", b"\x1bOA": "up",
            b"\x1b[B": "down", b"\x1bOB": "down",
            b"\x1b[C": "right", b"\x1bOC": "right",
            b"\x1b[D": "left", b"\x1bOD": "left",
            b"\x1b[H": "home", b"\x1b[1~": "home", b"\x1bOH": "home",
            b"\x1b[F": "end", b"\x1b[4~": "end", b"\x1bOF": "end",
            b"\x1b[5~": "pageup", b"\x1b[6~": "pagedown",
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

_L = ["██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"]
_S = ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"]
_H = ["██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"]
_E = ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"]
_W = ["██╗    ██╗", "██║    ██║", "██║ █╗ ██║", "██║███╗██║", "╚███╔███╔╝", " ╚══╝╚══╝ "]
_I = ["██╗", "██║", "██║", "██║", "██║", "╚═╝"]
_D = ["         ", "         ", " █████╗  ", " ╚════╝  ", "         ", "         "]
_F = ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "██║     ", "╚═╝     "]
_G = {"L": _L, "S": _S, "H": _H, "E": _E, "W": _W, "I": _I, "-": _D, "F": _F}

LOGO = ["".join(_G[ch][i] for ch in "LSHELL") for i in range(6)]
WIFI = ["".join(_G[ch][i] for ch in "WI-FI") for i in range(6)]
WIDE = [LOGO[i] + "   " + WIFI[i] for i in range(6)]
WIDE_W = len(WIDE[0])
LOCK = ["  ╭───╮  ", "  │   │  ", "╭─┴───┴─╮", "│   ●   │", "╰───────╯"]

DIGITS = {
    "0": ["┏━┓", "┃ ┃", "┗━┛"], "1": ["╺┓ ", " ┃ ", "╺┻╸"], "2": ["┏━┓", "┏━┛", "┗━╸"],
    "3": ["┏━┓", "╺━┫", "┗━┛"], "4": ["╻ ╻", "┗━┫", "  ╹"], "5": ["┏━╸", "┗━┓", "┗━┛"],
    "6": ["┏━╸", "┣━┓", "┗━┛"], "7": ["┏━┓", "  ┃", "  ╹"], "8": ["┏━┓", "┣━┫", "┗━┛"],
    "9": ["┏━┓", "┗━┫", "┗━┛"], ".": [" ", " ", "▪"], "-": ["   ", "╺━╸", "   "], " ": [" ", " ", " "],
}
SPARK = "▁▂▃▄▅▆▇█"
SCALES = (10, 25, 50, 100, 250, 500, 1000, 2500, 10000)
SEC_COLORS = {"Open": YELLOW, "WEP": (255, 160, 90), "WPA": (255, 190, 110), "WPA2": (120, 200, 235),
              "WPA2/3": GREEN, "WPA3": GREEN, "802.1X": VIOLET}


def dim(c, k: float):
    return tuple(int(v * k) for v in c)


def meter_color(level: float):
    level = max(0.0, min(100.0, level))
    if level < 50:
        return lerp(RED, YELLOW, level / 50)
    return lerp(YELLOW, GREEN, (level - 50) / 50)


def paint(rows: list[str], now: float, reveal: int = 99) -> list[str]:
    width = max(len(r) for r in rows)
    height = max(1, len(rows) - 1)
    breathe = 0.1 * math.sin(now * 0.8)
    sweep = (now * 16) % (width + 50) - 25
    res = []
    for r, row in enumerate(rows):
        if r >= reveal:
            res.append("")
            continue
        s = ""
        for x, ch in enumerate(row):
            if ch == " ":
                s += ch
                continue
            col = grad(x / max(1, width - 1) * 0.8 + r / height * 0.2 + breathe + 0.08)
            if ch != "█":
                col = dim(col, 0.55)
            shine = max(0.0, 1 - abs((x + r * 3) - sweep) / 7)
            if shine:
                col = lerp(col, (255, 255, 255), shine * 0.6)
            s += fg(col) + ch
        res.append(s + RESET)
    return res


def logo_lines(cols: int, rows: int, now: float, reveal: int) -> list[str]:
    tick = int(now / 0.15) * 0.15
    if cols >= WIDE_W + 4 and rows >= 32:
        return paint(WIDE, tick, reveal)
    if cols >= 56 and rows >= 44:
        return paint(LOGO, tick, reveal) + [""] + paint(WIFI, tick, reveal)
    if rows >= 14:
        shift = 0.15 * math.sin(tick * 0.8)
        bars = "".join(fg(grad(i / 3 + shift)) + ch for i, ch in enumerate("▂▄▆█")) + RESET
        word = "".join(fg(grad(i / 5 + shift)) + BOLD + ch for i, ch in enumerate("LSHELL")) + RESET
        return [f"{bars}  {word}  {fg(GRAY)}Wi-Fi{RESET}"]
    return []


def rule(W: int, now: float) -> str:
    tick = int(now / 0.15) * 0.15
    sweep = (tick * 22) % (W + 30) - 15
    s = ""
    for x in range(W):
        col = dim(grad(x / max(1, W - 1)), 0.5)
        shine = max(0.0, 1 - abs(x - sweep) / 6)
        if shine:
            col = lerp(col, (255, 255, 255), shine * 0.5)
        s += fg(col) + "━"
    return s + RESET


def clip(s: str, width: int) -> str:
    res, w, i = [], 0, 0
    while i < len(s):
        m = ANSI_RE.match(s, i)
        if m:
            res.append(m.group())
            i = m.end()
            continue
        c = cw(s[i])
        if w + c > width:
            break
        res.append(s[i])
        w += c
        i += 1
    return "".join(res) + RESET


def tint(content: str, width: int, c0, c1) -> str:
    res = []
    x = 0
    i = 0
    while i < len(content):
        m = ANSI_RE.match(content, i)
        if m:
            if m.group() != RESET:
                res.append(m.group())
            i = m.end()
            continue
        res.append(bg(lerp(c0, c1, x / max(1, width - 1))) + content[i])
        x += cw(content[i])
        i += 1
    while x < width:
        res.append(bg(lerp(c0, c1, x / max(1, width - 1))) + " ")
        x += 1
    return "".join(res)


def pill(label: str, fg_col, bg_col) -> str:
    return f"{fg(bg_col)}▐{bg(bg_col)}{fg(fg_col)}{BOLD} {label} {RESET}{fg(bg_col)}▌{RESET}"


def button(label: str, focused: bool, col) -> str:
    if focused:
        return f"{bg(col)}{fg((10, 12, 24))}{BOLD}   {label}   {RESET}"
    return f"{bg(KEYBG)}{fg(SOFT)}   {label}   {RESET}"


def signal_bars(level: int) -> str:
    n = 0 if level <= 0 else min(4, max(1, (level + 24) // 25))
    color = meter_color(level)
    s = ""
    for i, ch in enumerate("▂▄▆█"):
        s += (fg(color) if i < n else fg(DARK)) + ch
    return s


def meter(width: int, level: float) -> str:
    filled = round(max(0, min(100, level)) / 100 * width)
    s = ""
    for i in range(width):
        if i < filled:
            s += fg(meter_color(i / max(1, width - 1) * 100)) + "━"
        else:
            s += fg(DARK) + "━"
    return s + RESET


def gauge(width: int, frac: float, c0, c1) -> str:
    filled = round(max(0.0, min(1.0, frac)) * width)
    s = ""
    for i in range(width):
        if i < filled:
            s += fg(lerp(c0, c1, i / max(1, width - 1))) + "━"
        else:
            s += fg(DARK) + "─"
    return s + RESET


def busy_bar(width: int, now: float) -> str:
    pos = (now * 18) % (width + 10) - 5
    s = ""
    for i in range(width):
        k = max(0.0, 1 - abs(i - pos) / 5)
        s += fg(lerp(DARK, grad(i / max(1, width - 1)), 0.2 + 0.8 * k)) + "━"
    return s + RESET


def spark(values, width: int, c0, c1) -> str:
    vals = list(values)[-width:]
    vals = [0.0] * (width - len(vals)) + vals
    top = max(max(vals), 100000.0)
    s = ""
    for i, v in enumerate(vals):
        lvl = 0 if v <= 0 else min(7, int(v / top * 7.999))
        col = lerp(c0, c1, i / max(1, width - 1)) if v > 0 else DARK
        s += fg(col) + SPARK[lvl]
    return s + RESET


def big(text: str, c0, c1) -> list[str]:
    glyphs = [DIGITS.get(ch, DIGITS["-"]) for ch in text]
    rows = ["".join(g[r] + " " for g in glyphs).rstrip() for r in range(3)]
    width = max(len(r) for r in rows)
    out_rows = []
    for row in rows:
        s = ""
        for x, ch in enumerate(row):
            s += (fg(lerp(c0, c1, x / max(1, width - 1))) + ch) if ch != " " else " "
        out_rows.append(s + RESET)
    return out_rows


def graph(values: list[float], width: int, height: int, top: float, c0, c1) -> list[str]:
    if not values or width <= 0:
        return [" " * width for _ in range(height)]
    if len(values) > width:
        step = len(values) / width
        values = [sum(values[int(i * step):max(int(i * step) + 1, int((i + 1) * step))])
                  / max(1, len(values[int(i * step):max(int(i * step) + 1, int((i + 1) * step))]))
                  for i in range(width)]
    levels = height * 8
    cells = [min(levels, int(v / max(top, 1.0) * levels)) for v in values]
    cells += [-1] * (width - len(cells))
    lines = []
    for r in range(height):
        s = ""
        base = (height - 1 - r) * 8
        for x, h in enumerate(cells):
            if h < 0:
                s += " "
                continue
            lvl = max(0, min(8, h - base))
            if lvl == 0:
                s += " "
                continue
            col = lerp(c0, c1, x / max(1, width - 1))
            s += fg(dim(col, 0.55 + 0.45 * (height - 1 - r) / max(1, height - 1) + 0.0)) + " ▁▂▃▄▅▆▇█"[lvl]
        lines.append(s + RESET)
    return lines


def band_of(chan: str) -> str:
    try:
        return "2.4 GHz" if int(chan) <= 14 else "5 GHz"
    except ValueError:
        return "—"


def side_color(t: float, which: int):
    a, b = (CYAN, VIOLET) if which == 0 else (VIOLET, PINK)
    return dim(lerp(a, b, t), 0.6)


def edge_line(content: str, W: int, t: float = 0.5, style: str = "plain", thumb: bool = False) -> str:
    left = f"{fg(side_color(t, 0))}│{RESET}"
    right = f"{fg(CYAN)}┃{RESET}" if thumb else f"{fg(side_color(t, 1))}│{RESET}"
    if style == "sel":
        body = tint(content, W - 4, TINT0, TINT1)
        return f"{left}{fg(CYAN)}{bg(TINT0)}▌{body}{bg(TINT1)} {RESET}{right}"
    pb = {"plain": PANEL, "alt": PANEL_ALT, "head": PANEL_HI}[style]
    body = pad(content, W - 4).replace(RESET, RESET + bg(pb))
    return f"{left}{bg(pb)} {body}{bg(pb)} {RESET}{right}"


def border(text: str, W: int, offset: int = 0) -> str:
    s = ""
    for i, ch in enumerate(text):
        s += fg(dim(grad((i + offset) / max(1, W - 1)), 0.8)) + ch
    return s + RESET


def box_top(title: str, right: str, W: int) -> str:
    head = f" {gradient_text(title)} " if "\x1b" not in title else f" {title} "
    tail = f" {right} " if right else ""
    fill = max(0, W - 2 - 2 - vlen(head) - vlen(tail) - 1)
    pre = border("╭─", W)
    mid = border("─" * fill, W, 2 + vlen(head))
    end = border("─╮", W, W - 2)
    return f"{pre}{head}{mid}{tail}{end}"


def box_bottom(W: int) -> str:
    return border("╰" + "─" * (W - 2) + "╯", W)


def divider(W: int, t: float) -> str:
    mid = border("─" * (W - 2), W, 1)
    return f"{fg(side_color(t, 0))}├{RESET}{mid}{fg(side_color(t, 1))}┤{RESET}"


def framed(title: str, right: str, rows_: list[str], W: int, height: int) -> list[str]:
    lines = [box_top(title, right, W)]
    for j, r in enumerate(rows_[:height - 2], start=1):
        lines.append(edge_line(center(r, W - 4), W, j / (height - 1)))
    lines.append(box_bottom(W))
    return lines


class App:
    def __init__(self, transparent: bool = False) -> None:
        self.transparent = transparent
        self.dev: str | None = None
        self.radio: bool | None = None
        self.nets: list[Net] = []
        self.saved: dict[str, str] = {}
        self.ip = ""
        self.gw = ""
        self.fault = ""
        self.sel = 0
        self.top = 0
        self.page = 5
        self.busy = ""
        self.scanning = False
        self.msg = ("info", "")
        self.msg_at = 0.0
        self.mode = "list"
        self.buf = ""
        self.show = False
        self.focus = 0
        self.target: dict = {}
        self.ask: dict | None = None
        self.last_scan = 0.0
        self.gate = threading.Lock()
        self.t0 = time.time()
        self.now = self.t0
        self.prev: list[str] | None = None
        self.prev_size = (0, 0)
        self.mon = Monitor()
        self.speed = new_speed_state()
        self.cancel = threading.Event()
        self.recorded: dict | None = None
        self.last_test: tuple | None = None

    def say(self, kind: str, text: str) -> None:
        self.msg = (kind, text)
        self.msg_at = time.time()

    def refresh(self, rescan: bool) -> None:
        dev = wifi_device()
        radio = radio_enabled()
        self.dev, self.radio = dev, radio
        self.mon.dev = dev
        if dev is None:
            self.nets, self.fault = [], "No Wi-Fi adapter found"
            return
        if radio is False:
            self.nets, self.fault = [], ""
            return
        nets, err = scan(dev, rescan)
        if nets is None:
            self.fault = err
            return
        saved = saved_profiles()
        keep = self.nets[self.sel].ssid if self.nets and self.sel < len(self.nets) else None
        ip, gw = link_info(dev) if any(n.active for n in nets) else ("", "")
        self.nets, self.saved, self.ip, self.gw, self.fault = nets, saved, ip, gw, ""
        self.sel = 0
        if keep:
            for i, n in enumerate(nets):
                if n.ssid == keep:
                    self.sel = i
                    break

    def scan_async(self, rescan: bool) -> None:
        with self.gate:
            if self.scanning:
                return
            self.scanning = True

        def work() -> None:
            try:
                self.refresh(rescan)
            except Exception as e:
                self.fault = str(e)
            finally:
                self.scanning = False
                self.last_scan = time.time()

        threading.Thread(target=work, daemon=True).start()

    def act(self, label: str, fn, rescan: bool = False) -> None:
        if self.busy:
            self.say("info", "Please wait for the current action to finish")
            return
        self.busy = label

        def work() -> None:
            try:
                ok, text, ask = fn()
            except Exception as e:
                ok, text, ask = False, str(e), False
            self.busy = ""
            self.say("ok" if ok else "err", text)
            if ask:
                self.ask = ask if isinstance(ask, dict) else None
            while self.scanning:
                time.sleep(0.2)
            self.scan_async(rescan)

        threading.Thread(target=work, daemon=True).start()

    def current(self) -> Net | None:
        return self.nets[self.sel] if 0 <= self.sel < len(self.nets) else None

    def active_net(self) -> Net | None:
        return next((n for n in self.nets if n.active), None)

    def start_connect(self, ssid: str, uuid: str | None, password: str | None, hidden: bool = False,
                      security: str = "") -> None:
        dev = self.dev

        def fn():
            ok, text, ask = do_connect(dev, ssid, uuid, password, hidden)
            if not ok and ask:
                return False, "Wrong password — try again", {"ssid": ssid, "uuid": uuid, "hidden": hidden,
                                                              "security": security, "empty": False}
            return ok, text, False

        self.act(f"Connecting to {ssid}", fn)

    def open_password(self, ssid: str, uuid: str | None, hidden: bool, security: str, empty: bool = False) -> None:
        self.target = {"ssid": ssid, "uuid": uuid, "hidden": hidden, "security": security, "empty": empty}
        self.mode, self.buf, self.show = "pass", "", False

    def connect_selected(self) -> None:
        net = self.current()
        if net is None:
            return
        if net.active:
            self.say("info", f"Already connected to {net.ssid}")
            return
        uuid = self.saved.get(net.ssid)
        label = sec_label(net.security)
        if uuid or label == "Open":
            self.start_connect(net.ssid, uuid, None, False, net.security)
        elif label == "802.1X":
            self.say("err", "Enterprise network — it needs a saved profile")
        else:
            self.open_password(net.ssid, None, False, net.security)

    def disconnect(self) -> None:
        net = self.active_net()
        if net is None or not self.dev:
            self.say("info", "Not connected to any network")
            return
        dev = self.dev

        def fn():
            rc, o, e = run(["device", "disconnect", dev])
            return (True, f"Disconnected from {net.ssid}", False) if rc == 0 else (False, friendly(e or o)[0], False)

        self.act("Disconnecting", fn)

    def forget_start(self) -> None:
        net = self.current()
        if net is None or net.ssid not in self.saved:
            self.say("info", "This network is not saved")
            return
        self.target = {"ssid": net.ssid, "uuid": self.saved[net.ssid]}
        self.mode, self.focus = "confirm", 0

    def forget_do(self) -> None:
        ssid, uuid = self.target["ssid"], self.target["uuid"]

        def fn():
            rc, o, e = run(["connection", "delete", "uuid", uuid])
            return (True, f"Forgot {ssid}", False) if rc == 0 else (False, friendly(e or o)[0], False)

        self.act("Removing the saved network", fn)

    def toggle_radio(self) -> None:
        want_on = not bool(self.radio)

        def fn():
            rc, o, e = run(["radio", "wifi", "on" if want_on else "off"])
            if rc != 0:
                return False, friendly(e or o)[0], False
            if want_on:
                time.sleep(1.5)
            return True, "Wi-Fi turned on" if want_on else "Wi-Fi turned off", False

        self.act("Turning Wi-Fi on" if want_on else "Turning Wi-Fi off", fn, rescan=want_on)

    def start_speed(self) -> None:
        if self.speed.get("running") and not self.cancel.is_set():
            return
        self.cancel = threading.Event()
        st = new_speed_state()
        st.update(phase="ping", running=True)
        self.speed = st
        threading.Thread(target=speed_worker, args=(st, self.cancel), daemon=True).start()

    def open_speed(self) -> None:
        if self.active_net() is None:
            self.say("info", "Connect to a network first")
            return
        self.mode = "speed"
        self.start_speed()

    def submit(self) -> None:
        t = self.target
        if self.mode == "ssid":
            name = self.buf.strip()
            if not name:
                self.say("err", "Type the network name")
                return
            self.open_password(name, None, True, "", True)
            return
        pw = self.buf
        if not pw and not t.get("empty"):
            self.say("err", "Type the password")
            return
        if pw and len(pw) < 8 and "WEP" not in t.get("security", ""):
            self.say("err", "A Wi-Fi password has at least 8 characters")
            return
        self.mode, self.buf = "list", ""
        self.start_connect(t["ssid"], t.get("uuid"), pw or None, t.get("hidden", False), t.get("security", ""))

    def handle_list(self, k: str) -> bool:
        n = len(self.nets)
        if k in ("q", "esc"):
            return False
        if k in ("up", "k"):
            self.sel = max(0, self.sel - 1)
        elif k in ("down", "j"):
            self.sel = min(max(0, n - 1), self.sel + 1)
        elif k == "home":
            self.sel = 0
        elif k == "end":
            self.sel = max(0, n - 1)
        elif k == "pageup":
            self.sel = max(0, self.sel - self.page)
        elif k == "pagedown":
            self.sel = min(max(0, n - 1), self.sel + self.page)
        elif k == "enter":
            self.connect_selected()
        elif k == "d":
            self.disconnect()
        elif k == "f":
            self.forget_start()
        elif k == "h":
            self.mode, self.buf, self.target = "ssid", "", {}
        elif k == "r":
            self.scan_async(True)
        elif k == "w":
            self.toggle_radio()
        elif k == "s":
            self.open_speed()
        return True

    def handle_text(self, k: str) -> None:
        if k == "esc":
            self.mode, self.buf = "list", ""
        elif k == "enter":
            self.submit()
        elif k == "backspace":
            self.buf = self.buf[:-1]
        elif k == "tab" and self.mode == "pass":
            self.show = not self.show
        elif k.startswith("\0"):
            typed = "".join(ch for ch in k[1:] if ch.isprintable())
            if typed:
                self.buf = (self.buf + typed)[:128]

    def handle_confirm(self, k: str) -> None:
        if k in ("left", "right", "tab", "h", "l"):
            self.focus = 1 - self.focus
        elif k == "y" or (k == "enter" and self.focus == 0):
            self.mode = "list"
            self.forget_do()
        elif k in ("esc", "n", "q", "enter"):
            self.mode = "list"

    def handle_speed(self, k: str) -> None:
        if k in ("esc", "q"):
            self.cancel.set()
            self.mode = "list"
        elif k in ("enter", "s", "space"):
            self.start_speed()

    def status_line(self, cols: int, now: float) -> str:
        if self.dev is None and self.fault:
            return pill(f"✕ {self.fault}", RED, (70, 24, 34))
        if self.radio is False:
            return pill("◌ Wi-Fi is off", YELLOW, (66, 52, 16))
        act = self.active_net()
        if act:
            tail = [x for x in (self.ip, f"gw {self.gw}" if self.gw else "", self.dev or "") if x]
            room = max(10, cols - 14 - vlen(fit(act.ssid, 30)))
            text = fit("   ·   ".join(tail), room)
            pulse = lerp(GREEN, (30, 120, 70), 0.5 + 0.5 * math.sin(now * 3))
            return pill(f"{fg(pulse)}●{fg(GREEN)} {fit(act.ssid, 30)}", GREEN, (16, 62, 46)) + f"  {fg(GRAY)}{text}{RESET}"
        return pill("○ Not connected", GRAY, (36, 40, 62)) + (f"  {fg(DARK)}{self.dev}{RESET}" if self.dev else "")

    def live_line(self, cols: int) -> str:
        if self.active_net() is None or self.radio is False:
            return ""
        d, du = fmt_rate(self.mon.down)
        u, uu = fmt_rate(self.mon.up)
        extras = []
        if self.mon.rate is not None:
            extras.append(f"{fg(GRAY)}link {self.mon.rate:.0f} Mbit/s{RESET}")
        if self.mon.dbm is not None:
            extras.append(f"{fg(GRAY)}{self.mon.dbm} dBm{RESET}")
        line = ""
        for width in (12, 8, 5, 0):
            sd = " " + spark(self.mon.hist_down, width, CYAN, VIOLET) if width else ""
            su = " " + spark(self.mon.hist_up, width, VIOLET, PINK) if width else ""
            parts = [f"{fg(CYAN)}↓{RESET} {BOLD}{fg(WHITE)}{d:>5}{NORM} {fg(GRAY)}{du:<6}{RESET}{sd}",
                     f"{fg(PINK)}↑{RESET} {BOLD}{fg(WHITE)}{u:>5}{NORM} {fg(GRAY)}{uu:<6}{RESET}{su}"]
            line = "     ".join(parts)
            if vlen(line) <= cols - 4:
                break
        for e in extras:
            cand = line + "     " + e
            if vlen(cand) > cols - 4:
                break
            line = cand
        return line

    def test_line(self, cols: int) -> str:
        lt = self.last_test
        act = self.active_net()
        if not lt or act is None or lt[0] != act.ssid:
            return ""
        line = (f"{fg(GRAY)}last test{RESET}   {fg(CYAN)}↓{RESET} {BOLD}{fg(WHITE)}{fmt_short(lt[1])}{NORM}"
                f"   {fg(PINK)}↑{RESET} {BOLD}{fg(WHITE)}{fmt_short(lt[2])}{NORM}"
                f"   {fg(GREEN)}◷{RESET} {BOLD}{fg(WHITE)}{fmt_ping(lt[3])}{NORM} {fg(GRAY)}ms{RESET}")
        return line if vlen(line) <= cols - 4 else ""

    def message_line(self, cols: int, now: float) -> str:
        if self.busy:
            return f"{busy_bar(18, now)}  {fg(WHITE)}{fit(self.busy, cols - 30)}…{RESET}"
        kind, text = self.msg
        if text and now - self.msg_at < 12:
            text = fit(text, cols - 8)
            if kind == "ok":
                return pill(f"✓ {text}", GREEN, (16, 62, 46))
            if kind == "err":
                return pill(f"✕ {text}", RED, (70, 24, 34))
            return f"{fg(GRAY)}{text}{RESET}"
        if self.fault and self.dev is not None:
            return pill(f"✕ {fit(self.fault, cols - 8)}", RED, (70, 24, 34))
        return ""

    def dialog_body(self, W: int, inner: int, now: float):
        t = self.target
        caret = "▌" if int(now * 2) % 2 == 0 else " "
        icon: list[str] = []
        if self.mode == "confirm":
            title = "Forget network"
            body = [f"{BOLD}{fg(WHITE)}Forget “{fit(t['ssid'], W - 24)}”?{RESET}", "",
                    button("Forget", self.focus == 0, RED) + "    " + button("Cancel", self.focus == 1, CYAN)]
        else:
            width = W - 14
            if self.mode == "ssid":
                title = "Hidden network"
                heading = f"{BOLD}{fg(WHITE)}Network name{RESET}"
                sub = ""
                shown = self.buf
            else:
                title = "Connect"
                heading = f"{BOLD}{fg(WHITE)}{fit(t['ssid'], W - 20)}{RESET}"
                lab = sec_label(t.get("security", "")) if t.get("security") else "Password"
                if t.get("empty"):
                    lab = "Password · optional"
                sub = f"{fg(GRAY)}{lab}{RESET}"
                shown = self.buf if self.show else "•" * len(self.buf)
                icon = paint(LOCK, now) if inner >= 15 else []
            room = width - 10
            tail = shown[-room:] if vlen(shown) > room else shown
            field = pad(f"{fg(CYAN)}❯{RESET} {BOLD}{fg(WHITE)}{tail}{NORM}{fg(CYAN)}{caret}{RESET}", width - 7)
            count = f"{fg(DARK)}{len(self.buf):>3}{RESET}"
            box = [border("╭" + "─" * (width - 2) + "╮", width),
                   f"{border('│', width)} {field}{count} {border('│', width, width - 1)}",
                   border("╰" + "─" * (width - 2) + "╯", width, width // 2)]
            body = icon + ([""] if icon else []) + [heading] + ([sub] if sub else []) + [""] + box
        top_pad = max(0, (inner - len(body)) // 2)
        rows_ = [""] * top_pad + body
        rows_ += [""] * max(0, inner - len(rows_))
        return rows_[:inner], title

    def speed_rows(self, W: int, inner_h: int, now: float) -> list[str]:
        st = self.speed
        inner = W - 4
        colw = inner // 3
        phase = st["phase"]
        net = self.active_net()

        def value(kind: str):
            if kind == "ping":
                return st["ping"], True
            if phase == kind:
                return st["live"], False
            return st[kind], phase in ("done", "up", "error") and st[kind] is not None

        def block(label: str, kind: str, c0, c1, bigdigits: bool):
            v, final = value(kind)
            if kind == "ping":
                text = "-" if v is None else fmt_ping(v)
                unit = "ms" + (f"  ±{st['jitter']:.1f}" if st["jitter"] is not None else "")
                frac = 0.0 if v is None else max(0.04, 1 - v / 150)
            else:
                if v is None or (phase == kind and v <= 0):
                    text, unit, frac = "-", "Mbit/s", 0.0
                else:
                    text, unit = fmt_rate(v)
                    mbps = v / 1e6
                    scale = next((x for x in SCALES if x >= mbps * 1.1), SCALES[-1])
                    frac = mbps / scale
            dimmer = 1.0 if final else 0.72
            cells = [f"{fg(GRAY)}{BOLD}{label}{RESET}"]
            if bigdigits:
                cells += big(text, dim(c0, dimmer), dim(c1, dimmer))
            else:
                cells.append(f"{BOLD}{fg(lerp(c0, c1, 0.5))}{text}{RESET}")
            cells.append(f"{fg(GRAY)}{unit}{RESET}")
            cells.append(gauge(colw - 8, frac, c0, c1))
            return cells

        def columns(bigdigits: bool) -> list[str]:
            blocks = [block("PING", "ping", GREEN, CYAN, bigdigits), block("DOWNLOAD", "down", CYAN, VIOLET, bigdigits),
                      block("UPLOAD", "up", VIOLET, PINK, bigdigits)]
            res = []
            for r in range(max(len(b) for b in blocks)):
                res.append("".join(pad(center(b[r] if r < len(b) else "", colw), colw) for b in blocks))
            return res

        if st["running"]:
            label = {"ping": "Measuring latency", "down": "Measuring download", "up": "Measuring upload"}.get(phase, "")
            phase_row = f"{busy_bar(18, now)}  {fg(WHITE)}{label}…{RESET}"
        elif phase == "done":
            phase_row = pill("✓ Done", GREEN, (16, 62, 46)) + (f"  {fg(YELLOW)}{st['error']}{RESET}" if st["error"] else "")
        elif phase == "error":
            phase_row = pill(f"✕ {st['error']}", RED, (70, 24, 34))
        else:
            phase_row = ""

        netline: list[str] = []
        if net is not None:
            bits = [band_of(net.chan)]
            if self.mon.rate is not None:
                bits.append(f"link {self.mon.rate:.0f} Mbit/s")
            if self.mon.dbm is not None:
                bits.append(f"{self.mon.dbm} dBm")
            netline = [f"{BOLD}{fg(WHITE)}{fit(net.ssid, 30)}{NORM}{fg(GRAY)}  ·  " + "  ·  ".join(bits) + RESET, ""]

        gw = inner - 4
        half = gw // 2
        top = max([1.0] + st["graph_down"] + st["graph_up"])
        gd = graph(st["graph_down"], half, 3, top, CYAN, VIOLET)
        gu = graph(st["graph_up"], gw - half, 3, top, VIOLET, PINK)
        graph_rows = [""] + [a + b for a, b in zip(gd, gu)]

        rows_: list[str] = []
        for bigdigits in ((inner >= 66, False) if inner >= 66 else (False,)):
            core = columns(bigdigits)
            for with_net, with_graph in ((True, True), (True, False), (False, False)):
                cand = (netline if with_net else []) + core + (graph_rows if with_graph else []) + ["", phase_row]
                if len(cand) <= inner_h:
                    rows_ = cand
                    break
            if rows_:
                break
        if not rows_:
            rows_ = (core + ["", phase_row])[:inner_h]
        top_pad = max(0, (inner_h - len(rows_)) // 2)
        return ([""] * top_pad + rows_)[:inner_h]

    def compose(self, cols: int, rows: int) -> list[str]:
        now = time.time()
        self.now = now
        W = max(46, min(cols - 4, 80))
        reveal = int((now - self.t0) / 0.07) + 1
        lines = logo_lines(cols, rows, now, reveal)
        if lines:
            lines.append(rule(W, now))
        lines += [self.status_line(cols, now), self.live_line(cols)]
        tl = self.test_line(cols) if rows >= 22 else ""
        if tl:
            lines.append(tl)
        lines.append("")
        extra = 3 if rows >= 28 else 0
        fixed = len(lines) + 3 + extra + 1
        n = max(3, min(rows - fixed, max(len(self.nets), 6)))
        self.page = max(1, n - 1)
        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + n:
            self.top = self.sel - n + 1
        self.top = max(0, min(self.top, max(0, len(self.nets) - n)))
        height = n + 3 + extra
        full = max(3, rows - fixed) + 3 + extra

        if self.mode in ("pass", "ssid", "confirm"):
            inner_rows, title = self.dialog_body(W, height - 2, now)
            lines += framed(title, "", inner_rows, W, height)
        elif self.mode == "speed":
            label = ""
            if self.speed["running"]:
                label = f"{fg(CYAN)}{SPIN[int(now * 10) % len(SPIN)]}{RESET}"
            lines += framed("Speed test", label, self.speed_rows(W, full - 2, now), W, full)
        else:
            lines += self.list_panel(W, n, extra, height, now)
        lines.append(self.message_line(cols, now))
        return lines

    def list_panel(self, W: int, n: int, extra: int, height: int, now: float) -> list[str]:
        inner = W - 4
        band = inner >= 58
        fixed = 2 + 1 + 9 + 2 + 8 + (6 if band else 0)
        ssid_w = inner - fixed
        spin = ""
        if self.scanning:
            spin = f"{fg(CYAN)}{SPIN[int(now * 10) % len(SPIN)]}{RESET} {fg(GRAY)}scanning{RESET}"
        count = f"  {fg(GRAY)}{len(self.nets)}{RESET}" if self.nets else ""
        top = box_top("Networks", spin, W) if not count else box_top(f"{gradient_text('Networks')}{count}", spin, W)
        head = (f"{fg(GRAY)}{BOLD}  {pad('NETWORK', ssid_w)} {pad('SIGNAL', 9)}" + (f"  {pad('BAND', 4)}" if band else "")
                + f"  SECURITY{RESET}")
        items: list = [(head, "head", False)]
        total = len(self.nets)
        thumb_h = max(1, n * n // total) if total > n else 0
        thumb_y = self.top * (n - thumb_h) // max(1, total - n) if total > n else 0
        note = ""
        if not self.nets:
            if self.radio is False:
                note = f"{fg(GRAY)}Wi-Fi is switched off{RESET}"
            elif self.scanning or (self.dev is None and not self.fault):
                note = f"{fg(CYAN)}{SPIN[int(now * 10) % len(SPIN)]}{RESET} {fg(GRAY)}Looking for networks…{RESET}"
            else:
                note = f"{fg(GRAY)}No networks found{RESET}"
        for i in range(n):
            idx = self.top + i
            thumb = bool(thumb_h) and thumb_y <= i < thumb_y + thumb_h
            zebra = "alt" if idx % 2 else "plain"
            if idx < total:
                sel = idx == self.sel
                items.append((self.row(self.nets[idx], ssid_w, sel, band), "sel" if sel else zebra, thumb))
            elif not self.nets and i == n // 2:
                items.append((center(note, inner), "plain", False))
            else:
                items.append(("", zebra, thumb))
        if extra:
            items.append(None)
            d1, d2 = self.details(inner)
            items += [(d1, "plain", False), (d2, "plain", False)]
        lines = [top]
        for j, item in enumerate(items, start=1):
            t = j / (height - 1)
            if item is None:
                lines.append(divider(W, t))
            else:
                lines.append(edge_line(item[0], W, t, item[1], item[2]))
        lines.append(box_bottom(W))
        return lines

    def row(self, net: Net, ssid_w: int, selected: bool, band: bool) -> str:
        saved = net.ssid in self.saved
        if net.active:
            mark = f"{fg(lerp(GREEN, (30, 120, 70), 0.5 + 0.5 * math.sin(self.now * 3)))}●"
        elif saved:
            mark = f"{fg(GRAY)}◦"
        else:
            mark = " "
        name_col = WHITE if (net.active or selected) else SOFT
        weight = BOLD if (net.active or selected) else NORM
        name = pad(fit(net.ssid, ssid_w), ssid_w)
        label = sec_label(net.security)
        col = meter_color(net.signal)
        s = (f"{mark} {weight}{fg(name_col)}{name}{NORM} {signal_bars(net.signal)} "
             f"{fg(col)}{net.signal:>3d}%")
        if band:
            short = "2.4G" if band_of(net.chan).startswith("2.4") else "5G"
            s += f"  {fg(GRAY)}{pad(short, 4)}"
        return s + f"  {fg(SEC_COLORS.get(label, GRAY))}{label}"

    def details(self, inner: int) -> tuple[str, str]:
        net = self.current()
        if net is None:
            return "", ""
        l1 = (f"{BOLD}{fg(WHITE)}{fit(net.ssid, max(8, inner - 36))}{NORM}"
              f"  {fg(GRAY)}{band_of(net.chan)}  ·  ch {net.chan}  ·  {sec_label(net.security)}")
        tags = []
        if net.active:
            tags.append(f"{fg(GREEN)}connected")
        if net.ssid in self.saved:
            tags.append(f"{fg(CYAN)}saved")
        if sec_label(net.security) == "Open":
            tags.append(f"{fg(YELLOW)}open network")
        l2 = (f"{meter(22, net.signal)} {fg(meter_color(net.signal))}{BOLD}{net.signal}%{NORM}"
              f"   " + f"{fg(GRAY)} · ".join(tags))
        return l1, l2

    def draw(self, lines: list[str], cols: int, rows: int) -> None:
        top = max(0, (rows - len(lines)) // 2)
        frame = ([""] * top + lines)
        frame += [""] * (rows - len(frame))
        frame = frame[:rows]
        painted = []
        for y, body in enumerate(frame):
            body = clip(body, cols)
            w = vlen(body)
            left = (cols - w) // 2
            right = cols - w - left
            if self.transparent:
                painted.append(" " * left + body + f"{ESC}[K")
            else:
                c = bg(lerp(BG_TOP, BG_BOT, y / max(1, rows - 1)))
                painted.append(c + " " * left + body.replace(RESET, RESET + c) + " " * right + RESET)
        full = self.prev is None or self.prev_size != (cols, rows)
        buf = f"{ESC}[2J" if full else ""
        for y in range(rows):
            if full or painted[y] != self.prev[y]:
                buf += f"{ESC}[{y + 1};1H{painted[y]}"
        if buf:
            out(buf)
        self.prev, self.prev_size = painted, (cols, rows)

    def run(self, term: Term) -> None:
        self.mon.start()
        self.scan_async(False)
        threading.Thread(target=lambda: (self.wait_idle(), self.scan_async(True)), daemon=True).start()
        while True:
            cols, rows = shutil.get_terminal_size((80, 24))
            now = time.time()
            if (self.mode == "list" and not self.busy and not self.scanning and self.last_scan
                    and now - self.last_scan > 25 and self.radio):
                self.scan_async(True)
            if self.ask and self.mode == "list" and not self.busy:
                a, self.ask = self.ask, None
                self.open_password(a["ssid"], a.get("uuid"), a.get("hidden", False), a.get("security", ""),
                                   a.get("empty", False))
            st = self.speed
            if st["phase"] == "done" and st is not self.recorded:
                self.recorded = st
                net = self.active_net()
                self.last_test = (net.ssid if net else "", st["down"], st["up"], st["ping"])
            self.draw(self.compose(cols, rows), cols, rows)
            k = term.key(0.1, text=self.mode in ("pass", "ssid"))
            if k is None:
                continue
            if self.mode == "list":
                if not self.handle_list(k):
                    self.cancel.set()
                    self.mon.stop = True
                    return
            elif self.mode == "confirm":
                self.handle_confirm(k)
            elif self.mode == "speed":
                self.handle_speed(k)
            else:
                self.handle_text(k)

    def wait_idle(self) -> None:
        while self.scanning:
            time.sleep(0.1)


def main() -> int:
    ap = argparse.ArgumentParser(prog="lshell_wifi")
    ap.add_argument("-t", "--transparent", action="store_true")
    args = ap.parse_args()
    if not shutil.which("nmcli"):
        print("nmcli was not found. Install NetworkManager: sudo pacman -S networkmanager", file=sys.stderr)
        return 1
    if not sys.stdin.isatty():
        print("This program needs an interactive terminal", file=sys.stderr)
        return 1
    app = App(args.transparent)
    try:
        with Term() as term:
            app.run(term)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
