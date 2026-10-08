#!/usr/bin/env python3
"""tests/screenshots.py - regenerate docs/images/*.png from the fake
provider, without a display.

    python3 tests/screenshots.py                # every screenshot
    python3 tests/screenshots.py --only dashboard workitems
    python3 tests/screenshots.py --cols 132 --rows 38 --font "Noto Sans Mono"

How: tests/demo.sh --standalone runs in a detached tmux server with a fixed
pane size (so the layout is the same on every machine), this script sends
the keys each screenshot needs and waits for the text that proves the
screen has finished loading, then `tmux capture-pane -e` gives the pane
with its colours as ANSI SGR sequences. Those are turned into Pango markup
(one <span> per styled run, with the terminal's 24-bit colours) and
rasterised by ImageMagick's pango: coder, which gets font fallback from
fontconfig - box-drawing glyphs, ✓/✗/⚠ and the 🆕 emoji all come out the
way a terminal would draw them. Needs: tmux, ImageMagick built with pango
(`magick -list format | grep PANGO`), nvim, git, python3, and a monospace
font (Noto Sans Mono by default; --font picks another).

The sequence in SHOTS is the whole story of a review: dashboard -> open
PR #101 -> its first file's diff -> the inline thread expanded -> the
complete dialog -> the work-items dashboard -> a work item. Each entry is
(name, keys to send, text to wait for, seconds to let toasts fade). Add a
step here to add a screenshot; the fixtures it relies on live in
tests/fake-provider.py. The workspace is fresh every run, so the pictures
are reproducible.
"""

import argparse
import collections
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DEFAULT = os.path.join(ROOT, "docs", "images")
SOCK = "azvicli-shots"

# (name, tmux key names, text that must appear before capturing, settle seconds)
SHOTS = [
    ("dashboard", [], "#201", 2),
    ("reviewer-files", ["Enter"], "throttle.py", 7),
    ("reviewer-diff", ["4j", "Enter"], "is_locked", 6),
    ("reviewer-thread", ["C-w", "l", "]C", "Tab"], "Should a locked", 6),
    ("complete-dialog", ["g", "m"], "Complete PR", 6),
    ("workitems", ["Escape", "Escape", "q", "W"], "Sprint 42", 6),
    ("workitem-detail", ["Enter"], "Acceptance", 6),
]

ANSI16 = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
          "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"]
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def tmux(*args):
    return subprocess.run(["tmux", "-L", SOCK] + list(args), capture_output=True, text=True)


