#!/usr/bin/env python3
"""Relay design canvas, pass 4: immersive style in the spirit of CleanMyMac (owner request).

Every window is a full-bleed colour scene per section (teal home, blue copying, amber paused, green
done, violet history), a labelled sidebar on the welcome screen that becomes an icon rail elsewhere,
large glossy illustrations, frosted glass panels and cards, and one round glowing action button.
All artwork is Relay's own, drawn here as SVG. Dark and light variants of every screen.

Usage: generate.py [existing canvas.json]   (keeps the editor's keys from the existing index)
Output: design/project/*.dc.html and design/project/canvas.json
"""
import datetime, itertools, json, math, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "project")
os.makedirs(ROOT, exist_ok=True)

ACCENT = "#3CCFBE"
ACC = "{{accent}}"
NUM = "font-variant-numeric: tabular-nums;"
T1, T2, T3 = "var(--t1)", "var(--t2)", "var(--t3)"
W, H = 1120, 720
FONT = '"Plus Jakarta Sans", -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'

THEMES = {
    "dark": {
        "t1": "#FFFFFF", "t2": "rgba(255,255,255,0.78)", "t3": "rgba(255,255,255,0.62)",
        "panel-hi": "rgba(255,255,255,0.17)", "panel-lo": "rgba(255,255,255,0.05)", "panel-border": "rgba(255,255,255,0.18)",
        "panel-shadow": "0 1px 0 rgba(255,255,255,0.20) inset, 0 24px 60px rgba(0,0,0,0.28)",
        "pill": "rgba(255,255,255,0.16)", "pill-border": "rgba(255,255,255,0.24)", "sel": "rgba(255,255,255,0.16)",
        "track": "rgba(255,255,255,0.18)", "sep": "rgba(255,255,255,0.12)", "row": "rgba(255,255,255,0.045)",
        "amber": "#FFC873", "amber-bg": "rgba(255,176,60,0.20)", "green": "#8CF5AE", "green-bg": "rgba(80,220,120,0.18)", "coral": "#FF9C8C",
        "check-bg": "rgba(255,255,255,0.92)", "check-ink": "#0B3B40", "sheet": "#18323F", "white-pill": "#FFFFFF", "white-pill-ink": "#0B1D26",
    },
    "light": {
        "t1": "#0B1D26", "t2": "rgba(11,29,38,0.76)", "t3": "rgba(11,29,38,0.64)",
        "panel-hi": "rgba(255,255,255,0.78)", "panel-lo": "rgba(255,255,255,0.40)", "panel-border": "rgba(255,255,255,0.90)",
        "panel-shadow": "0 1px 0 rgba(255,255,255,0.95) inset, 0 24px 60px rgba(20,50,70,0.14)",
        "pill": "rgba(255,255,255,0.72)", "pill-border": "rgba(11,29,38,0.10)", "sel": "rgba(255,255,255,0.70)",
        "track": "rgba(11,29,38,0.12)", "sep": "rgba(11,29,38,0.10)", "row": "rgba(255,255,255,0.35)",
        "amber": "#8A4F00", "amber-bg": "rgba(255,176,60,0.24)", "green": "#0B6E36", "green-bg": "rgba(40,180,90,0.16)", "coral": "#B3261E",
        "check-bg": "#0B3B40", "check-ink": "#FFFFFF", "sheet": "#F4FAFB", "white-pill": "#0B1D26", "white-pill-ink": "#FFFFFF",
    },
}


def radial(at, size, color):
    return f"radial-gradient({size} at {at}, {color}, transparent 62%)"


SCENES = {
    "home": {
        "dark": ", ".join([radial("78% 12%", "760px 560px", "rgba(60,207,190,0.62)"), radial("8% 96%", "720px 520px", "rgba(46,98,220,0.62)"),
                           "linear-gradient(140deg, #05283A 0%, #0A4A5C 48%, #0C2C62 100%)"]),
        "light": ", ".join([radial("78% 10%", "760px 560px", "rgba(60,207,190,0.45)"), radial("6% 96%", "720px 520px", "rgba(120,160,255,0.40)"),
                            "linear-gradient(140deg, #E6FBF7 0%, #C4EEE8 48%, #CBDDF8 100%)"]),
    },
    "copying": {
        "dark": ", ".join([radial("75% 10%", "760px 560px", "rgba(90,170,255,0.58)"), radial("10% 95%", "720px 520px", "rgba(60,207,190,0.45)"),
                           "linear-gradient(140deg, #071A4C 0%, #10398C 50%, #1A2A78 100%)"]),
        "light": ", ".join([radial("75% 10%", "760px 560px", "rgba(90,170,255,0.40)"), radial("10% 95%", "720px 520px", "rgba(60,207,190,0.32)"),
                            "linear-gradient(140deg, #E8F0FF 0%, #C6D9FF 50%, #D3E6F8 100%)"]),
    },
    "paused": {
        "dark": ", ".join([radial("75% 10%", "760px 560px", "rgba(255,170,60,0.55)"), radial("8% 96%", "720px 520px", "rgba(210,80,50,0.45)"),
                           "linear-gradient(140deg, #2A1305 0%, #5E2F0A 50%, #3A1808 100%)"]),
        "light": ", ".join([radial("75% 10%", "760px 560px", "rgba(255,170,60,0.40)"), radial("8% 96%", "720px 520px", "rgba(255,120,80,0.28)"),
                            "linear-gradient(140deg, #FFF3E2 0%, #FFDDB0 50%, #FBE5CF 100%)"]),
    },
    "done": {
        "dark": ", ".join([radial("30% 20%", "760px 560px", "rgba(150,240,140,0.40)"), radial("90% 95%", "720px 520px", "rgba(30,170,100,0.50)"),
                           "linear-gradient(140deg, #03240F 0%, #0A4B23 50%, #2E6A1C 100%)"]),
        "light": ", ".join([radial("30% 20%", "760px 560px", "rgba(150,240,140,0.40)"), radial("90% 95%", "720px 520px", "rgba(60,200,120,0.30)"),
                            "linear-gradient(140deg, #EAFAE6 0%, #C7EEC4 50%, #E2F4CD 100%)"]),
    },
    "history": {
        "dark": ", ".join([radial("75% 10%", "760px 560px", "rgba(160,110,255,0.55)"), radial("8% 96%", "720px 520px", "rgba(60,100,230,0.50)"),
                           "linear-gradient(140deg, #130A38 0%, #2A1674 50%, #18164E 100%)"]),
        "light": ", ".join([radial("75% 10%", "760px 560px", "rgba(160,110,255,0.36)"), radial("8% 96%", "720px 520px", "rgba(100,140,255,0.30)"),
                            "linear-gradient(140deg, #F0EBFF 0%, #DAD0FF 50%, #D9E2FB 100%)"]),
    },
    "slate": {
        "dark": ", ".join([radial("85% 0%", "700px 500px", "rgba(60,207,190,0.26)"), radial("0% 100%", "600px 420px", "rgba(70,90,200,0.26)"),
                           "linear-gradient(160deg, #0F1722 0%, #172233 100%)"]),
        "light": ", ".join([radial("85% 0%", "700px 500px", "rgba(60,207,190,0.20)"), radial("0% 100%", "600px 420px", "rgba(120,150,255,0.18)"),
                            "linear-gradient(160deg, #F5F8FA 0%, #E5ECF2 100%)"]),
    },
}

PANEL = ("background: linear-gradient(135deg, var(--panel-hi), var(--panel-lo)); border: 1px solid var(--panel-border); "
         "box-shadow: var(--panel-shadow); backdrop-filter: blur(30px) saturate(1.4); -webkit-backdrop-filter: blur(30px) saturate(1.4);")

_ids = itertools.count()


def uid(prefix):
    return f"{prefix}{next(_ids)}"


def svg_attr_fix(html):
    """SVG presentation attributes do not accept var(): move token colours into style."""
    def fix(tag):
        text = tag.group(0)
        moved = []

        def take(m):
            moved.append(f"{m.group(1)}: {m.group(2)}")
            return ""
        text2 = re.sub(r'\s(stroke|fill)="(var\([^"]+\))"', take, text)
        if not moved:
            return text
        if ' style="' in text2:
            return text2.replace(' style="', ' style="' + "; ".join(moved) + "; ", 1)
        return re.sub(r"^<(\w+)", lambda m: f'<{m.group(1)} style="' + "; ".join(moved) + '"', text2)
    return re.sub(r"<[a-zA-Z][^>]*>", fix, html)


