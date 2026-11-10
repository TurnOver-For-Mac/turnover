#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The guides (Guides/*.md, written plainly) as web pages for the updates site and as one plain-text guide inside the
app. Headings stay headings, lists lists, tables tables, so a screen reader can move by them.
    python3 make-guides.py <site folder>      writes <site>/guides/*.html
    python3 make-guides.py --text <file>      writes the combined plain-text guide
    python3 make-guides.py --text <file> --language ru   writes the Russian guide (Guides/ru/*.md)"""
import glob, html, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TITLES = {"ru": "TurnOver: руководство"}

def sources(language=None):
    """The guide files for a language, in name order. A language folder, when given, sits beside the English files in
    Guides/, so the English build and site never see it."""
    folder = os.path.join(HERE, "Guides", language) if language else os.path.join(HERE, "Guides")
    return sorted(glob.glob(os.path.join(folder, "[0-9]*.md")))

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t

def to_html(md):
    out, para, items, kind, table, code = [], [], [], None, [], None
    title = "TurnOver guide"
    def flush():
        nonlocal para, items, kind, table
        if para: out.append("<p>" + inline(" ".join(para)) + "</p>"); para = []
        if items: out.append(f"<{kind}>\n" + "\n".join("<li>" + inline(i) + "</li>" for i in items) + f"\n</{kind}>"); items = []
        if table:
            rows = [r for r in table if not re.fullmatch(r"\|[\s:|-]+\|", r)]
            cells = [[c.strip() for c in r.strip("|").split("|")] for r in rows]
            head, body = cells[0], cells[1:]
            out.append("<table>\n<tr>" + "".join(f"<th scope=\"col\">{inline(c)}</th>" for c in head) + "</tr>\n" +
                       "\n".join("<tr>" + "".join((f"<th scope=\"row\">{inline(c)}</th>" if i == 0 else f"<td>{inline(c)}</td>") for i, c in enumerate(r)) + "</tr>" for r in body) + "\n</table>")
            table = []
    for raw in md.splitlines():
        line = raw.rstrip()
        if code is not None:
            if line.startswith("```"): out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>"); code = None
            else: code.append(line)
            continue
        if line.startswith("```"): flush(); code = []; continue
        if not line.strip(): flush(); continue
        m = re.match(r"^(#{1,3}) (.*)", line)
        if m:
            flush(); level = len(m.group(1))
            if level == 1: title = m.group(2)
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>"); continue
        if line.startswith("|"): para and flush(); table.append(line); continue
        m = re.match(r"^(- |\d+\. )(.*)", line)
        if m:
            k = "ol" if m.group(1)[0].isdigit() else "ul"
            if para or (items and kind != k): flush()
            kind = k; items.append(m.group(2)); continue
        if items and raw.startswith("   "): items[-1] += " " + line.strip(); continue
        flush() if table else None
        para.append(line.strip())
    flush()
    return title, "\n".join(out)

def page(title, body, back=True):
    nav = '<p><a href="index.html">All guides</a> · <a href="../index.html">TurnOver beta home</a></p>' if back else '<p><a href="../index.html">TurnOver beta home</a></p>'
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>{html.escape(title)}</title></head>
<body><main>
{body}
{nav}
</main></body></html>
"""

def slug(path):
    return re.sub(r"^\d+-", "", os.path.basename(path)[:-3])

def to_text(md):
    t = md
    t = re.sub(r"```\n(.*?)```", lambda m: "\n".join("    " + l for l in m.group(1).splitlines()) + "\n", t, flags=re.S)
    t = re.sub(r"^# (.*)$", lambda m: m.group(1).upper(), t, flags=re.M)
    t = re.sub(r"^#{2,3} (.*)$", r"\1", t, flags=re.M)
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)
    t = re.sub(r"^\|[\s:|-]+\|$\n", "", t, flags=re.M)
    t = re.sub(r"^\| (.*?) \| (.*?) \|$", r"  \1: \2", t, flags=re.M)
    return t

if __name__ == "__main__":
    if sys.argv[1:2] == ["--text"]:
        args = sys.argv[2:]
        language = None
        if "--language" in args:
            i = args.index("--language"); language = args[i + 1]; del args[i:i + 2]
        parts = [to_text(open(p, encoding="utf-8").read()).strip() for p in sources(language)]
        open(args[0], "w", encoding="utf-8").write(TITLES.get(language, "TurnOver: the guide") + "\n\n" + "\n\n\n".join(parts) + "\n")
        sys.exit(0)
    out = os.path.join(sys.argv[1], "guides"); os.makedirs(out, exist_ok=True)
    for p in sources():
        title, body = to_html(open(p, encoding="utf-8").read())
        open(os.path.join(out, slug(p) + ".html"), "w", encoding="utf-8").write(page(title, body))
    title, body = to_html(open(os.path.join(HERE, "Guides", "index.md"), encoding="utf-8").read())
    open(os.path.join(out, "index.html"), "w", encoding="utf-8").write(page(title, body, back=False))
    print(f"{len(sources())} guides in {out}")
