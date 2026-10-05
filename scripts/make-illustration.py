#!/usr/bin/env python3
"""Zeichnet die README-Illustration (Menüleiste + Menü) als SVG: Deutsch/Englisch × hell/dunkel.
Bewusst eine Illustration, kein Screenshot. Aufruf: python3 scripts/make-illustration.py"""

from pathlib import Path

THEMES = {
    "light": dict(bg="#f5f5f7", bar="#e8e8ed", text="#1d1d1f", faint="#b0b0b6", muted="#6e6e73",
                  menu="#ffffff", border="#d2d2d7", sep="#e5e5ea", hl="#0a84ff", hltext="#ffffff", ok="#30a46c",
                  legend="#ffffff"),
    "dark": dict(bg="#0d1117", bar="#2c2c2e", text="#f5f5f7", faint="#636366", muted="#98989d",
                 menu="#1c1c1e", border="#3a3a3c", sep="#38383a", hl="#0a84ff", hltext="#ffffff", ok="#3dd68c",
                 legend="#161b22"),
}

TEXTS = {
    "de": dict(
        connected="Verbunden – Nur TU", ip="IP-Adresse: 192.0.2.10", expiry="Session gültig bis Sa 10.10., 12:39",
        tip="Darf ruhig an bleiben – Trennen nur zum Profilwechsel", disconnect="Trennen",
        logout="Abmelden (Session beenden)", account="Account: e12345678@student.tuwien.ac.at",
        nopw="Ohne Mac-Passwort verbinden", login="Bei Anmeldung starten", stale="Hängende Sessions beenden …",
        more="Weitere", quit="TU VPN beenden", legend="Menüleiste", off="getrennt", on="verbunden – Nur TU",
        plus="verbunden – Alles getunnelt", busy="beschäftigt", caption="Illustration, kein Screenshot",
        clock="Mo 9:41"),
    "en": dict(
        connected="Connected – TU only", ip="IP address: 192.0.2.10", expiry="Session valid until Sat 10 Oct, 12:39",
        tip="Fine to leave on – disconnect only to switch profiles", disconnect="Disconnect",
        logout="Log out (end session)", account="Account: e12345678@student.tuwien.ac.at",
        nopw="Connect without Mac password", login="Open at login", stale="End stale sessions …",
        more="More", quit="Quit TU VPN", legend="Menu bar", off="disconnected", on="connected – TU only",
        plus="connected – all traffic", busy="busy", caption="Illustration, not a screenshot",
        clock="Mon 9:41"),
}

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"