# ----------------------------------------------------------------------------- line icons
PATHS = {
    "trash": '<path d="M4 7h16"></path><path d="M9.5 7V4.5h5V7"></path><path d="M6.5 7l1 13h9l1-13"></path><path d="M10 11v5.5M14 11v5.5"></path>',
    "chat": '<path d="M4 5.5h16v10H9l-4.5 4v-4H4z"></path><path d="M8 9.5h8M8 12.5h5"></path>',
    "bell": '<path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z"></path><path d="M10 20.5a2 2 0 0 0 4 0"></path>',
    "layers": '<path d="M12 3.5l8.5 4.5-8.5 4.5L3.5 8z"></path><path d="M3.5 12.5l8.5 4.5 8.5-4.5"></path><path d="M3.5 16.5l8.5 4.5 8.5-4.5"></path>',
    "upload": '<path d="M12 20V9"></path><path d="M7.5 13.5L12 9l4.5 4.5"></path><path d="M5 4.5h14"></path>',
    "map": '<rect x="3.5" y="4" width="17" height="16" rx="2.5"></rect><path d="M11 4v16M11 11h9.5M15.5 11v9"></path>',
    "shield": '<path d="M12 3l7.5 3v5.5c0 4.5-3.2 8-7.5 9.5-4.3-1.5-7.5-5-7.5-9.5V6z"></path><path d="M8.5 12l2.5 2.5 4.5-5"></path>',
    "calendar": '<rect x="3.5" y="5" width="17" height="15" rx="2.5"></rect><path d="M3.5 10h17M8 3v4M16 3v4"></path>',
    "copies": '<rect x="8" y="8" width="12" height="12" rx="2.5"></rect><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"></path>',
    "gear": '<circle cx="12" cy="12" r="3.2"></circle><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"></path>',
    "check": '<path d="M5 12.5l4.5 4.5L19 7.5"></path>',
    "fold": '<rect x="4" y="3" width="16" height="18" rx="2.6"></rect><path d="M12 3v18" stroke-dasharray="1.6 2.2"></path>',
    "folder": '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"></path>',
    "chevron": '<path d="M9 6l6 6-6 6"></path>',
    "chevdown": '<path d="M6 9l6 6 6-6"></path>',
    "back": '<path d="M15 6l-6 6 6 6"></path>',
    "lock": '<rect x="5" y="11" width="14" height="10" rx="2"></rect><path d="M8 11V8a4 4 0 0 1 8 0v3"></path>',
    "pause": '<path d="M9 6v12M15 6v12"></path>',
    "play": '<path d="M8 5.5v13l10.5-6.5z"></path>',
    "stop": '<rect x="6.5" y="6.5" width="11" height="11" rx="2"></rect>',
    "finder": '<rect x="3" y="4" width="18" height="16" rx="3"></rect><path d="M12 4v16"></path><path d="M7.5 9v1.5M16.5 9v1.5"></path><path d="M7.5 15.5c2.8 1.6 6.2 1.6 9 0"></path>',
    "alert": '<path d="M12 3.5l9.5 16.5h-19z"></path><path d="M12 10v4.5"></path><path d="M12 17.3v.2"></path>',
    "info": '<circle cx="12" cy="12" r="9"></circle><path d="M12 11v5.5"></path><path d="M12 7.8v.2"></path>',
    "search": '<circle cx="11" cy="11" r="6.5"></circle><path d="M16 16l4.5 4.5"></path>',
    "doc": '<path d="M7 3h7l5 5v13H7z"></path><path d="M14 3v5h5"></path>',
    "image": '<rect x="3.5" y="5" width="17" height="14" rx="2.5"></rect><circle cx="9" cy="10" r="1.6"></circle><path d="M20.5 16l-5-5L6 19"></path>',
    "video": '<rect x="3" y="6" width="13" height="12" rx="2.5"></rect><path d="M16 10.5l5-3v9l-5-3z"></path>',
    "arrows": '<path d="M12 4v11"></path><path d="M7.5 10.5L12 15l4.5-4.5"></path><path d="M5 19h14"></path>',
    "export": '<path d="M12 15V3.5"></path><path d="M8 7.5l4-4 4 4"></path><path d="M5 12.5v6A2.5 2.5 0 0 0 7.5 21h9a2.5 2.5 0 0 0 2.5-2.5v-6"></path>',
    "clock": '<circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path>',
    "sparkle": '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"></path><path d="M18.5 16.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"></path>',
    "speaker": '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"></path><path d="M15.5 9a4 4 0 0 1 0 6"></path><path d="M18 6.5a7.5 7.5 0 0 1 0 11"></path>',
    "cable": '<path d="M7 3v5M11 3v5"></path><rect x="5" y="8" width="8" height="5" rx="1.5"></rect><path d="M9 13v3a4 4 0 0 0 4 4h6"></path>',
    "lens": '<circle cx="12" cy="12" r="8.5"></circle><circle cx="12" cy="12" r="4.2"></circle><circle cx="10.4" cy="10.4" r="1"></circle>',
    "download": '<path d="M12 3.5v11"></path><path d="M7.5 10l4.5 4.5 4.5-4.5"></path><path d="M4 15.5v2A2.5 2.5 0 0 0 6.5 20h11a2.5 2.5 0 0 0 2.5-2.5v-2"></path>',
    "screens": '<rect x="7" y="2.5" width="10" height="19" rx="2.3"></rect><path d="M9.5 15l2-2.5 1.6 1.8 1.4-1.3 1 2"></path>',
}


def icon(name, size=16, color="currentColor", stroke=1.8):
    style = "" if color == "currentColor" else f' style="color: {color}"'
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="{stroke}" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"{style}>{PATHS[name]}</svg>')


def glyph(name, x, y, scale, color="#FFFFFF", width=1.9, opacity=1):
    return (f'<g transform="translate({x} {y}) scale({scale})" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linecap="round" stroke-linejoin="round" opacity="{opacity}">{PATHS[name]}</g>')


# ----------------------------------------------------------------------------- glossy artwork (Relay's own)
PALETTE = {
    "teal": ("#A6FFF3", "#34C9B8", "#0A6F6C"), "blue": ("#A9D4FF", "#3F8CF0", "#1B3FA8"),
    "violet": ("#D9C8FF", "#8B63F2", "#4424A8"), "amber": ("#FFE2A6", "#F5A93A", "#A8540C"),
    "green": ("#C9FFB8", "#46C96A", "#0D6B2E"), "pink": ("#FFC7DD", "#F0609A", "#9C1F5C"),
    "sky": ("#C7F1FF", "#46B6E6", "#135D93"),
}


def gem(size, shape, colors, glyph_name, face=False, tilt=0):
    """A glossy 3D-looking badge: disc, hexagon or squircle, with a white glyph (or a white face)."""
    u = uid("g")
    c1, c2, c3 = PALETTE[colors]
    pts = " ".join(f"{100 + 70 * math.cos(math.radians(a)):.1f},{100 + 70 * math.sin(math.radians(a)):.1f}" for a in range(-90, 270, 60))

    def shp(fill, attrs=""):
        if shape == "disc":
            return f'<circle cx="100" cy="100" r="80" fill="{fill}" {attrs}></circle>'
        if shape == "hex":
            return f'<polygon points="{pts}" fill="{fill}" stroke="{fill}" stroke-width="26" stroke-linejoin="round" {attrs}></polygon>'
        return f'<rect x="24" y="24" width="152" height="152" rx="46" fill="{fill}" {attrs}></rect>'

    rim = "" if shape == "hex" else shp("none", 'stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="1.6"')
    if face:
        inner = (f'<circle cx="100" cy="106" r="48" fill="#000000" opacity="0.18" filter="url(#{u}s)"></circle>'
                 f'<circle cx="100" cy="100" r="48" fill="url(#{u}f)"></circle>'
                 + glyph(glyph_name, 70, 70, 2.5, c3, 2.4))
    else:
        inner = glyph(glyph_name, 64, 67, 3, "#000000", 1.9, 0.18) + glyph(glyph_name, 64, 64, 3, "#FFFFFF", 1.9)
    return f'''<svg width="{size}" height="{size}" viewBox="0 0 200 200" aria-hidden="true" style="overflow: visible; display: block;">
<defs>
<linearGradient id="{u}b" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"></stop><stop offset="0.5" stop-color="{c2}"></stop><stop offset="1" stop-color="{c3}"></stop></linearGradient>
<radialGradient id="{u}h" cx="0.3" cy="0.22" r="0.75"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"></stop><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0.14"></stop><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"></stop></radialGradient>
<radialGradient id="{u}f" cx="0.38" cy="0.3" r="0.85"><stop offset="0" stop-color="#FFFFFF"></stop><stop offset="1" stop-color="#E4EEF0"></stop></radialGradient>
<filter id="{u}s" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="9"></feGaussianBlur></filter>
</defs>
<g transform="rotate({tilt} 100 100)">
<g transform="translate(0 14)" opacity="0.45" filter="url(#{u}s)">{shp("#000000")}</g>
{shp(f"url(#{u}b)")}
{shp(f"url(#{u}h)")}
{rim}
{inner}
</g></svg>'''


def phone_art(width=300, screen="photos", colors="teal", cable="plugged"):
    """The hero: a glossy Galaxy-Fold-like phone (two halves) with a USB-C cable."""
    u = uid("p")
    c1, c2, c3 = PALETTE[colors]
    tiles = ["#7FE3D6", "#FFB86B", "#A58BFF", "#6BB8FF", "#FF8FB1", "#9BE38F"]
    if screen == "photos":
        content = "".join(f'<rect x="{107 + (i % 3) * 32}" y="{96 + (i // 3) * 32}" width="26" height="26" rx="6" fill="{tiles[(i * 5) % 6]}" opacity="0.92"></rect>' for i in range(15))
        content += '<rect x="112" y="76" width="40" height="6" rx="3" fill="#FFFFFF" opacity="0.7"></rect>'
    elif screen == "notify":
        content = ('<rect x="108" y="76" width="92" height="58" rx="11" fill="#FFFFFF" opacity="0.95"></rect>'
                   '<rect x="117" y="86" width="48" height="6" rx="3" fill="#0B1D26" opacity="0.5"></rect>'
                   '<rect x="117" y="98" width="70" height="6" rx="3" fill="#0B1D26" opacity="0.8"></rect>'
                   f'<rect x="117" y="113" width="40" height="12" rx="6" fill="{ACCENT}"></rect>'
                   '<rect x="161" y="113" width="30" height="12" rx="6" fill="#0B1D26" opacity="0.15"></rect>'
                   + glyph("lock", 135, 190, 1.6, "#FFFFFF", 2, 0.9))
    elif screen == "pause":
        content = glyph("pause", 124, 146, 2.4, "#FFD58A", 2.4)
    elif screen == "check":
        content = glyph("check", 124, 146, 2.4, "#FFFFFF", 2.6)
    else:
        content = ""
    if cable == "plugged":
        cable_svg = (f'<path d="M152 292 C152 318 196 324 256 318" fill="none" stroke="url(#{u}c)" stroke-width="9" stroke-linecap="round"></path>'
                     f'<rect x="140" y="284" width="24" height="12" rx="4" fill="url(#{u}m)"></rect>'
                     f'<rect x="250" y="308" width="44" height="20" rx="7" fill="url(#{u}m)"></rect>'
                     '<rect x="292" y="313" width="10" height="10" rx="2" fill="#8FA0A7"></rect>')
    elif cable == "unplugged":
        cable_svg = (f'<path d="M226 324 C240 322 250 320 262 318" fill="none" stroke="url(#{u}c)" stroke-width="9" stroke-linecap="round"></path>'
                     f'<rect x="258" y="308" width="44" height="20" rx="7" fill="url(#{u}m)"></rect>'
                     '<path d="M200 300l-8-10M212 296l2-12M188 312l-12-4" stroke="#FFC873" stroke-width="3" stroke-linecap="round"></path>')
    else:
        cable_svg = ""
    h = width * 340 / 320
    return f'''<svg width="{width}" height="{h:.0f}" viewBox="0 0 320 340" aria-hidden="true" style="overflow: visible; display: block;">
<defs>
<linearGradient id="{u}b" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"></stop><stop offset="0.45" stop-color="{c2}"></stop><stop offset="1" stop-color="{c3}"></stop></linearGradient>
<linearGradient id="{u}k" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c2}"></stop><stop offset="1" stop-color="#062B33"></stop></linearGradient>
<linearGradient id="{u}s" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#16384A"></stop><stop offset="1" stop-color="#0A1824"></stop></linearGradient>
<linearGradient id="{u}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.6"></stop><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"></stop></linearGradient>
<linearGradient id="{u}c" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#E9F1F3"></stop><stop offset="1" stop-color="#B8C6CC"></stop></linearGradient>
<linearGradient id="{u}m" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F8FA"></stop><stop offset="1" stop-color="#9FB0B8"></stop></linearGradient>
<filter id="{u}blur" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="30"></feGaussianBlur></filter>
<filter id="{u}sh" x="-40%" y="-200%" width="180%" height="500%"><feGaussianBlur stdDeviation="7"></feGaussianBlur></filter>
<clipPath id="{u}clip"><rect x="92" y="52" width="124" height="240" rx="28"></rect></clipPath>
</defs>
<ellipse cx="160" cy="170" rx="118" ry="138" fill="{c2}" opacity="0.55" filter="url(#{u}blur)"></ellipse>
<ellipse cx="164" cy="316" rx="92" ry="10" fill="#000000" opacity="0.35" filter="url(#{u}sh)"></ellipse>
<rect x="132" y="38" width="120" height="236" rx="28" fill="url(#{u}k)" stroke="#FFFFFF" stroke-opacity="0.25" stroke-width="1.5"></rect>
<rect x="92" y="52" width="124" height="240" rx="28" fill="url(#{u}b)" stroke="#FFFFFF" stroke-opacity="0.6" stroke-width="1.5"></rect>
<rect x="101" y="62" width="106" height="220" rx="20" fill="url(#{u}s)"></rect>
{content}
<g clip-path="url(#{u}clip)"><polygon points="92,52 182,52 92,196" fill="url(#{u}g)" opacity="0.55"></polygon></g>
<circle cx="154" cy="70" r="3.4" fill="#000000" opacity="0.55"></circle>
{cable_svg}
</svg>'''