def color256(n):
    if n < 16:
        return ANSI16[n]
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return "#{0:02x}{1:02x}{2:02x}".format(lv[n // 36], lv[(n // 6) % 6], lv[n % 6])
    v = 8 + (n - 232) * 10
    return "#{0:02x}{0:02x}{0:02x}".format(v)


def parse_ansi(raw):
    """Rows of (text, style) runs from a `capture-pane -e` dump."""
    rows = []
    for line in raw.split("\n"):
        st = {"fg": None, "bg": None, "bold": False, "italic": False, "underline": False, "reverse": False}
        runs, pos = [], 0
        for m in SGR.finditer(line):
            if m.start() > pos:
                runs.append((line[pos:m.start()], dict(st)))
            pos = m.end()
            params = [int(p) if p else 0 for p in m.group(1).split(";")] if m.group(1) else [0]
            i = 0
            while i < len(params):
                p = params[i]
                if p == 0:
                    st.update(fg=None, bg=None, bold=False, italic=False, underline=False, reverse=False)
                elif p == 1:
                    st["bold"] = True
                elif p == 3:
                    st["italic"] = True
                elif p == 4:
                    st["underline"] = True
                elif p == 7:
                    st["reverse"] = True
                elif p == 22:
                    st["bold"] = False
                elif p == 23:
                    st["italic"] = False
                elif p == 24:
                    st["underline"] = False
                elif p == 27:
                    st["reverse"] = False
                elif 30 <= p <= 37:
                    st["fg"] = ANSI16[p - 30]
                elif 90 <= p <= 97:
                    st["fg"] = ANSI16[p - 90 + 8]
                elif 40 <= p <= 47:
                    st["bg"] = ANSI16[p - 40]
                elif 100 <= p <= 107:
                    st["bg"] = ANSI16[p - 100 + 8]
                elif p == 39:
                    st["fg"] = None
                elif p == 49:
                    st["bg"] = None
                elif p in (38, 48) and i + 1 < len(params):
                    key = "fg" if p == 38 else "bg"
                    if params[i + 1] == 2 and i + 4 < len(params):
                        st[key] = "#{0:02x}{1:02x}{2:02x}".format(*params[i + 2:i + 5])
                        i += 4
                    elif params[i + 1] == 5 and i + 2 < len(params):
                        st[key] = color256(params[i + 2])
                        i += 2
                i += 1
        if pos < len(line):
            runs.append((line[pos:], dict(st)))
        rows.append(runs)
    return rows


def render_png(raw, png, cols, rows_n, font, font_pt):
    rows = parse_ansi(raw)
    counter = collections.Counter()
    for runs in rows:
        for text, st in runs:
            if st["bg"]:
                counter[st["bg"]] += len(text)
    page_bg = counter.most_common(1)[0][0] if counter else "#1c1c1c"
    default_fg = "#c7c7c7"
    lines = []
    for runs in rows[:rows_n]:
        parts, width = [], 0
        for text, st in runs:
            if not text:
                continue
            fg, bg = st["fg"] or default_fg, st["bg"] or page_bg
            if st["reverse"]:
                fg, bg = bg, fg
            attrs = ['foreground="{0}"'.format(fg), 'background="{0}"'.format(bg)]
            if st["bold"]:
                attrs.append('weight="bold"')
            if st["italic"]:
                attrs.append('style="italic"')
            if st["underline"]:
                attrs.append('underline="single"')
            parts.append("<span {0}>{1}</span>".format(" ".join(attrs), html.escape(text)))
            width += len(text)
        if width < cols:
            parts.append('<span background="{0}">{1}</span>'.format(page_bg, " " * (cols - width)))
        lines.append("".join(parts))
    markup = '<span font_family="{0}" font_size="{1}pt">{2}</span>'.format(font, font_pt, "\n".join(lines))
    src = png + ".pango"
    with open(src, "w", encoding="utf-8") as fh:
        fh.write(markup)
    try:
        subprocess.run(["magick", "-density", "144", "-background", page_bg, "pango:@" + src,
                        "-bordercolor", page_bg, "-border", "18", "-strip", png], check=True)
    finally:
        os.remove(src)


def wait_for(text, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if text in tmux("capture-pane", "-p").stdout:
            return True
        time.sleep(0.25)
    return False


def main():
    ap = argparse.ArgumentParser(description="regenerate docs/images from the fake provider")
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--workspace", help="demo workspace dir (default: a fresh temp dir)")
    ap.add_argument("--cols", type=int, default=132)
    ap.add_argument("--rows", type=int, default=38)
    ap.add_argument("--font", default="Noto Sans Mono")
    ap.add_argument("--font-size", type=float, default=11)
    ap.add_argument("--only", nargs="*", help="names from SHOTS to write (the sequence still runs in full)")
    ap.add_argument("--keep", action="store_true", help="leave the tmux session (-L %s) running" % SOCK)
    args = ap.parse_args()

    for tool in ("tmux", "magick", "nvim", "git", "python3"):
        if not shutil.which(tool):
            print("screenshots.py: {0} is not on PATH".format(tool), file=sys.stderr)
            return 1
    if "PANGO" not in subprocess.run(["magick", "-list", "format"], capture_output=True, text=True).stdout:
        print("screenshots.py: this ImageMagick has no pango coder", file=sys.stderr)
        return 1

    ws = args.workspace or tempfile.mkdtemp(prefix="azure-vicli-shots-")
    os.makedirs(args.out, exist_ok=True)
    tmux("kill-server")
    cmd = "bash tests/demo.sh --standalone --fresh --workspace {0}; sleep 60".format(ws)
    subprocess.run(["tmux", "-L", SOCK, "-f", "/dev/null", "new-session", "-d",
                    "-x", str(args.cols), "-y", str(args.rows), "-e", "COLORTERM=truecolor",
                    "-e", "TERM=xterm-256color", "-c", ROOT, cmd], check=True)
    try:
        if not wait_for("#201", 60):
            print("screenshots.py: the dashboard never listed the fake PRs:\n" + tmux("capture-pane", "-p").stdout,
                  file=sys.stderr)
            return 1
        failed = 0
        for name, keys, marker, settle in SHOTS:
            for k in keys:
                tmux("send-keys", k)
                time.sleep(0.4)
            if not wait_for(marker, 30):
                print("screenshots.py: {0}: never saw {1!r}:\n{2}".format(name, marker, tmux("capture-pane", "-p").stdout),
                      file=sys.stderr)
                failed += 1
                continue
            time.sleep(settle)
            if args.only and name not in args.only:
                continue
            raw = tmux("capture-pane", "-p", "-e").stdout
            png = os.path.join(args.out, name + ".png")
            render_png(raw, png, args.cols, args.rows, args.font, args.font_size)
            print("wrote", png)
        return 1 if failed else 0
    finally:
        if not args.keep:
            tmux("kill-server")
        if not args.workspace:
            shutil.rmtree(ws, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