def svg(lang: str, theme: str) -> str:
    c, t = THEMES[theme], TEXTS[lang]
    width, height = 760, 372
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
             f'font-family="{FONT}" role="img" aria-label="TU VPN – {t["caption"]}">',
             f'<rect width="{width}" height="{height}" rx="14" fill="{c["bg"]}"/>',
             # Menüleiste
             f'<rect x="0" y="0" width="{width}" height="30" rx="14" fill="{c["bar"]}"/>',
             f'<rect x="0" y="16" width="{width}" height="14" fill="{c["bar"]}"/>']
    # Platzhalter-Symbole rechts (generisch: Batterie, WLAN) + Uhr
    parts += [f'<rect x="590" y="10" width="22" height="11" rx="3" fill="none" stroke="{c["muted"]}" stroke-width="1.4"/>',
              f'<rect x="593" y="13" width="14" height="5" rx="1" fill="{c["muted"]}"/>',
              f'<path d="M628 21 l7 -8 a10 10 0 0 0 -14 0 z" fill="{c["muted"]}"/>',
              f'<text x="{width - 20}" y="20" font-size="13" text-anchor="end" fill="{c["text"]}">{t["clock"]}</text>']
    # "TU" hervorgehoben (Menü offen), sitzt über dem linken Rand des Menüs
    menu_w = 318
    tu_x = width - menu_w - 14 + 18
    parts += [f'<rect x="{tu_x - 8}" y="4" width="40" height="22" rx="5" fill="{c["hl"]}"/>',
              f'<text x="{tu_x + 12}" y="20" font-size="13.5" font-weight="700" text-anchor="middle" fill="{c["hltext"]}">TU</text>']

    # Menü
    menu_y = 32
    rows = [
        ("info-ok", "● " + t["connected"]), ("info", t["ip"]), ("info", t["expiry"]), ("info-small", t["tip"]), ("sep", ""),
        ("item", t["disconnect"]), ("item", t["logout"]), ("sep", ""),
        ("info", t["account"]), ("check", t["nopw"]), ("check", t["login"]), ("item", t["stale"]), ("sub", t["more"]),
        ("sep", ""), ("quit", t["quit"]),
    ]
    row_h, sep_h = 21, 9
    menu_h = 10 + sum(sep_h if kind == "sep" else row_h for kind, _ in rows)
    menu_x = width - menu_w - 14
    parts.append(f'<rect x="{menu_x}" y="{menu_y}" width="{menu_w}" height="{menu_h}" rx="9" fill="{c["menu"]}" '
                 f'stroke="{c["border"]}" stroke-width="1"/>')
    y = menu_y + 5
    for kind, label in rows:
        if kind == "sep":
            parts.append(f'<line x1="{menu_x + 10}" y1="{y + 4.5}" x2="{menu_x + menu_w - 10}" y2="{y + 4.5}" stroke="{c["sep"]}"/>')
            y += sep_h
            continue
        baseline = y + 15
        color = c["muted"] if kind.startswith("info") else c["text"]
        size = 11 if kind == "info-small" else 12.5
        if kind == "info-ok":
            parts.append(f'<text x="{menu_x + 22}" y="{baseline}" font-size="{size}" fill="{c["text"]}">'
                         f'<tspan fill="{c["ok"]}">●</tspan>{label[1:]}</text>')
        else:
            parts.append(f'<text x="{menu_x + 22}" y="{baseline}" font-size="{size}" fill="{color}">{label}</text>')
        if kind == "check":
            parts.append(f'<text x="{menu_x + 8}" y="{baseline}" font-size="11" fill="{c["text"]}">✓</text>')
        if kind == "sub":
            parts.append(f'<text x="{menu_x + menu_w - 14}" y="{baseline}" font-size="12" text-anchor="end" fill="{c["muted"]}">›</text>')
        if kind == "quit":
            parts.append(f'<text x="{menu_x + menu_w - 14}" y="{baseline}" font-size="12" text-anchor="end" fill="{c["muted"]}">⌘Q</text>')
        y += row_h

    # Legende links: Zustände des Menüleisten-Texts
    lx, ly = 28, 70
    parts.append(f'<rect x="{lx - 14}" y="{ly - 28}" width="300" height="176" rx="10" fill="{c["legend"]}" stroke="{c["border"]}"/>')
    parts.append(f'<text x="{lx}" y="{ly - 6}" font-size="12" font-weight="600" fill="{c["muted"]}" '
                 f'letter-spacing="0.4">{t["legend"].upper()}</text>')
    states = [("TU", c["faint"], t["off"]), ("TU", c["text"], t["on"]), ("TU+", c["text"], t["plus"]),
              ("TU…", c["muted"], t["busy"])]
    for index, (label, color, meaning) in enumerate(states):
        row_y = ly + 22 + index * 34
        parts.append(f'<rect x="{lx}" y="{row_y - 17}" width="58" height="24" rx="5" fill="{c["bar"]}"/>')
        parts.append(f'<text x="{lx + 29}" y="{row_y}" font-size="13.5" font-weight="700" text-anchor="middle" fill="{color}">{label}</text>')
        parts.append(f'<text x="{lx + 74}" y="{row_y}" font-size="13" fill="{c["text"]}">{meaning}</text>')

    parts.append(f'<text x="28" y="{height - 18}" font-size="11" fill="{c["muted"]}">{t["caption"]}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "docs"
    out.mkdir(exist_ok=True)
    for lang in TEXTS:
        for theme in THEMES:
            (out / f"menu-{lang}-{theme}.svg").write_text(svg(lang, theme), encoding="utf-8")
    print("docs/menu-*.svg geschrieben")