def thumb(kind, size=28):
    colors = {"video": ("#B7A2FF", "#6B4BE0"), "image": ("#7FEBDD", "#1C9C91"), "folder": ("#8CC6FF", "#2F6FE0"), "doc": ("#FFD28F", "#D98A1C")}[kind]
    return (f'<span aria-hidden="true" style="width: {size}px; height: {size}px; border-radius: {size * 0.28:.0f}px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; '
            f'background: linear-gradient(145deg, {colors[0]}, {colors[1]}); box-shadow: 0 1px 0 rgba(255,255,255,0.45) inset, 0 3px 8px rgba(0,0,0,0.18); color: #FFFFFF;">'
            f'{icon(kind, round(size * 0.56), "currentColor", 2)}</span>')


# ----------------------------------------------------------------------------- controls
def traffic_lights():
    dot = "display: block; width: 12px; height: 12px; border-radius: 6px;"
    return (f'<div aria-hidden="true" style="display: flex; gap: 8px;"><span style="{dot} background: #FF5F57;"></span>'
            f'<span style="{dot} background: #FEBC2E;"></span><span style="{dot} background: #28C840;"></span></div>')


def pill(label, icon_name=None, kind="glass", aria=None, small=False, extra=""):
    look = {"glass": f"background: var(--pill); border: 1px solid var(--pill-border); color: {T1};",
            "white": "background: var(--white-pill); border: 1px solid transparent; color: var(--white-pill-ink); box-shadow: 0 4px 14px rgba(0,0,0,0.18);",
            "accent": f"background: linear-gradient(180deg, {ACC}, #0A6F66); border: 1px solid rgba(255,255,255,0.35); color: #FFFFFF; box-shadow: 0 6px 18px rgba(60,207,190,0.35);"}[kind]
    ic = f'<span style="display: flex;">{icon(icon_name, 14, "currentColor", 2)}</span>' if icon_name else ""
    lab = f"<span>{label}</span>" if label else ""
    al = f' aria-label="{aria}"' if aria else ""
    pad = "0 12px" if label else "0"
    wd = "" if label else "width: 32px;"
    return (f'<button{al} style="height: {28 if small else 32}px; {wd} padding: {pad}; border-radius: 9px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; '
            f'font-family: inherit; font-size: {12.5 if small else 13}px; font-weight: 600; cursor: pointer; white-space: nowrap; {look} {extra}">{ic}{lab}</button>')


def round_button(label, bottom=24):
    return (f'<button style="position: absolute; left: 50%; bottom: {bottom}px; margin-left: -54px; width: 108px; height: 108px; border-radius: 54px; cursor: pointer; font-family: inherit; '
            f'border: 3px solid rgba(255,255,255,0.62); color: #FFFFFF; font-size: 20px; font-weight: 700; letter-spacing: 0.01em; text-shadow: 0 1px 3px rgba(0,50,45,0.5); '
            f'background: radial-gradient(circle at 50% 22%, rgba(255,255,255,0.55), rgba(255,255,255,0) 46%), linear-gradient(180deg, {ACC} 0%, #0A6F66 100%); '
            f'box-shadow: 0 0 0 7px rgba(60,207,190,0.18), 0 16px 48px rgba(60,207,190,0.6), inset 0 -10px 24px rgba(0,50,45,0.35);">{label}</button>')


def checkbox(state, label):
    if state == "on":
        look, mark = "background: var(--check-bg); border: 1px solid transparent; color: var(--check-ink);", icon("check", 12, "currentColor", 3.2)
    elif state == "mixed":
        look, mark = "background: var(--check-bg); border: 1px solid transparent;", '<span style="width: 8px; height: 2px; border-radius: 1px; background: var(--check-ink); display: block;"></span>'
    else:
        look, mark = f"border: 1.5px solid {T3};", ""
    return (f'<input type="checkbox" {"checked" if state == "on" else ""} aria-label="{label}" style="position: absolute; opacity: 0; width: 1px; height: 1px;">'
            f'<span aria-hidden="true" style="width: 18px; height: 18px; border-radius: 6px; box-sizing: border-box; flex-shrink: 0; display: flex; align-items: center; justify-content: center; {look}">{mark}</span>')


def pie(pct, color, size=18):
    a = math.radians(pct / 100 * 360 - 90)
    x, y = 9 + 7.5 * math.cos(a), 9 + 7.5 * math.sin(a)
    large = 1 if pct > 50 else 0
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="8.5" fill="#FFFFFF" opacity="0.95"></circle>'
            f'<path d="M9 9 L9 1.5 A7.5 7.5 0 {large} 1 {x:.2f} {y:.2f} Z" fill="{color}"></path></svg>')


def toggle(on):
    bg = f"background: {ACC};" if on else "background: var(--track);"
    knob = "right: 2px;" if on else "left: 2px;"
    return (f'<span aria-hidden="true" style="width: 38px; height: 22px; border-radius: 11px; {bg} position: relative; flex-shrink: 0; box-shadow: inset 0 1px 2px rgba(0,0,0,0.15);">'
            f'<span style="position: absolute; {knob} top: 2px; width: 18px; height: 18px; border-radius: 9px; background: #FFFFFF; box-shadow: 0 1px 3px rgba(0,0,0,0.3);"></span></span>')


def search_field(placeholder, width=200):
    return (f'<label style="height: 32px; width: {width}px; box-sizing: border-box; padding: 0 12px; border-radius: 9px; display: flex; align-items: center; gap: 6px; background: var(--pill); border: 1px solid var(--pill-border);">'
            f'<span style="display: flex; color: {T3};">{icon("search", 14)}</span><input type="search" placeholder="{placeholder}" aria-label="{placeholder}" '
            f'style="border: none; outline: none; background: transparent; color: {T1}; font-size: 13px; width: 100%;"></label>')


def chip(text):
    return f'<span style="padding: 5px 12px; border-radius: 999px; font-size: 13px; font-weight: 600; background: var(--pill); {NUM}">{text}</span>'


# ----------------------------------------------------------------------------- window chrome
RAIL_W, SIDE_W = 88, 260


def rail(selected, copying=None, attention=False):
    """The collapsed sidebar: icons only, the selected one in a glass tile, live status on the tile."""
    items = [("phone", "fold", "myGalaxy"), ("copies", "arrows", "Copies"), ("history", "clock", "History")]
    if attention:
        items.append(("attention", "alert", "Needs attention"))
    html = ""
    for key, ic, label in items:
        sel = key == selected
        status = ""
        if key == "copies" and copying:
            pct, color = copying
            status = f'<span style="position: absolute; right: -5px; top: -5px; display: flex; filter: drop-shadow(0 2px 4px rgba(0,0,0,0.3));">{pie(pct, color)}</span>'
        if key == "attention":
            status = '<span style="position: absolute; right: 2px; top: 2px; width: 10px; height: 10px; border-radius: 5px; background: #FFB547; box-shadow: 0 0 8px #FFB547;"></span>'
        tile = f"{PANEL} border-radius: 15px;" if sel else ""
        html += (f'<li><a href="#" aria-label="{label}" aria-current="{"page" if sel else "false"}" style="position: relative; width: 54px; height: 54px; box-sizing: border-box; display: flex; align-items: center; justify-content: center; '
                 f'color: {T1}; opacity: {1 if sel else 0.85}; {tile}">{icon(ic, 24, "currentColor", 1.8)}{status}</a></li>')
    return f'''<nav aria-label="Sections" style="position: absolute; left: 0; top: 52px; bottom: 0; width: {RAIL_W}px; border-right: 1px solid var(--sep); display: flex; flex-direction: column; align-items: center;">
  <ul style="list-style: none; margin: 40px 0 0; padding: 0; display: flex; flex-direction: column; gap: 14px;">{html}</ul>
  <a href="#" aria-label="Settings" style="margin-top: auto; margin-bottom: 22px; width: 54px; height: 54px; display: flex; align-items: center; justify-content: center; color: {T1}; opacity: 0.85;">{icon("gear", 22)}</a>
</nav>'''


def full_sidebar(selected, phone_label="Phone"):
    """The labelled sidebar, used on the welcome screen only."""
    items = [("phone", "fold", phone_label), ("copies", "arrows", "Copies"), ("history", "clock", "History")]
    html = ""
    for key, ic, label in items:
        sel = key == selected
        tile = PANEL if sel else "border: 1px solid transparent;"
        html += (f'<li><a href="#" aria-current="{"page" if sel else "false"}" style="height: 50px; box-sizing: border-box; padding: 0 16px; border-radius: 13px; display: flex; align-items: center; gap: 14px; '
                 f'text-decoration: none; color: {T1}; font-size: 14.5px; font-weight: 500; {tile}"><span style="display: flex;">{icon(ic, 22, "currentColor", 1.8)}</span>{label}</a></li>')
    return f'''<nav aria-label="Sections" style="position: absolute; left: 0; top: 52px; bottom: 0; width: {SIDE_W}px; box-sizing: border-box; padding: 40px 18px 22px; border-right: 1px solid var(--sep); display: flex; flex-direction: column;">
  <ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px;">{html}</ul>
  <a href="#" style="margin-top: auto; height: 50px; padding: 0 16px; display: flex; align-items: center; gap: 14px; text-decoration: none; color: {T1}; font-size: 14.5px; font-weight: 500;"><span style="display: flex;">{icon("gear", 22)}</span>Settings</a>
</nav>'''


def window(title, content, nav="rail", selected="phone", back=None, right="", copying=None, attention=False, phone_label="Phone"):
    left = RAIL_W if nav == "rail" else SIDE_W
    navigation = rail(selected, copying, attention) if nav == "rail" else full_sidebar(selected, phone_label)
    t = (f'<h1 style="position: absolute; left: 0; right: 0; top: 17px; margin: 0; text-align: center; font-size: 13px; font-weight: 600; color: {T2}; pointer-events: none;">{title}</h1>'
         if title else "")
    b = (f'<a href="#" style="position: absolute; left: {left + 24}px; top: 16px; display: flex; align-items: center; gap: 4px; font-size: 13px; font-weight: 600; color: {T1}; text-decoration: none;">'
         f'{icon("back", 15, "currentColor", 2.2)}{back}</a>') if back else ""
    r = f'<div style="position: absolute; right: 16px; top: 10px; display: flex; gap: 8px; align-items: center;">{right}</div>' if right else ""
    return f'''<div style="position: absolute; left: 20px; top: 20px;">{traffic_lights()}</div>{t}{b}{r}
{navigation}
<main style="position: absolute; left: {left}px; right: 0; top: 52px; bottom: 0;">{content}</main>'''


# ----------------------------------------------------------------------------- page rendering
def page(title, body, scene, w=W, h=H, script_extra="", vals="", radius=16):
    return {"title": title, "body": body, "scene": scene, "w": w, "h": h, "script_extra": script_extra, "vals": vals, "radius": radius}


def render_page(spec, theme):
    w, h = spec["w"], spec["h"]
    props = {"theme": {"editor": "enum", "options": ["dark", "light"], "default": theme},
             "accent": {"editor": "color", "default": ACCENT, "options": [ACCENT, "#0A84FF", "#F2B24C", "#BF5AF2"]},
             "$preview": {"width": w, "height": h}}
    tokens = "".join(".relay-" + n + "{" + ";".join(f"--{k}:{v}" for k, v in t.items()) + "}" for n, t in THEMES.items())
    scene = SCENES[spec["scene"]]
    scene_css = f".relay-dark .scene{{background:{scene['dark']}}}.relay-light .scene{{background:{scene['light']}}}"
    title = spec["title"] + (" (light)" if theme == "light" else "")
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&amp;display=swap" rel="stylesheet">
<style>
body{{margin:0;background:transparent;font-family:{FONT};-webkit-font-smoothing:antialiased}}
button,input{{font-family:inherit}}
{tokens}
{scene_css}
a{{color:inherit}}
</style>
</helmet>
<div class="{{{{themeClass}}}}" style="width: {w}px; height: {h}px; box-sizing: border-box; position: relative; overflow: hidden; color: {T1}; border-radius: {spec["radius"]}px; font-size: 13px;">
<div class="scene" aria-hidden="true" style="position: absolute; inset: 0;"></div>
{svg_attr_fix(spec["body"])}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{json.dumps(props)}'>
class Component extends DCLogic {{
{spec["script_extra"]}
  renderVals() {{
    return {{
      accent: this.props.accent ?? '{ACCENT}',
      themeClass: (this.props.theme ?? '{theme}') === 'light' ? 'relay-light' : 'relay-dark',{spec["vals"]}
    }};
  }}
}}
</script>
</body>
</html>
'''


FILES = {}


def headline(text, size=38, weight=500):
    return f'<h2 style="margin: 0; font-size: {size}px; font-weight: {weight}; letter-spacing: -0.015em; line-height: 1.15;">{text}</h2>'


def para(text, size=15, color=T2, width=None):
    mw = f"max-width: {width}px;" if width else ""
    return f'<p style="margin: 0; {mw} font-size: {size}px; line-height: 1.5; color: {color};">{text}</p>'



# ----------------------------------------------------------------------------- 0 · introduction (first launch only)
def intro_frame(step):
    """Three moments of the ~4 s introduction: light gathers, the mark lands and the name writes
    itself, then the promises and the Get Started button."""
    motes = ""
    import random as _r
    rng = _r.Random(7)
    for _ in range(46):
        angle, dist, size = rng.uniform(0, 6.283), rng.uniform(0.35, 0.75), rng.uniform(2, 5.5)
        k = 1.0 if step == 1 else 0.28
        x = 560 + math.cos(angle) * dist * k * 1120
        y = 250 + math.sin(angle) * dist * k * 1120 * 0.62
        color = rng.choice(["#3CCFBE", "#8FC7FF", "#FFFFFF"])
        motes += f'<span style="position: absolute; left: {x:.0f}px; top: {y:.0f}px; width: {size:.1f}px; height: {size:.1f}px; border-radius: 50%; background: {color}; opacity: {0.35 if step == 1 else 0.6}; box-shadow: 0 0 6px {color};"></span>'
    mark = "" if step == 1 else f'<div style="position: absolute; left: 50%; top: 60px; margin-left: -85px;">{gem(170, "squircle", "teal", "arrows")}</div>'
    ring = (f'<div style="position: absolute; left: 50%; top: {145 - 95 * (1.8 if step == 2 else 0.7) / 1.8}px; width: 190px; height: 190px; margin-left: -95px; border-radius: 50%; '
            f'border: 3px solid rgba(60,207,190,{0.8 if step == 1 else 0.25}); transform: scale({0.7 if step == 1 else 1.8});"></div>') if step < 3 else ""
    word = "" if step == 1 else '<div style="position: absolute; left: 0; right: 0; top: 262px; text-align: center; font-size: 64px; font-weight: 700; letter-spacing: -1.5px;">Relay</div>'
    tagline = "" if step == 1 else '<div style="position: absolute; left: 0; right: 0; top: 346px; text-align: center; font-size: 18px; font-weight: 500; color: rgba(255,255,255,0.8);">Copy from your Android phone. Never lose progress.</div>'
    cards = ""
    if step == 3:
        items = [("teal", "cable", "Plug in and go", "No app on the phone. Relay finds it."),
                 ("amber", "arrows", "Never starts over", "Unplugged? It resumes from the exact byte."),
                 ("violet", "sparkle", "Every copy at a glance", "Progress for every phone in the menu bar.")]
        cards = '<div style="position: absolute; left: 0; right: 0; top: 404px; display: flex; justify-content: center; gap: 16px;">' + "".join(
            f'<div style="width: 220px; height: 150px; box-sizing: border-box; padding: 18px; border-radius: 20px; display: flex; flex-direction: column; gap: 8px; {PANEL}">{gem(50, "disc", c, g)}'
            f'<span style="font-size: 15.5px; font-weight: 600;">{t}</span><span style="font-size: 13px; color: rgba(255,255,255,0.75);">{d}</span></div>' for c, g, t, d in items) + "</div>"
        cards += round_button("Get Started", bottom=34).replace("font-size: 20px", "font-size: 16.5px")
    caption = {1: "0.0 – 1.0 s · light streams in; the airy rise of the intro sound", 2: "1.0 – 2.0 s · the mark lands with a ring of light; the name writes itself, letter by letter",
               3: "2.5 – 3.4 s · three promises rise in; the round Get Started button blooms with the sparkle"}[step]
    skip = '' if step == 3 else f'<div style="position: absolute; right: 16px; top: 14px;">{pill("Skip", small=True)}</div>'
    return (f'<div style="position: absolute; inset: 0; color: #FFFFFF;">{motes}{ring}{mark}{word}{tagline}{cards}{skip}'
            f'<div style="position: absolute; left: 20px; bottom: 14px; font-size: 12px; color: rgba(255,255,255,0.6);">{caption}</div></div>')


for number in (1, 2, 3):
    FILES[f"Intro{number}.dc.html"] = (page(f"Introduction {number}", intro_frame(number), "home"), f"Introduction · {['', 'light gathers', 'the mark lands', 'Get Started'][number]}")

# ----------------------------------------------------------------------------- 1 · welcome (no phone)
content = f'''<div style="position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; padding-top: 34px; text-align: center;">
  {phone_art(250, "photos", "teal", "plugged")}
  <div style="margin-top: 26px; display: flex; flex-direction: column; gap: 10px; align-items: center;">
    {headline("Welcome to Relay", 40, 400)}
    {para("Plug in your Android phone with a data cable and unlock it. Relay finds it by itself.", 15.5, T2, 470)}
  </div>
</div>
<div role="status" style="position: absolute; left: 50%; bottom: 52px; transform: translateX(-50%); height: 44px; padding: 0 20px; border-radius: 22px; display: flex; align-items: center; gap: 10px; font-size: 14px; font-weight: 500; white-space: nowrap; {PANEL}">
  <span aria-hidden="true" style="width: 9px; height: 9px; border-radius: 5px; background: {ACC}; box-shadow: 0 0 0 5px rgba(60,207,190,0.25), 0 0 14px {ACC};"></span>Waiting for a phone…</div>
<a href="#" style="position: absolute; right: 24px; bottom: 22px; font-size: 12.5px; font-weight: 600; color: {T2};">Phone not showing up?</a>'''
FILES["Main.dc.html"] = (page("Relay: welcome", window(None, content, nav="full", selected="phone"), "home"), "Welcome (no phone yet)")


# ----------------------------------------------------------------------------- 2 · phone ready
def card(title, big, small, art, state=None, action="Review", tint=None):
    head = (f'<label style="display: flex; align-items: center; gap: 10px; cursor: pointer;">{checkbox(state, title)}<span style="font-size: 14px; font-weight: 500;">{title}</span></label>'
            if state else f'<span style="font-size: 14px; font-weight: 500;">{title}</span>')
    bg = f"background: linear-gradient(135deg, {tint}, var(--panel-lo)); border: 1px solid var(--panel-border); box-shadow: var(--panel-shadow);" if tint else PANEL
    return f'''<section style="position: relative; overflow: hidden; border-radius: 18px; padding: 18px 18px 16px 20px; box-sizing: border-box; display: flex; flex-direction: column; {bg}">
    <div aria-hidden="true" style="position: absolute; right: -22px; top: -26px;">{art}</div>
    <div style="position: relative;">{head}</div>
    <div style="position: relative; margin-top: auto; display: flex; align-items: flex-end; justify-content: space-between; gap: 12px;">
      <div style="display: flex; flex-direction: column; gap: 3px; min-width: 0; {NUM}"><span style="font-size: 28px; font-weight: 600; letter-spacing: -0.01em;">{big}</span><span style="font-size: 13.5px; line-height: 1.4; color: {T2};">{small}</span></div>
      {pill(action, small=True)}
    </div>
  </section>'''


cards_top = (card("New since last copy", "74 items", "1.8 GB to copy", gem(150, "squircle", "teal", "sparkle", tilt=-10), "on")
             + card("Camera", "1,284 photos", "and videos · 42.8 GB", gem(150, "disc", "blue", "lens"), "off")
             + card("Screenshots", "212 images", "212 MB", gem(150, "hex", "violet", "screens"), "off"))
cards_bottom = (card("Downloads", "38 files", "240 MB", gem(150, "squircle", "sky", "download", tilt=8), "off")
                + card("Cable · USB 2 · 30 MB/s", "3× faster with USB 3", "Your Fold7 supports USB 3. All photos: about 8 min instead of 24.",
                       gem(150, "disc", "amber", "cable"), None, "Which Cable?", tint="var(--amber-bg)"))
content = f'''<div style="position: absolute; left: 32px; right: 32px; top: 18px; text-align: center;">{headline("myGalaxy is ready. Here's what's on it:", 27, 500)}</div>
<div style="position: absolute; left: 32px; right: 32px; top: 80px; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; height: 172px;">{cards_top}</div>
<div style="position: absolute; left: 32px; right: 32px; top: 268px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.25fr); gap: 16px; height: 172px;">{cards_bottom}</div>
<div style="position: absolute; left: 0; right: 0; top: 468px; text-align: center; font-size: 14px; color: {T2}; {NUM}">
  Selected: <strong style="color: {T1}; font-weight: 600;">74 items · 1.8 GB · about 1 min</strong> to Pictures › From myGalaxy<span style="color: var(--amber); font-weight: 600;"> · about 20 s with a USB 3 cable</span></div>
{round_button("Copy")}'''
FILES["Overview.dc.html"] = (page("myGalaxy is ready", window("myGalaxy", content, selected="phone", right=pill("Browse Phone…", "folder")), "home"), "Phone ready (cards, cable advice)")

# ----------------------------------------------------------------------------- 3 · locked / charging only
steps = [("Unlock your phone", "Relay can only see files while the phone is unlocked the first time."),
         ("Open the USB notification", "Swipe down from the top. Tap “Charging this device via USB”."),
         ("Choose “File transfer”", "Tap “Allow” if the phone asks about access to data.")]
steps_html = "".join(f'''<li style="display: flex; gap: 14px; align-items: flex-start;">
    <span style="width: 28px; height: 28px; border-radius: 14px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 700; color: #FFFFFF; background: linear-gradient(180deg, {ACC}, #0A6F66); box-shadow: 0 4px 12px rgba(60,207,190,0.4);">{i + 1}</span>
    <span style="display: flex; flex-direction: column; gap: 3px;"><span style="font-size: 15px; font-weight: 600;">{t}</span><span style="font-size: 13.5px; line-height: 1.45; color: {T2};">{d}</span></span></li>''' for i, (t, d) in enumerate(steps))
content = f'''<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL} display: flex; align-items: center; gap: 30px; padding: 0 48px 0 30px;">
  <div style="flex-shrink: 0;">{phone_art(290, "notify", "teal", "plugged")}</div>
  <div style="display: flex; flex-direction: column; gap: 18px;">
    <span style="align-self: flex-start; padding: 4px 12px; border-radius: 999px; font-size: 12.5px; font-weight: 600; color: var(--amber); background: var(--amber-bg);">Connected · charging only</span>
    {headline("Let Relay see your files", 32, 500)}
    <ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 16px;">{steps_html}</ol>
    <div role="status" style="display: flex; align-items: center; gap: 9px; font-size: 13.5px; color: {T2};"><span aria-hidden="true" style="width: 8px; height: 8px; border-radius: 4px; background: {ACC}; box-shadow: 0 0 10px {ACC};"></span>Relay continues as soon as the phone is ready.</div>
  </div>
</section>'''
FILES["Guide.dc.html"] = (page("Unlock and choose File transfer", window("myGalaxy", content, selected="phone"), "home"), "Locked or Charging only")

# ----------------------------------------------------------------------------- 4 · another app holds the phone
content = f'''<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL} display: flex; align-items: center; gap: 40px; padding: 0 56px 0 40px;">
  <div style="flex-shrink: 0; display: flex; align-items: center; gap: 4px;">{gem(170, "squircle", "pink", "image", tilt=-8)}
    <svg width="46" height="10" viewBox="0 0 46 10" aria-hidden="true"><path d="M2 5h42" stroke="#FFFFFF" stroke-opacity="0.6" stroke-width="2.5" stroke-dasharray="3 6" stroke-linecap="round"></path></svg>
    {phone_art(170, "photos", "teal", "none")}</div>
  <div style="display: flex; flex-direction: column; gap: 16px;">
    {headline("Photos is using your phone", 32, 500)}
    {para("Only one app at a time can talk to the phone. Quit Photos and Relay picks up the connection straight away.", 15, T2, 400)}
    <div style="display: flex; gap: 10px; margin-top: 4px;">{pill("Try Again")}{pill("Quit Photos", kind="white")}</div>
    {para("Relay releases the phone from macOS's own camera service by itself. It never closes an app you opened without asking.", 12.5, T3, 400)}
  </div>
</section>'''
FILES["Busy.dc.html"] = (page("Another app is using the phone", window("myGalaxy", content, selected="phone"), "home"), "Another app has the phone")

# ----------------------------------------------------------------------------- 5 · browse & choose
rows = [(0, "folder", "Camera", "—", "74 items", "1.83 GB", "mixed", True), (1, "video", "20260917_081927.mp4", "17 Sep 2026, 08:20", "Video", "385.4 MB", "on", False),
        (1, "video", "20260920_173532.mp4", "20 Sep 2026, 17:36", "Video", "363.3 MB", "on", False), (1, "image", "20260926_161059.jpg", "26 Sep 2026, 16:11", "Photo", "4.2 MB", "on", False),
        (1, "image", "20260926_161031.jpg", "26 Sep 2026, 16:10", "Photo", "3.9 MB", "on", False), (1, "image", "20260926_155434.jpg", "26 Sep 2026, 15:54", "Photo", "4.4 MB", "off", False),
        (0, "folder", "Screenshots", "—", "212 items", "212 MB", "off", False), (0, "folder", "Restored", "—", "Counting…", "", "off", False)]
row_html = ""
for depth, kind, name, date, what, size, state, open_ in rows:
    chev = f'<span style="display: flex; color: {T3};">{icon("chevdown" if open_ else "chevron", 13, "currentColor", 2.2)}</span>' if kind == "folder" else '<span style="width: 13px;"></span>'
    muted = f"font-style: italic; color: {T3};" if what == "Counting…" else ""
    row_html += f'''<div role="row" style="display: grid; grid-template-columns: minmax(0, 1fr) 160px 90px 80px; align-items: center; height: 40px; padding: 0 18px; border-top: 1px solid var(--sep); font-size: 13.5px; {NUM}">
    <label role="cell" style="display: flex; align-items: center; gap: 10px; padding-left: {depth * 24}px; min-width: 0; cursor: pointer;">{chev}{checkbox(state, name)}{thumb(kind, 26)}
      <span style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: {600 if kind == "folder" else 400};">{name}</span></label>
    <span role="cell" style="color: {T2};">{date}</span><span role="cell" style="color: {T2}; {muted}">{what}</span><span role="cell" style="color: {T2}; text-align: right;">{size}</span></div>'''
content = f'''<section style="position: absolute; left: 32px; right: 32px; top: 16px; bottom: 150px; border-radius: 22px; overflow: hidden; {PANEL}">
  <div style="height: 48px; display: flex; align-items: center; gap: 7px; padding: 0 18px; font-size: 13.5px; color: {T2};">
    <span style="display: flex; color: {T1};">{icon("fold", 15)}</span>myGalaxy{icon("chevron", 12, T3, 2)}Internal storage{icon("chevron", 12, T3, 2)}<strong style="color: {T1}; font-weight: 600;">DCIM</strong></div>
  <div role="table" aria-label="DCIM on myGalaxy">
    <div role="row" style="display: grid; grid-template-columns: minmax(0, 1fr) 160px 90px 80px; height: 30px; align-items: center; padding: 0 18px; font-size: 12px; font-weight: 600; color: {T3}; border-top: 1px solid var(--sep);">
      <span role="columnheader" style="padding-left: 77px;">Name</span><span role="columnheader">Date Modified</span><span role="columnheader">Kind</span><span role="columnheader" style="text-align: right;">Size</span></div>
    {row_html}
  </div>
</section>
<div style="position: absolute; left: 40px; bottom: 58px; display: flex; flex-direction: column; gap: 3px; {NUM}">
  <span style="font-size: 15px; font-weight: 600;">73 items · 1.83 GB · about 1 min</span>
  <span style="font-size: 13px; color: {T2};">to Pictures › From myGalaxy · <a href="#" style="font-weight: 600;">Change</a></span></div>
<div style="position: absolute; right: 40px; bottom: 58px; display: flex; align-items: center; gap: 10px; max-width: 290px; padding: 10px 14px; border-radius: 14px; background: var(--amber-bg);">
  <span style="display: flex; color: var(--amber);">{icon("cable", 18, "currentColor", 2)}</span>
  <span style="font-size: 12.5px; line-height: 1.4; color: {T1};">About 20 s with a USB 3 cable. <a href="#" style="font-weight: 600;">Which cable?</a></span></div>
{round_button("Copy")}'''
FILES["Browse.dc.html"] = (page("Choose what to copy", window("DCIM", content, selected="phone", back="myGalaxy", right=search_field("Search DCIM", 190)), "home"), "Browse and choose")


# ----------------------------------------------------------------------------- 6 · copying / paused
def hero_ring(pct, color, art, size=330, glow=True):
    r = size / 2 - 12
    c = 2 * math.pi * r
    u = uid("r")
    arc = f'stroke-dasharray="{c * pct / 100:.1f} {c:.1f}" transform="rotate(-90 {size / 2} {size / 2})"'
    glow_arc = f'<circle cx="{size / 2}" cy="{size / 2}" r="{r}" fill="none" stroke="{color}" stroke-width="10" stroke-linecap="round" {arc} filter="url(#{u})" opacity="0.8"></circle>' if glow else ""
    return f'''<div role="progressbar" aria-label="Copy progress" aria-valuenow="{pct}" aria-valuemin="0" aria-valuemax="100" style="position: relative; width: {size}px; height: {size}px; flex-shrink: 0;">
    <svg width="{size}" height="{size}" viewBox="0 0 {size} {size}" aria-hidden="true" style="position: absolute; inset: 0; overflow: visible;">
      <defs><filter id="{u}" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="6"></feGaussianBlur></filter></defs>
      <circle cx="{size / 2}" cy="{size / 2}" r="{r}" fill="none" stroke="#FFFFFF" stroke-opacity="0.2" stroke-width="10"></circle>
      {glow_arc}
      <circle cx="{size / 2}" cy="{size / 2}" r="{r}" fill="none" stroke="{color}" stroke-width="10" stroke-linecap="round" {arc}></circle>
    </svg>
    <div style="position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding-bottom: 20px;">{art}</div>
    <span style="position: absolute; left: 50%; bottom: 22px; transform: translateX(-50%); padding: 5px 14px; border-radius: 999px; font-size: 15px; font-weight: 700; {NUM} {PANEL}">{pct}%</span>
  </div>'''


def file_row(kind, name, size, state):
    status = {"done": f'<span style="display: flex; color: {T1};">{icon("check", 18, "currentColor", 2.6)}</span>',
              "now": f'<span style="display: flex;">{pie(41, "#3F8CF0", 20)}</span>',
              "wait": f'<span style="width: 10px; height: 10px; border-radius: 5px; background: {T3};"></span>'}[state]
    return (f'<li style="display: flex; align-items: center; gap: 14px; height: 48px;">{thumb(kind, 34)}<span style="font-size: 14.5px; font-weight: 500; flex-grow: 1; {NUM}">{name}</span>'
            f'<span style="font-size: 13.5px; color: {T2}; {NUM}">{size}</span><span style="width: 22px; display: flex; justify-content: center;">{status}</span></li>')


files_list = (file_row("image", "20260917_081544.jpg", "4.1 MB", "done") + file_row("video", "20260916_193002.mp4", "96.2 MB", "done")
              + file_row("video", "20260917_081927.mp4", "385.4 MB", "now") + file_row("image", "20260918_212923.jpg", "5.2 MB", "wait")
              + file_row("image", "20260918_213002.jpg", "4.8 MB", "wait"))
content = f'''<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL} display: flex; align-items: center; gap: 34px; padding: 0 44px 0 30px;">
  {hero_ring(62, ACC, phone_art(210, "photos", "blue", "plugged"))}
  <div style="flex-grow: 1; display: flex; flex-direction: column; gap: 14px; min-width: 0;">
    {headline("Copying from myGalaxy…", 30, 400)}
    <div style="display: flex; gap: 8px; flex-wrap: wrap;">{chip("31.4 MB/s")}{chip("23 s left")}{chip("46 of 74 files · 1.13 of 1.83 GB")}</div>
    <ul style="list-style: none; margin: 4px 0 0; padding: 0;">{files_list}</ul>
    <div style="display: flex; align-items: center; gap: 10px; margin-top: 6px;">
      <span style="display: flex; align-items: center; gap: 8px; flex-grow: 1; font-size: 12.5px; color: {T2};"><span style="display: flex; color: var(--amber);">{icon("cable", 16, "currentColor", 2)}</span>USB 2 link: about 20 s with a USB 3 cable.</span>
      {pill("Pause", "pause")}{pill("Stop")}</div>
  </div>
</section>'''
FILES["Copying.dc.html"] = (page("Copying", window("Copying", content, selected="copies", copying=(62, "#3F8CF0")), "copying"), "Copying")

facts = [("Finished", "45 files"), ("Resumes from", "20260917_081927.mp4 at 158 MB"), ("Still to copy", "28 files · 0.70 GB")]
facts_html = "".join(f'<li style="display: flex; justify-content: space-between; gap: 16px; padding: 11px 0; {"" if i == 0 else "border-top: 1px solid var(--sep);"} font-size: 14px; {NUM}"><span style="color: {T2};">{a}</span><span style="font-weight: 600;">{b}</span></li>' for i, (a, b) in enumerate(facts))
content = f'''<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL} display: flex; align-items: center; gap: 34px; padding: 0 44px 0 30px;">
  {hero_ring(62, "#FFB547", phone_art(210, "pause", "amber", "unplugged"), glow=False)}
  <div style="flex-grow: 1; display: flex; flex-direction: column; gap: 14px;">
    {headline("Reconnect myGalaxy to continue", 30, 400)}
    {para("The phone was unplugged. Everything copied so far is safe on your Mac. Plug it back in, into any port, and Relay carries on by itself.", 15, T2, 470)}
    <ul style="list-style: none; margin: 0; padding: 0; max-width: 470px;">{facts_html}</ul>
    <div style="display: flex; align-items: center; gap: 12px;">
      <span role="status" style="display: flex; align-items: center; gap: 9px; flex-grow: 1; font-size: 13px; color: {T2};"><span aria-hidden="true" style="width: 8px; height: 8px; border-radius: 4px; background: #FFB547; box-shadow: 0 0 10px #FFB547;"></span>Waiting for myGalaxy · the Mac stays awake</span>
      {pill("Stop")}</div>
  </div>
</section>'''
FILES["Paused.dc.html"] = (page("Copy paused", window("Paused", content, selected="copies", copying=(62, "#F5A93A")), "paused"), "Paused (phone unplugged)")


# ----------------------------------------------------------------------------- 7 · done
def result_row(g, big, small, link=None):
    lk = f' · <a href="#" style="font-weight: 600;">{link}</a>' if link else ""
    return (f'<li style="display: flex; align-items: center; gap: 14px;"><span style="flex-shrink: 0;">{g}</span>'
            f'<span style="display: flex; flex-direction: column; gap: 2px;"><span style="font-size: 18px; font-weight: 600; {NUM}">{big}</span><span style="font-size: 13.5px; color: {T2};">{small}{lk}</span></span></li>')


content = f'''<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL}">
  <div style="position: absolute; left: -34px; top: 76px;">{gem(330, "disc", "green", "check", face=True)}</div>
  <div style="position: absolute; left: 380px; right: 40px; top: 92px; display: flex; flex-direction: column; gap: 22px;">
    {headline("Copy complete!", 36, 500)}
    <ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 16px;">
      {result_row(gem(46, "disc", "green", "arrows"), "72 files · 1.79 GB", "safely copied to Pictures › From myGalaxy")}
      {result_row(gem(46, "disc", "amber", "alert"), "2 files need attention", "one is gone from the phone, one was refused", "Review")}
      {result_row(gem(46, "disc", "sky", "info"), "3 names adjusted for macOS", "IMG.jpg and img.jpg can't share a folder", "See Changes")}
    </ul>
    <span style="font-size: 13px; color: {T3}; {NUM}">58 s · average 31.2 MB/s over USB 2 · 1 reconnect</span>
  </div>
  <a href="#" style="position: absolute; left: 30px; bottom: 26px; font-size: 13.5px; font-weight: 600;">View Log</a>
  <div style="position: absolute; right: 24px; bottom: 20px; display: flex; gap: 10px;">{pill("Show in Finder", "finder")}{pill("Done", kind="white")}</div>
</section>'''
FILES["Done.dc.html"] = (page("Copy finished", window("Copy finished", content, selected="copies", attention=True), "done"), "Done")

# ----------------------------------------------------------------------------- 8 · history
ok = ("Done", "var(--green)", "var(--green-bg)")
history = [("Today, 16:42", "myGalaxy", "DCIM › Camera", "Pictures › From myGalaxy", "74 files", "1.83 GB", ("2 need attention", "var(--amber)", "var(--amber-bg)"), "teal"),
           ("Today, 11:05", "myGalaxy", "Download", "Desktop › Phone downloads", "12 files", "240 MB", ok, "teal"),
           ("Yesterday, 21:30", "Pixel 8 Pro", "DCIM", "External SSD › Pixel", "1,120 files", "11.8 GB", ok, "blue"),
           ("24 Sep, 18:02", "myGalaxy", "Movies", "Movies › Phone", "3 files", "2.3 GB", ("Cancelled", T2, "var(--pill)"), "teal"),
           ("20 Sep, 09:14", "myGalaxy", "DCIM, Pictures", "Pictures › From myGalaxy", "1,284 files", "42.8 GB", ok, "teal")]
hrows = "".join(f'''<li style="display: grid; grid-template-columns: 44px minmax(0, 1fr) 130px 90px 76px 140px; align-items: center; gap: 14px; height: 62px; padding: 0 22px; {"" if i == 0 else "border-top: 1px solid var(--sep);"} {NUM}">
    {gem(40, "squircle", col, "fold")}
    <span style="display: flex; flex-direction: column; gap: 2px; min-width: 0;"><span style="font-size: 14.5px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">{what} <span style="font-weight: 400; color: {T2};">from {p}</span></span><span style="font-size: 12.5px; color: {T3};">to {dest}</span></span>
    <span style="font-size: 13px; color: {T2};">{d}</span><span style="font-size: 13px; color: {T2}; text-align: right;">{n}</span><span style="font-size: 13px; color: {T2}; text-align: right;">{s}</span>
    <span style="justify-self: end; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; color: {r[1]}; background: {r[2]};">{r[0]}</span></li>''' for i, (d, p, what, dest, n, s, r, col) in enumerate(history))
content = f'''<div style="position: absolute; left: 40px; right: 40px; top: 20px; display: flex; align-items: baseline; justify-content: space-between;">{headline("History", 30, 500)}<span style="font-size: 14px; color: {T2}; {NUM}">5 copies · 59 GB</span></div>
<section aria-label="Copy history" style="position: absolute; left: 40px; right: 40px; top: 80px; border-radius: 22px; overflow: hidden; padding: 6px 0; {PANEL}"><ul style="list-style: none; margin: 0; padding: 0;">{hrows}</ul></section>'''
FILES["History.dc.html"] = (page("Copy history", window("History", content, selected="history", right=search_field("Search", 170)), "history"), "History")

# ----------------------------------------------------------------------------- 9 · menu bar extra
MW, MH = 380, 580


def job(device, what, pct, left, right, color, tag_html=None, hint=None, colors="teal"):
    h = f'<div style="display: flex; align-items: center; gap: 6px; font-size: 11.5px; color: {T2};"><span style="display: flex; color: var(--amber);">{icon("cable", 13, "currentColor", 2)}</span>{hint}</div>' if hint else ""
    return f'''<li style="padding: 12px 13px; border-radius: 16px; display: flex; flex-direction: column; gap: 8px; {PANEL}">
    <div style="display: flex; align-items: center; gap: 10px;">{gem(34, "squircle", colors, "fold")}
      <span style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0;"><span style="font-size: 13.5px; font-weight: 600;">{device}</span><span style="font-size: 12px; color: {T2}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">{what}</span></span>{tag_html or ""}</div>
    <div role="progressbar" aria-label="{device}: {what}" aria-valuenow="{pct}" aria-valuemin="0" aria-valuemax="100" style="height: 7px; border-radius: 4px; background: var(--track); overflow: hidden;"><div style="width: {pct}%; height: 7px; border-radius: 4px; background: {color}; box-shadow: 0 0 10px {color};"></div></div>
    <div style="display: flex; justify-content: space-between; font-size: 12px; color: {T2}; {NUM}"><span>{left}</span><span>{right}</span></div>{h}
  </li>'''


def tag(text, color, bg):
    return f'<span style="padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; color: {color}; background: {bg};">{text}</span>'


body = f'''<div aria-hidden="true" style="position: relative; height: 26px; display: flex; align-items: center; justify-content: flex-end; gap: 14px; padding: 0 12px; background: rgba(0,0,0,0.18); font-size: 12.5px; font-weight: 500;">
  <span style="padding: 1px 7px; border-radius: 5px; background: var(--sel); display: flex; align-items: center; gap: 4px;">{icon("arrows", 14, "currentColor", 2)}<span style="{NUM}">62%</span></span><span>Sun 27 Sep  16:42</span></div>
<section aria-label="Relay copies" style="position: absolute; left: 12px; right: 12px; top: 38px; bottom: 12px; display: flex; flex-direction: column; gap: 10px;">
  <div style="display: flex; align-items: center; justify-content: space-between;"><div style="display: flex; flex-direction: column;"><h1 style="margin: 0; font-size: 16px; font-weight: 700;">Relay</h1><span style="font-size: 12px; color: {T2};">2 copying · 1 paused</span></div>
    {pill("Pause All", "pause", small=True)}</div>
  <ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px;">
    {job("myGalaxy", "Camera → Pictures › From myGalaxy", 62, "46 of 74 · 31.4 MB/s", "23 s left", ACC, hint="USB 2 · about 3× faster with a USB 3 cable")}
    {job("myGalaxy", "Movies → Desktop › Movies backup", 8, "3 of 41 files", "after Camera", "#9FB0B8", tag("Next", T2, "var(--pill)"))}
    {job("Pixel 8 Pro", "DCIM → External SSD › Pixel", 36, "4.2 of 11.8 GB", "reconnect the phone", "#FFB547", tag("Paused", "var(--amber)", "var(--amber-bg)"), colors="blue")}
  </ul>
  <div style="display: flex; gap: 8px; align-items: center; padding: 10px 12px; border-radius: 12px; background: var(--amber-bg); font-size: 12px;"><span style="display: flex; color: var(--amber);">{icon("alert", 15, "currentColor", 2)}</span><span>1 file needs attention in Pixel 8 Pro's copy. <a href="#" style="font-weight: 600;">Review</a></span></div>
  <div style="margin-top: auto; display: flex; gap: 8px;">{pill("Open Relay", kind="accent", extra="flex-grow: 1;")}{pill(None, "gear", aria="Settings")}</div>
</section>'''
FILES["MenuBar.dc.html"] = (page("Menu bar: every copy at a glance", body, "home", MW, MH, radius=18), "Menu bar extra")

# ----------------------------------------------------------------------------- 10 · settings
SW, SH = 640, 600


def settings_window(active, groups):
    tabs = "".join(f'''<button aria-pressed="{"true" if n == active else "false"}" style="width: 88px; height: 58px; box-sizing: border-box; border-radius: 14px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; cursor: pointer; font-size: 12px; font-weight: 600; color: {T1};
        {PANEL if n == active else "background: transparent; border: 1px solid transparent;"}">{icon(ic, 20)}{n}</button>''' for n, ic in [("General", "gear"), ("Sounds", "speaker"), ("Advanced", "sparkle")])
    return f'''<div style="position: absolute; left: 20px; top: 20px;">{traffic_lights()}</div>
<h1 style="margin: 0; position: absolute; left: 0; right: 0; top: 17px; text-align: center; font-size: 13px; font-weight: 600; color: {T2};">{active}</h1>
<div style="position: absolute; left: 0; right: 0; top: 48px; display: flex; justify-content: center; gap: 6px;">{tabs}</div>
<div style="position: absolute; left: 28px; right: 28px; top: 128px; display: flex; flex-direction: column; gap: 14px;">{"".join(groups)}</div>'''


def group(rows_):
    return f'<div style="border-radius: 16px; overflow: hidden; {PANEL}">' + "".join(f'<div style="{"" if i == 0 else "border-top: 1px solid var(--sep);"}">{r}</div>' for i, r in enumerate(rows_)) + "</div>"


def row(title, sub, control):
    s = f'<span style="font-size: 12px; line-height: 1.4; color: {T2};">{sub}</span>' if sub else ""
    return f'<div style="display: flex; align-items: center; gap: 14px; padding: 11px 16px;"><span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1;"><span style="font-size: 13.5px; font-weight: 500;">{title}</span>{s}</span>{control}</div>'


def trow(title, sub, on):
    s = f'<span style="font-size: 12px; line-height: 1.4; color: {T2};">{sub}</span>' if sub else ""
    return (f'<label style="display: flex; align-items: center; gap: 14px; padding: 11px 16px; cursor: pointer;"><input type="checkbox" {"checked" if on else ""} style="position: absolute; opacity: 0; width: 1px; height: 1px;">'
            f'<span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1;"><span style="font-size: 13.5px; font-weight: 500;">{title}</span>{s}</span>{toggle(on)}</label>')


def popup(text, ic=None):
    i = f'<span style="display: flex; color: {T2};">{icon(ic, 14)}</span>' if ic else ""
    return (f'<button style="height: 28px; padding: 0 9px 0 11px; border-radius: 8px; display: flex; align-items: center; gap: 6px; font-size: 12.5px; font-weight: 500; color: {T1}; cursor: pointer; white-space: nowrap; '
            f'background: var(--pill); border: 1px solid var(--pill-border);">{i}{text}<span style="display: flex; color: {T2};">{icon("chevdown", 12, "currentColor", 2.2)}</span></button>')


groups = [group([row("Copy to", "Where new copies go unless you choose another folder.", popup("Pictures › From phone", "folder")),
                 row("When a file already exists", "Same size and date means it is already there.", popup("Skip if identical"))]),
          group([trow("Keep copying when Relay is closed", "A background helper keeps copies going after you quit, and after a restart.", True),
                 trow("Keep the Mac awake while copying", "The display can still sleep.", True),
                 trow("Show Relay in the menu bar", "Every copy's progress, one click away.", True),
                 trow("Suggest a faster cable", "Tell me when a phone could copy faster with another cable or port.", True)])]
FILES["Settings.dc.html"] = (page("Settings: General", settings_window("General", groups), "slate", SW, SH, radius=14), "Settings · General")

groups = [group([trow("Play sounds", "A soft chime when a phone connects and when a copy finishes.", True),
                 row("Volume", "Follows the Mac's alert volume.", f'<input type="range" min="0" max="100" value="70" aria-label="Sound volume" style="width: 170px; accent-color: {ACC};">')]),
          group([trow("Phone connected", None, True), trow("Copy started", None, False), trow("Paused and resumed", None, True), trow("Copy finished", None, True), trow("Needs attention", None, True)]),
          para("Relay stays silent when the Mac's “Play user interface sound effects” is off, during Focus, and while another app is full screen.", 12, T2)]
FILES["SettingsSounds.dc.html"] = (page("Settings: Sounds", settings_window("Sounds", groups), "slate", SW, SH, radius=14), "Settings · Sounds")

chunks = ["4 MB", "8 MB", "16 MB", "32 MB", "64 MB"]
seg = "".join(f'<button aria-pressed="{"true" if c == "8 MB" else "false"}" style="height: 24px; padding: 0 10px; border-radius: 7px; border: none; font-size: 12px; font-weight: 600; cursor: pointer; {NUM} '
              f'{"background: var(--white-pill); color: var(--white-pill-ink);" if c == "8 MB" else "background: transparent; color: " + T2 + ";"}">{c}</button>' for c in chunks)
groups = [group([row("Chunk size", "8 MB is fastest on most phones; larger chunks react later to problems.",
                     f'<div role="group" aria-label="Chunk size" style="display: flex; gap: 2px; padding: 3px; border-radius: 9px; background: var(--pill);">{seg}</div>')]),
          group([trow("Free the phone from Image Capture automatically", "macOS's camera service grabs Android phones when plugged in. Relay releases it while copying; iPhone and camera imports pause meanwhile.", True),
                 trow("Double-check copies against the phone", "Reads every file a second time. Slower; for irreplaceable files.", False)]),
          group([row("Activity log", "Recent events, for troubleshooting.", pill("Open Log", "doc", small=True))])]
FILES["SettingsAdvanced.dc.html"] = (page("Settings: Advanced", settings_window("Advanced", groups), "slate", SW, SH, radius=14), "Settings · Advanced")

# ----------------------------------------------------------------------------- 11 · activity log
log = [("16:41:58", "info", "Copy started: 74 files, 1.83 GB from myGalaxy"), ("16:41:57", "info", "Released myGalaxy from macOS's camera service"),
       ("16:41:55", "notice", "myGalaxy connected at USB 2 (480 Mb/s); it supports USB 3"),
       ("16:40:12", "warn", "20260903_101512.jpg is no longer on the phone. Needs attention."), ("16:39:44", "info", "Resumed 20260917_081927.mp4 from 256 MB"),
       ("16:39:43", "notice", "Recovered myGalaxy after an interrupted copy"), ("16:39:31", "warn", "myGalaxy disconnected. Copy paused."),
       ("16:37:50", "error", "Destination full: 0 bytes free on External SSD. Paused until space is freed.")]
colors = {"info": "#9FB0B8", "notice": ACC, "warn": "#FFB547", "error": "#FF7A66"}
labels = {"info": "Info", "notice": "Notice", "warn": "Warning", "error": "Error"}
lrows = "".join(f'''<div role="row" style="display: grid; grid-template-columns: 84px 90px minmax(0, 1fr); align-items: center; height: 38px; padding: 0 18px; {"" if i == 0 else "border-top: 1px solid var(--sep);"} font-size: 13px;">
    <span role="cell" style="color: {T2}; {NUM}">{t}</span><span role="cell" style="display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600;"><span aria-hidden="true" style="width: 7px; height: 7px; border-radius: 4px; background: {colors[lv]}; box-shadow: 0 0 6px {colors[lv]};"></span>{labels[lv]}</span><span role="cell">{m}</span></div>''' for i, (t, lv, m) in enumerate(log))
segs = "".join(f'<button aria-pressed="{"true" if i == 0 else "false"}" style="height: 26px; padding: 0 12px; border-radius: 7px; border: none; font-size: 12px; font-weight: 600; cursor: pointer; '
               f'{"background: var(--white-pill); color: var(--white-pill-ink);" if i == 0 else "background: transparent; color: " + T2 + ";"}">{c}</button>' for i, c in enumerate(["All", "Warnings", "Errors"]))
body = f'''<div style="position: absolute; left: 20px; top: 20px;">{traffic_lights()}</div>
<h1 style="margin: 0; position: absolute; left: 0; right: 0; top: 17px; text-align: center; font-size: 13px; font-weight: 600; color: {T2};">Activity</h1>
<div style="position: absolute; left: 28px; right: 28px; top: 56px; display: flex; align-items: center; gap: 10px;">
  <div role="group" aria-label="Filter" style="display: flex; gap: 2px; padding: 3px; border-radius: 10px; background: var(--pill);">{segs}</div>
  <div style="margin-left: auto; display: flex; gap: 10px;">{search_field("Search the log", 200)}{pill("Export Diagnostics…", "export")}</div></div>
<section role="table" aria-label="Activity" style="position: absolute; left: 28px; right: 28px; top: 104px; border-radius: 18px; overflow: hidden; {PANEL}">{lrows}</section>'''
FILES["Log.dc.html"] = (page("Activity log", body, "slate", 900, 460, radius=14), "Activity log")

# ----------------------------------------------------------------------------- 12 · sound design (interactive)
SOUNDS = [("connect", "Phone connected", "A phone appears and is ready.", "Two rising glass notes, bright and short.", "teal", "fold"),
          ("start", "Copy started", "The Copy button turns into the progress ring.", "A soft airy swell into a low tone.", "blue", "arrows"),
          ("pause", "Paused", "The phone was unplugged or locked.", "Two gentle falling notes. Calm, never an alarm.", "amber", "pause"),
          ("resume", "Resumed", "The phone is back and copying continues.", "A quick rising pair, lighter than Connected.", "sky", "play"),
          ("done", "Copy finished", "Relay's signature: every file is safe.", "A four-note arpeggio with a shimmering tail.", "green", "check"),
          ("attention", "Needs attention", "A copy finished with files to review.", "Two soft muted ticks, low and short.", "violet", "alert")]
cards = "".join(f'''<div style="position: relative; overflow: hidden; border-radius: 18px; padding: 16px; display: flex; flex-direction: column; gap: 8px; min-height: 160px; box-sizing: border-box; {PANEL}">
    <div aria-hidden="true" style="position: absolute; right: -16px; top: -18px;">{gem(96, "disc", col, gl)}</div>
    <span style="position: relative; font-size: 15px; font-weight: 600;">{name}</span>
    <span style="position: relative; font-size: 12.5px; line-height: 1.45; color: {T2}; max-width: 170px;">{when}</span>
    <span style="position: relative; font-size: 12.5px; line-height: 1.45; color: {T3}; font-style: italic;">{character}</span>
    <button onClick="{{{{play_{sid}}}}}" aria-label="Play {name}" style="position: relative; margin-top: auto; align-self: flex-start; height: 30px; padding: 0 14px; border-radius: 9px; border: 1px solid rgba(255,255,255,0.35); background: linear-gradient(180deg, {ACC}, #0A6F66); color: #FFFFFF; font-size: 13px; font-weight: 700; display: flex; align-items: center; gap: 6px; cursor: pointer;">{icon("play", 12, "currentColor", 2.4)}Play</button>
  </div>''' for sid, name, when, character, col, gl in SOUNDS)
body = f'''<div style="position: absolute; left: 20px; top: 20px;">{traffic_lights()}</div>
<h1 style="margin: 0; position: absolute; left: 0; right: 0; top: 17px; text-align: center; font-size: 13px; font-weight: 600; color: {T2};">Sound design</h1>
<div style="position: absolute; left: 28px; right: 28px; top: 54px; display: flex; align-items: flex-end; justify-content: space-between; gap: 20px;">
  {para("Short, soft cues that tell you what happened without looking. In Play mode, press Play to hear each one.", 14, T2, 520)}
  <label style="display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; color: {T2};">Volume<input type="range" min="0" max="100" value="{{{{volumePercent}}}}" onChange="{{{{setVolume}}}}" aria-label="Preview volume" style="width: 140px; accent-color: {ACC};"></label></div>
<div style="position: absolute; left: 28px; right: 28px; top: 108px; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px;">{cards}</div>
<p style="margin: 0; position: absolute; left: 28px; right: 28px; bottom: 20px; font-size: 12px; line-height: 1.5; color: {T2};">On by default, with switches in Settings › Sounds. Silent when the Mac's interface sounds are off, during Focus and over full-screen apps. At most one cue per second, never one per file.</p>'''
SOUND_SCRIPT = r"""
  ensureContext() {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    if (!this.ctx) this.ctx = new Ctx();
    if (this.ctx.state === 'suspended') this.ctx.resume();
    return this.ctx;
  }
  play(kind) {
    const ctx = this.ensureContext();
    if (!ctx) return;
    const t0 = ctx.currentTime + 0.03;
    const master = ctx.createGain();
    master.gain.value = 0.22 * ((this.state && this.state.volume !== undefined) ? this.state.volume : 0.7);
    master.connect(ctx.destination);
    const tone = (freq, start, dur, level, type) => {
      [[1, level], [2.005, level * 0.18], [3.01, level * 0.05]].forEach(([mult, gainLevel]) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = type || 'sine';
        osc.frequency.setValueAtTime(freq * mult, t0 + start);
        gain.gain.setValueAtTime(0.0001, t0 + start);
        gain.gain.exponentialRampToValueAtTime(gainLevel, t0 + start + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + start + dur);
        osc.connect(gain);
        gain.connect(master);
        osc.start(t0 + start);
        osc.stop(t0 + start + dur + 0.05);
      });
    };
    const swell = (start, dur) => {
      const length = Math.floor(ctx.sampleRate * dur);
      const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < length; i++) data[i] = Math.random() * 2 - 1;
      const noise = ctx.createBufferSource();
      noise.buffer = buffer;
      const band = ctx.createBiquadFilter();
      band.type = 'bandpass';
      band.Q.value = 1.2;
      band.frequency.setValueAtTime(350, t0 + start);
      band.frequency.exponentialRampToValueAtTime(2600, t0 + start + dur);
      const gain = ctx.createGain();
      gain.gain.setValueAtTime(0.0001, t0 + start);
      gain.gain.exponentialRampToValueAtTime(0.35, t0 + start + dur * 0.6);
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + start + dur);
      noise.connect(band);
      band.connect(gain);
      gain.connect(master);
      noise.start(t0 + start);
    };
    if (kind === 'connect') { tone(784, 0, 0.45, 0.5); tone(1175, 0.09, 0.6, 0.45); }
    if (kind === 'start') { swell(0, 0.42); tone(392, 0.28, 0.5, 0.3); }
    if (kind === 'pause') { tone(659, 0, 0.5, 0.35); tone(494, 0.14, 0.7, 0.32); }
    if (kind === 'resume') { tone(494, 0, 0.3, 0.3); tone(740, 0.08, 0.45, 0.34); }
    if (kind === 'done') { tone(523, 0, 0.9, 0.36); tone(659, 0.08, 0.9, 0.34); tone(784, 0.16, 1.0, 0.34); tone(1047, 0.27, 1.5, 0.32); tone(2093, 0.42, 1.2, 0.05, 'triangle'); }
    if (kind === 'attention') { tone(330, 0, 0.12, 0.45, 'triangle'); tone(330, 0.15, 0.12, 0.4, 'triangle'); }
  }
"""
vals = """
      volumePercent: Math.round(((this.state && this.state.volume !== undefined) ? this.state.volume : 0.7) * 100),
      setVolume: (event) => this.setState({ volume: Number(event.target.value) / 100 }),""" + "".join(
    f"\n      play_{sid}: () => this.play('{sid}')," for sid, *_ in SOUNDS)
FILES["Sounds.dc.html"] = (page("Sound design", body, "history", 900, 520, script_extra=SOUND_SCRIPT, vals=vals, radius=14), "Sound design (Play to hear)")

# Pass 5: the new features (their boards live in features.py).
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "features.py")).read())

# ----------------------------------------------------------------------------- canvas
existing = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
sections = [
    ("0 · Introduction (first launch only)", ["Intro1.dc.html", "Intro2.dc.html", "Intro3.dc.html"]),
    ("1 · Connect", ["Main.dc.html", "Overview.dc.html", "Guide.dc.html", "Busy.dc.html"]),
    ("2 · Choose, copy, pause, done, history", ["Browse.dc.html", "Copying.dc.html", "Paused.dc.html", "Done.dc.html", "History.dc.html"]),
    ("3 · Menu bar, settings, activity", ["MenuBar.dc.html", "Settings.dc.html", "SettingsSounds.dc.html", "SettingsAdvanced.dc.html", "Log.dc.html"]),
    ("4 · Sound", ["Sounds.dc.html"]),
    ("5 · Browse: previews, Quick Look, duplicates, Mac → phone, app media", ["QuickLook.dc.html", "Duplicates.dc.html", "Upload.dc.html", "Messaging.dc.html"]),
    ("6 · Storage map and freeing up space", ["StorageMap.dc.html", "FreeUpVerify.dc.html", "FreeUpConfirm.dc.html", "FreeUpDone.dc.html"]),
    ("7 · Notifications, widgets, Shortcuts, organising", ["Desktop.dc.html", "SettingsOrganise.dc.html"]),
]
boards, order, notes = {}, [], {}
y = 0
widest = 0
for index, (heading, names) in enumerate(sections):
    notes[f"row{index + 1}"] = {"x": 0, "y": y - 300, "text": heading, "kind": "title1", "maxW": 6000}
    tallest = max(FILES[n][0]["h"] for n in names)
    themes = ["dark"] if heading in ("4 · Sound", "0 · Introduction (first launch only)") else ["dark", "light"]
    for t_index, theme in enumerate(themes):
        row_y = y + t_index * (tallest + 160)
        notes[f"row{index + 1}-{theme}"] = {"x": -440, "y": row_y, "w": 360, "text": theme.capitalize(), "size": "xl", "bold": True,
                                            "fill": "gray" if theme == "dark" else "blue"}
        x = 0
        for name in names:
            spec, title = FILES[name]
            file_name = name if theme == "dark" else name.replace(".dc.html", "Light.dc.html")
            board = {"x": x, "y": row_y, "w": spec["w"], "h": spec["h"], "title": f"{title} · {theme}" if len(themes) > 1 else title, "radius": spec["radius"]}
            if name == "Sounds.dc.html":
                board["is_interactive"] = True
            boards[file_name] = board
            order.append(file_name)
            with open(os.path.join(ROOT, file_name), "w") as f:
                f.write(render_page(spec, theme))
            x += spec["w"] + 80
        widest = max(widest, x)
    y += len(themes) * (tallest + 160) - 160 + 420

note_x = widest + 40
notes["intro"] = {"x": note_x, "y": 0, "w": 460, "size": "m", "fill": "teal",
                  "text": "Relay, design pass 4: immersive, in the spirit of CleanMyMac.\n\n• Each section has its own colour scene: teal for the phone, blue while copying, amber when paused, green when done, violet for history.\n• A labelled sidebar on the welcome screen; everywhere else it folds into an icon rail with live status (a pie on Copies, a dot on Needs attention).\n• Big glossy artwork (Relay's own), frosted glass panels and result cards, and one round glowing action button.\n• Cable advice: the phone screen has a cable card (USB 2 now, 3× faster with USB 3, time saved); Choose, Copying and the menu bar repeat it in one line.\n\nEvery screen in dark (top row) and light (row below); Theme and accent switches in Tweaks."}
notes["motion"] = {"x": note_x, "y": 2200, "w": 460, "size": "m", "fill": "blue",
                   "text": "Motion (SwiftUI):\n• The scene colour cross-fades between sections (teal → blue → green).\n• The round Copy button morphs into the progress ring around the phone.\n• Numbers animate; files tick off one by one.\n• Unplugging turns the scene amber and the phone's cable drops away.\n• The artwork floats gently (a few points, slow).\n• Reduce Motion: cross-fades only. Reduce Transparency: solid panels."}
notes["sound"] = {"x": 980, "y": notes["row5-dark"]["y"], "w": 420, "size": "m", "fill": "purple",
                  "text": "Sound: open the board in Play mode and press Play on each card. Synthesised live here; the app ships the same recipes rendered to short audio files, so there is nothing licensed."}
notes["font"] = {"x": note_x, "y": 4000, "w": 460, "size": "m", "fill": "gray",
                 "text": "Type: Plus Jakarta Sans (SIL Open Font License), bundled with the app. The introduction always plays in the dark teal scene, once, on first launch."}

notes["features"] = {"x": note_x, "y": notes["row6"]["y"] + 300, "w": 460, "size": "m", "fill": "purple",
                     "text": "Pass 5, new features:\n\u2022 Previews: the phone's own thumbnails (MTP GetThumb, ~40 ms each); Finder icons for other files; drag, \u2318- and \u21e7-click selection; Space opens Quick Look.\n\u2022 Duplicates: files already on the Mac (by content, any name) are marked and left unticked.\n\u2022 Mac \u2192 phone: drop files on a folder, or Add from Mac.\n\u2022 App media: WhatsApp, Telegram and Instagram folders as cards.\n\u2022 Storage map: what fills the phone, as tiles; copy any tile.\n\u2022 Free up space: check every copy against the phone byte for byte, then a clear confirmation, then a summary. The only feature that deletes.\n\u2022 Notifications, desktop widgets, Shortcuts actions, and copies organised by year and month."}

canvas = dict(existing)
canvas.update({"v": 3, "title": existing.get("title", "Relay — App Design"), "launch": existing.get("launch", {"view": "canvas"}),
               "boards": boards, "order": order, "notes": notes})
canvas.setdefault("createdOnFiles", {"v": 1, "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
canvas.setdefault("pages", [])
with open(os.path.join(ROOT, "canvas.json"), "w") as f:
    json.dump(canvas, f, indent=1, ensure_ascii=False)
print("wrote", len(boards), "boards")
