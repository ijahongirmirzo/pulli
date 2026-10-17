# Relay design canvas, pass 5: the new features (owner request, 2026-09-27).
# Loaded by generate.py (exec), so every helper there (window, gem, pill, card, ...) is in scope.
import random


def photo(seed, w, h, radius=8, video=False):
    """A stand-in photo (gradient sky, sun, hills) for previews."""
    rng = random.Random(seed)
    u = uid("ph")
    skies = [("#FFB36B", "#6B7BFF"), ("#7FE3D6", "#1B5F8C"), ("#FFD27A", "#E0567A"), ("#9FD1FF", "#3A6FD8"), ("#C7F0B8", "#2E8B6B"), ("#FFC4D6", "#7B5CFF")]
    top, bottom = skies[seed % len(skies)]
    sun_x = rng.randint(20, 70)
    hills = f"0,{h} 0,{h * 0.62:.0f} {w * 0.3:.0f},{h * 0.45:.0f} {w * 0.62:.0f},{h * 0.66:.0f} {w},{h * 0.5:.0f} {w},{h}"
    small = min(w, h)
    play = ""
    if video:
        play = (f'<circle cx="{w / 2}" cy="{h / 2}" r="{small * 0.18:.1f}" fill="#000000" opacity="0.45"></circle>'
                f'<path d="M{w / 2 - small * 0.06:.1f} {h / 2 - small * 0.09:.1f} L{w / 2 + small * 0.1:.1f} {h / 2} L{w / 2 - small * 0.06:.1f} {h / 2 + small * 0.09:.1f}z" fill="#FFFFFF"></path>')
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" aria-hidden="true" style="display: block; border-radius: {radius}px; flex-shrink: 0;">'
            f'<defs><linearGradient id="{u}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"></stop><stop offset="1" stop-color="{bottom}"></stop></linearGradient>'
            f'<clipPath id="{u}c"><rect width="{w}" height="{h}" rx="{radius}"></rect></clipPath></defs>'
            f'<g clip-path="url(#{u}c)"><rect width="{w}" height="{h}" fill="url(#{u})"></rect>'
            f'<circle cx="{w * sun_x / 100:.0f}" cy="{h * 0.3:.0f}" r="{small * 0.12:.1f}" fill="#FFF5DA" opacity="0.9"></circle>'
            f'<polygon points="{hills}" fill="#0E2A22" opacity="0.55"></polygon>{play}</g>'
            f'<rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="{radius}" fill="none" stroke="#FFFFFF" stroke-opacity="0.35"></rect></svg>')


def list_row(icon_html, name, date, kind, size, state="off", badge_html="", first=False, focus=False):
    stripe = "background: var(--pill);" if state == "on" else ""
    ring = f'<span style="position: absolute; left: 4px; top: 12px; width: 3px; height: 22px; border-radius: 2px; background: {ACC};"></span>' if focus else ""
    border = "" if first else "border-top: 1px solid var(--sep);"
    return (f'<div role="row" style="position: relative; display: grid; grid-template-columns: minmax(0, 1fr) 150px 80px 80px; align-items: center; height: 46px; '
            f'padding: 0 18px; {border} font-size: 13.5px; {stripe} {NUM}">{ring}'
            f'<span role="cell" style="display: flex; align-items: center; gap: 10px; min-width: 0;">{checkbox(state, name)}{icon_html}'
            f'<span style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">{name}</span>{badge_html}</span>'
            f'<span role="cell" style="color: {T2};">{date}</span><span role="cell" style="color: {T2};">{kind}</span>'
            f'<span role="cell" style="color: {T2}; text-align: right;">{size}</span></div>')


def list_header():
    return (f'<div role="row" style="display: grid; grid-template-columns: minmax(0, 1fr) 150px 80px 80px; height: 30px; align-items: center; padding: 0 18px; '
            f'font-size: 12px; font-weight: 600; color: {T3}; border-top: 1px solid var(--sep); border-bottom: 1px solid var(--sep);">'
            f'<span style="padding-left: 68px;">Name</span><span style="color: {T1};">Date Modified ⌄</span><span>Kind</span><span style="text-align: right;">Size</span></div>')


def path_bar(parts, right=""):
    crumbs = f'<span style="display: flex; color: {T1};">{icon("fold", 15)}</span>myGalaxy'
    for index, part in enumerate(parts):
        style = f"color: {T1}; font-weight: 600;" if index == len(parts) - 1 else ""
        crumbs += f'{icon("chevron", 12, T3, 2)}<span style="{style}">{part}</span>'
    return (f'<div style="height: 48px; display: flex; align-items: center; gap: 7px; padding: 0 18px; font-size: 13.5px; color: {T2};">'
            f'{crumbs}<span style="margin-left: auto; display: flex; gap: 6px;">{right}</span></div>')


def list_panel(inner, bottom=150):
    return f'<section style="position: absolute; left: 32px; right: 32px; top: 16px; bottom: {bottom}px; border-radius: 22px; overflow: hidden; {PANEL}">{inner}</section>'


def footer_text(big, small):
    return (f'<div style="position: absolute; left: 40px; bottom: 58px; display: flex; flex-direction: column; gap: 3px; {NUM}">'
            f'<span style="font-size: 15px; font-weight: 600;">{big}</span><span style="font-size: 13px; color: {T2};">{small}</span></div>')


camera_rows = [("20260917_081927.mp4", "17 Sep 2026, 08:20", "Video", "385.4 MB", True), ("20260917_081544.jpg", "17 Sep 2026, 08:15", "Photo", "4.1 MB", False),
               ("20260917_081540.jpg", "17 Sep 2026, 08:15", "Photo", "3.8 MB", False), ("20260916_193002.mp4", "16 Sep 2026, 19:30", "Video", "96.2 MB", True),
               ("20260916_161059.jpg", "16 Sep 2026, 16:11", "Photo", "4.2 MB", False), ("20260916_161031.jpg", "16 Sep 2026, 16:10", "Photo", "3.9 MB", False),
               ("20260915_120000.jpg", "15 Sep 2026, 12:00", "Photo", "4.0 MB", False), ("20260914_094242.jpg", "14 Sep 2026, 09:42", "Photo", "4.4 MB", False)]

# ---------------------------------------------------------------- previews, multi-select, Quick Look
rows_html = "".join(list_row(photo(i + 3, 34, 34, 7, video=v), n, d, k, sz, state="on" if i in (1, 2, 3) else "off", first=i == 0, focus=i == 3)
                    for i, (n, d, k, sz, v) in enumerate(camera_rows))
quicklook = (f'<div style="position: absolute; left: 330px; top: 70px; width: 560px; border-radius: 14px; overflow: hidden; background: rgba(30,30,32,0.92); '
             f'border: 1px solid rgba(255,255,255,0.14); box-shadow: 0 30px 80px rgba(0,0,0,0.5); color: #FFFFFF;">'
             f'<div style="height: 38px; display: flex; align-items: center; gap: 8px; padding: 0 12px; font-size: 13px; font-weight: 600; border-bottom: 1px solid rgba(255,255,255,0.1);">'
             f'{traffic_lights()}<span style="margin-left: 10px;">20260916_193002.mp4</span><span style="margin-left: auto; font-size: 11.5px; font-weight: 500; color: rgba(255,255,255,0.6);">Quick Look</span></div>'
             f'<div style="position: relative;">{photo(4, 560, 330, 0, video=True)}'
             f'<div style="position: absolute; left: 16px; bottom: 14px; font-size: 12px; padding: 4px 10px; border-radius: 999px; background: rgba(0,0,0,0.5);">'
             f'Loading the full video · 38 of 96 MB · 2 s</div></div></div>')
content = (list_panel(path_bar(["Internal storage", "DCIM", "Camera"], pill("Select All", small=True) + pill("Clear", small=True)) + list_header() + rows_html)
           + footer_text("3 files · 104 MB · about 4 s", "Drag across rows to tick many · ⌘-click · ⇧-click a range · Space to preview")
           + round_button("Copy") + quicklook)
FILES["QuickLook.dc.html"] = (page("Previews and Quick Look", window("Camera", content, selected="phone", back="myGalaxy", right=search_field("Search Camera", 190)), "home"),
                              "Previews, multi-select, Quick Look")

# ---------------------------------------------------------------- duplicate finder
on_mac = '<span style="margin-left: 6px; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; color: var(--green); background: var(--green-bg); white-space: nowrap;">On your Mac</span>'
rows_html = "".join(list_row(photo(i + 11, 34, 34, 7, video=v), n, d, k, sz, state="off" if i < 5 else "on", badge_html=on_mac if i < 5 else "", first=i == 0)
                    for i, (n, d, k, sz, v) in enumerate(camera_rows))
banner = (f'<div style="display: flex; align-items: center; gap: 14px; padding: 12px 16px; border-top: 1px solid var(--sep); background: var(--green-bg);">'
          f'{gem(40, "disc", "green", "copies")}<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1;">'
          f'<span style="font-size: 14px; font-weight: 600;">41 of 74 are already on your Mac</span>'
          f'<span style="font-size: 12.5px; color: {T2};">Found by content in Pictures, even under other names (IMG_4411.jpg = 20260917_081544.jpg). They are left unticked.</span></div>'
          f'{pill("Show Matches", small=True)}{pill("Tick Them Anyway", small=True)}</div>')
content = (list_panel(path_bar(["Internal storage", "DCIM", "Camera"]) + banner + list_header() + rows_html)
           + footer_text("33 new files · 812 MB · about 27 s", "Already on your Mac and skipped: 41 files · 1.02 GB") + round_button("Copy"))
FILES["Duplicates.dc.html"] = (page("Duplicate finder", window("Camera", content, selected="phone", back="myGalaxy"), "home"), "Duplicate finder")

# ---------------------------------------------------------------- Mac to phone
rows_html = "".join(list_row(photo(i + 21, 34, 34, 7, video=v), n, d, k, sz, first=i == 0) for i, (n, d, k, sz, v) in enumerate(camera_rows[:6]))
drop = (f'<div style="position: absolute; left: 14px; right: 14px; top: 94px; bottom: 14px; border-radius: 18px; border: 2.5px dashed {ACC}; background: rgba(60,207,190,0.16); '
        f'display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px;">'
        f'{gem(96, "squircle", "teal", "upload", tilt=-6)}<span style="font-size: 22px; font-weight: 600;">Drop to copy to Camera on myGalaxy</span>'
        f'<span style="font-size: 13.5px; color: {T2};">3 items from your Mac · 212 MB · about 8 s</span></div>')
upload = (f'<div style="position: absolute; right: 40px; bottom: 36px; width: 360px; padding: 14px 16px; border-radius: 16px; display: flex; flex-direction: column; gap: 8px; {PANEL}">'
          f'<div style="display: flex; align-items: center; gap: 10px;">{gem(34, "squircle", "teal", "upload")}<span style="display: flex; flex-direction: column;">'
          f'<span style="font-size: 13.5px; font-weight: 600;">Copying to myGalaxy</span><span style="font-size: 12px; color: {T2};">Holiday.mov → DCIM › Camera</span></span></div>'
          f'<div style="height: 7px; border-radius: 4px; background: var(--track);"><div style="width: 58%; height: 7px; border-radius: 4px; background: {ACC};"></div></div>'
          f'<div style="display: flex; justify-content: space-between; font-size: 12px; color: {T2}; {NUM}"><span>2 of 3 · 123 of 212 MB</span><span>4 s left</span></div></div>')
content = list_panel(path_bar(["Internal storage", "DCIM", "Camera"], pill("Add from Mac…", "upload", small=True)) + list_header() + rows_html + drop) + upload
FILES["Upload.dc.html"] = (page("Copy from Mac to phone", window("Camera", content, selected="phone", back="myGalaxy"), "home"), "Mac → phone (drag and drop)")

# ---------------------------------------------------------------- messaging-app media
cards_row1 = (card("New since last copy", "74 items", "1.8 GB to copy", gem(150, "squircle", "teal", "sparkle", tilt=-10), "on")
              + card("Camera", "1,284 photos", "and videos · 42.8 GB", gem(150, "disc", "blue", "lens"), "off")
              + card("Screenshots", "212 images", "212 MB", gem(150, "hex", "violet", "screens"), "off"))
cards_row2 = (card("WhatsApp media", "3,412 files", "photos, videos, voice notes · 18.2 GB", gem(150, "disc", "green", "chat"), "off")
              + card("Telegram", "860 files", "downloads and media · 6.1 GB", gem(150, "disc", "sky", "chat"), "off")
              + card("Instagram", "214 files", "saved photos and reels · 1.3 GB", gem(150, "squircle", "pink", "image", tilt=6), "off"))
content = (f'<div style="position: absolute; left: 32px; right: 32px; top: 18px; text-align: center;">{headline("myGalaxy is ready. Here&#39;s what&#39;s on it:", 27, 500)}</div>'
           f'<div style="position: absolute; left: 32px; right: 32px; top: 80px; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; height: 172px;">{cards_row1}</div>'
           f'<div style="position: absolute; left: 34px; top: 266px; font-size: 12px; font-weight: 700; letter-spacing: 0.06em; color: {T3};">FROM YOUR APPS</div>'
           f'<div style="position: absolute; left: 32px; right: 32px; top: 288px; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; height: 172px;">{cards_row2}</div>'
           f'<div style="position: absolute; left: 0; right: 0; top: 488px; text-align: center; font-size: 14px; color: {T2}; {NUM}">Selected: <strong style="color: {T1};">74 items · 1.8 GB · about 1 min</strong>'
           f' to Pictures › From myGalaxy › <strong style="color: {T1};">2026 › 09</strong></div>' + round_button("Copy"))
FILES["Messaging.dc.html"] = (page("Media from messaging apps", window("myGalaxy", content, selected="phone", right=pill("Storage Map", "map") + pill("Browse Phone…", "folder")), "home"),
                              "Messaging-app media cards")

# ---------------------------------------------------------------- storage map
tiles = [("Camera", "42.8 GB", 0, 0, 44, 58, "blue", "lens"), ("WhatsApp", "18.2 GB", 44, 0, 30, 58, "green", "chat"), ("Movies", "12.4 GB", 74, 0, 26, 34, "violet", "video"),
         ("Android data", "9.1 GB", 74, 34, 26, 24, "slate", "layers"), ("Telegram", "6.1 GB", 0, 58, 26, 42, "sky", "chat"), ("Download", "1.8 GB", 26, 58, 18, 42, "amber", "download"),
         ("Music", "3.4 GB", 44, 58, 20, 42, "pink", "speaker"), ("Other", "2.6 GB", 64, 58, 36, 42, "teal", "folder")]
tile_colors = {"blue": ("#5AA2FF", "#1B3FA8"), "green": ("#63D98A", "#0D6B2E"), "violet": ("#A58BFF", "#4424A8"), "slate": ("#A9B7C4", "#42505C"),
               "sky": ("#6FD0F5", "#135D93"), "amber": ("#FFC46B", "#A8540C"), "pink": ("#FF8FB8", "#9C1F5C"), "teal": ("#6FF0DF", "#0A6F6C")}
tile_html = ""
for name, size, x, y, w, h, color, glyph_name in tiles:
    light, deep = tile_colors[color]
    outline = "outline: 3px solid #FFFFFF; outline-offset: -3px;" if name == "WhatsApp" else ""
    tile_html += (f'<div style="position: absolute; left: calc({x}% + 3px); top: calc({y}% + 3px); width: calc({w}% - 6px); height: calc({h}% - 6px); border-radius: 14px; '
                  f'background: linear-gradient(145deg, {light}, {deep}); box-shadow: inset 0 1px 0 rgba(255,255,255,0.4), 0 6px 18px rgba(0,0,0,0.25); color: #FFFFFF; '
                  f'padding: 14px; box-sizing: border-box; display: flex; flex-direction: column; justify-content: space-between; {outline}">'
                  f'<span style="display: flex; align-items: center; gap: 7px; font-size: 14px; font-weight: 700;">{icon(glyph_name, 16, "#FFFFFF", 2)}{name}</span>'
                  f'<span style="font-size: {22 if w * h > 1200 else 15}px; font-weight: 700; {NUM}">{size}</span></div>')
side = (f'<aside style="width: 270px; flex-shrink: 0; display: flex; flex-direction: column; gap: 12px;">'
        f'<div style="padding: 16px; border-radius: 18px; display: flex; flex-direction: column; gap: 10px; {PANEL}">'
        f'<span style="font-size: 12px; font-weight: 700; letter-spacing: 0.06em; color: {T3};">SELECTED</span>'
        f'<div style="display: flex; align-items: center; gap: 10px;">{gem(44, "disc", "green", "chat")}<span style="display: flex; flex-direction: column;">'
        f'<span style="font-size: 16px; font-weight: 700;">WhatsApp</span><span style="font-size: 12.5px; color: {T2};">Android › media › com.whatsapp</span></span></div>'
        f'<div style="font-size: 26px; font-weight: 700; {NUM}">18.2 GB</div>'
        f'<div style="display: flex; flex-direction: column; gap: 6px; font-size: 12.5px; color: {T2}; {NUM}"><span>Video · 12.1 GB</span><span>Images · 4.6 GB</span>'
        f'<span>Voice notes · 0.9 GB</span><span>Documents · 0.6 GB</span></div>'
        f'<div style="display: flex; gap: 8px;">{pill("Copy to Mac", "arrows", kind="accent", small=True)}{pill("Open", small=True)}</div></div>'
        f'<div style="padding: 14px 16px; border-radius: 18px; display: flex; flex-direction: column; gap: 6px; {PANEL}">'
        f'<span style="font-size: 13.5px; font-weight: 600;">Phone storage</span>'
        f'<div style="height: 8px; border-radius: 4px; background: var(--track);"><div style="width: 82%; height: 8px; border-radius: 4px; background: linear-gradient(90deg, #5AA2FF, #63D98A, #A58BFF);"></div></div>'
        f'<span style="font-size: 12.5px; color: {T2}; {NUM}">192.3 GB used · 42.6 GB free</span></div></aside>')
content = (f'<div style="position: absolute; left: 32px; right: 32px; top: 16px; bottom: 32px; display: flex; gap: 18px;">'
           f'<div style="flex-grow: 1; display: flex; flex-direction: column; gap: 12px;">'
           f'<div style="display: flex; align-items: baseline; justify-content: space-between;">{headline("What&#39;s filling myGalaxy", 26, 500)}'
           f'<span style="font-size: 13px; color: {T2};">48,210 files · click a tile to look inside</span></div>'
           f'<div style="position: relative; flex-grow: 1; margin: -3px;">{tile_html}</div></div>{side}</div>')
FILES["StorageMap.dc.html"] = (page("Phone storage map", window("Storage Map", content, selected="phone", back="myGalaxy"), "history"), "Phone storage map")

# ---------------------------------------------------------------- free up space: check, confirm, summary
checks = [("20260917_081544.jpg", "4.1 MB", False, "✓ Identical", "var(--green)"), ("20260916_193002.mp4", "96.2 MB", True, "✓ Identical", "var(--green)"),
          ("20260917_081927.mp4", "385.4 MB", True, "Checking… 41%", T1), ("20260918_212923.jpg", "5.2 MB", False, "Waiting", T3)]
check_rows = "".join(
    f'<li style="display: flex; align-items: center; gap: 12px; height: 44px; {"" if i == 0 else "border-top: 1px solid var(--sep);"}">{photo(i + 31, 32, 32, 7, video=v)}'
    f'<span style="font-size: 14px; font-weight: 500; flex-grow: 1; {NUM}">{n}</span><span style="font-size: 13px; color: {T2}; {NUM}">{sz}</span>'
    f'<span style="width: 110px; text-align: right; font-size: 12.5px; font-weight: 600; color: {c};">{st}</span></li>' for i, (n, sz, v, st, c) in enumerate(checks))
content = (f'<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL} display: flex; align-items: center; gap: 34px; padding: 0 44px 0 30px;">'
           f'{hero_ring(58, "#B17BFF", gem(190, "disc", "violet", "shield"))}'
           f'<div style="flex-grow: 1; display: flex; flex-direction: column; gap: 14px;">{headline("Checking copies before freeing space…", 28, 400)}'
           f'{para("Relay reads each file again from the phone and compares it with the copy on your Mac, byte for byte. Nothing is deleted yet.", 14.5, T2, 480)}'
           f'<div style="display: flex; gap: 8px;">{chip("42 of 72 identical")}{chip("1.02 of 1.79 GB")}{chip("26 s left")}</div>'
           f'<ul style="list-style: none; margin: 0; padding: 0;">{check_rows}</ul>'
           f'<div style="display: flex; justify-content: flex-end;">{pill("Stop Checking")}</div></div></section>')
FILES["FreeUpVerify.dc.html"] = (page("Free up space: checking", window("Free Up Space", content, selected="copies"), "history"), "Free up space · 1 check")

summary_rows = [("shield", "var(--green)", "Checked and identical on your Mac", "72 files · 1.79 GB"),
                ("alert", "var(--amber)", "Kept on the phone (not copied, or not identical)", "2 files"),
                ("folder", T2, "Your copies stay in", "Pictures › From myGalaxy")]
summary_html = "".join(
    f'<li style="display: flex; justify-content: space-between; gap: 12px; padding: 11px 14px; font-size: 13.5px; {"" if i == 0 else "border-top: 1px solid var(--sep);"}">'
    f'<span style="display: flex; gap: 8px; align-items: center;">{icon(g, 16, c, 2)}{label}</span><strong>{value}</strong></li>' for i, (g, c, label, value) in enumerate(summary_rows))
delete_button = ('<button style="height: 32px; padding: 0 16px; border-radius: 9px; border: none; background: #E5484D; color: #FFFFFF; font-size: 13px; font-weight: 700;">'
                 'Delete 72 Files from Phone</button>')
sheet = (f'<div style="position: absolute; left: 50%; top: 60px; width: 580px; margin-left: -290px; border-radius: 22px; padding: 26px; box-sizing: border-box; display: flex; flex-direction: column; gap: 16px; '
         f'background: var(--sheet); border: 1px solid var(--panel-border); box-shadow: 0 30px 90px rgba(0,0,0,0.45);">'
         f'<div style="display: flex; align-items: center; gap: 14px;">{gem(64, "disc", "amber", "trash")}<div style="display: flex; flex-direction: column; gap: 3px;">'
         f'<span style="font-size: 22px; font-weight: 700;">Delete 72 originals from myGalaxy?</span><span style="font-size: 13.5px; color: {T2};">This frees 1.79 GB on the phone.</span></div></div>'
         f'<ul style="list-style: none; margin: 0; padding: 0; border-radius: 14px; overflow: hidden; border: 1px solid var(--sep); {NUM}">{summary_html}</ul>'
         f'<label style="display: flex; gap: 10px; align-items: flex-start; font-size: 13.5px; line-height: 1.45;">{checkbox("on", "I understand")}'
         f'<span>I understand the originals are removed from the phone. Relay cannot undo this.</span></label>'
         f'<div style="display: flex; justify-content: flex-end; gap: 10px;">{pill("Cancel")}{delete_button}</div></div>')
content = f'<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; opacity: 0.5; {PANEL}"></section>{sheet}'
FILES["FreeUpConfirm.dc.html"] = (page("Free up space: confirm", window("Free Up Space", content, selected="copies"), "history"), "Free up space · 2 confirm")

content = (f'<section style="position: absolute; left: 40px; right: 40px; top: 24px; bottom: 40px; border-radius: 26px; {PANEL}">'
           f'<div style="position: absolute; left: -34px; top: 76px;">{gem(330, "disc", "violet", "check", face=True)}</div>'
           f'<div style="position: absolute; left: 380px; right: 40px; top: 96px; display: flex; flex-direction: column; gap: 22px;">{headline("1.79 GB freed on myGalaxy", 34, 500)}'
           f'<ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 16px;">'
           f'{result_row(gem(46, "disc", "violet", "trash"), "72 originals deleted", "each one checked against its copy on your Mac first")}'
           f'{result_row(gem(46, "disc", "green", "folder"), "Your copies are safe", "in Pictures › From myGalaxy", "Show in Finder")}'
           f'{result_row(gem(46, "disc", "amber", "alert"), "2 files kept on the phone", "they were not copied, or did not match", "Review")}</ul>'
           f'<span style="font-size: 13px; color: {T3}; {NUM}">Phone storage: 150.9 GB used · 84.0 GB free</span></div>'
           f'<div style="position: absolute; right: 24px; bottom: 20px;">{pill("Done", kind="white")}</div></section>')
FILES["FreeUpDone.dc.html"] = (page("Free up space: done", window("Free Up Space", content, selected="copies"), "history"), "Free up space · 3 summary")


# ---------------------------------------------------------------- notifications, widgets, Shortcuts
def notification(title, body, when="now"):
    return (f'<div style="width: 380px; padding: 12px 14px; border-radius: 18px; box-sizing: border-box; display: flex; gap: 12px; background: rgba(40,40,44,0.78); '
            f'border: 1px solid rgba(255,255,255,0.14); box-shadow: 0 12px 40px rgba(0,0,0,0.35); color: #FFFFFF;">'
            f'{gem(38, "squircle", "teal", "arrows")}<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0;">'
            f'<div style="display: flex; justify-content: space-between; font-size: 13px;"><strong>{title}</strong><span style="color: rgba(255,255,255,0.55); font-size: 12px;">{when}</span></div>'
            f'<span style="font-size: 13px; color: rgba(255,255,255,0.8); line-height: 1.35;">{body}</span></div></div>')


def widget_bar(name, what, pct, right, color):
    return (f'<div style="display: flex; flex-direction: column; gap: 5px;"><div style="display: flex; justify-content: space-between; font-size: 12px;">'
            f'<strong>{name} · {what}</strong><span style="color: rgba(255,255,255,0.7);">{right}</span></div>'
            f'<div style="height: 6px; border-radius: 3px; background: rgba(255,255,255,0.18);"><div style="width: {pct}%; height: 6px; border-radius: 3px; background: {color};"></div></div></div>')


widget_bg = "background: linear-gradient(145deg, #0A4A5C, #0C2C62); color: #FFFFFF; box-shadow: 0 16px 40px rgba(0,0,0,0.35);"
widget_small = (f'<div style="width: 170px; height: 170px; border-radius: 26px; padding: 16px; box-sizing: border-box; display: flex; flex-direction: column; justify-content: space-between; {widget_bg}">'
                f'<div style="display: flex; justify-content: space-between; align-items: center;"><span style="font-size: 12px; font-weight: 700; color: rgba(255,255,255,0.75);">RELAY</span>{icon("arrows", 14, "#7FE3D6", 2.2)}</div>'
                f'<div style="position: relative; width: 74px; height: 74px;"><svg width="74" height="74" viewBox="0 0 74 74"><circle cx="37" cy="37" r="31" fill="none" stroke="#FFFFFF" stroke-opacity="0.18" stroke-width="8"></circle>'
                f'<circle cx="37" cy="37" r="31" fill="none" stroke="#3CCFBE" stroke-width="8" stroke-linecap="round" stroke-dasharray="120.8 194.8" transform="rotate(-90 37 37)"></circle></svg>'
                f'<span style="position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; font-size: 18px; font-weight: 700;">62%</span></div>'
                f'<div style="display: flex; flex-direction: column;"><span style="font-size: 13px; font-weight: 700;">myGalaxy</span><span style="font-size: 11.5px; color: rgba(255,255,255,0.7);">Camera · 23 s left</span></div></div>')
widget_medium = (f'<div style="width: 360px; height: 170px; border-radius: 26px; padding: 16px 18px; box-sizing: border-box; display: flex; flex-direction: column; gap: 12px; {widget_bg}">'
                 f'<div style="display: flex; justify-content: space-between; align-items: center;"><span style="font-size: 12px; font-weight: 700; color: rgba(255,255,255,0.75);">RELAY · 2 COPYING</span>'
                 f'<span style="font-size: 11.5px; color: #FFC873;">USB 2 · 3× faster with USB 3</span></div>'
                 f'{widget_bar("myGalaxy", "Camera", 62, "23 s left", "#3CCFBE")}{widget_bar("myGalaxy", "Movies", 8, "next", "rgba(255,255,255,0.5)")}{widget_bar("Pixel 8 Pro", "DCIM", 36, "paused", "#FFB547")}</div>')
steps = [("fold", "Get Phone", "myGalaxy"), ("sparkle", "Copy New Photos", "from the phone to Pictures › From myGalaxy"), ("bell", "Show Notification", "Backup done")]
shortcut_steps = "".join(
    f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 10px; background: #FFFFFF; box-shadow: 0 1px 3px rgba(0,0,0,0.1); font-size: 13px;">'
    f'{gem(26, "squircle", "teal", g)}<span><strong>{a}</strong> {b}</span></div>' for g, a, b in steps)
shortcuts = (f'<div style="position: absolute; left: 40px; bottom: 40px; width: 540px; border-radius: 16px; overflow: hidden; background: rgba(250,250,252,0.95); color: #1D1D1F; box-shadow: 0 20px 60px rgba(0,0,0,0.35);">'
             f'<div style="height: 36px; display: flex; align-items: center; gap: 10px; padding: 0 12px; border-bottom: 1px solid rgba(0,0,0,0.08); font-size: 13px; font-weight: 600;">'
             f'{traffic_lights()}<span style="margin-left: 8px;">Shortcuts · Back up my phone</span></div>'
             f'<div style="padding: 14px; display: flex; flex-direction: column; gap: 8px;">{shortcut_steps}</div></div>')
desktop = (f'<div style="position: absolute; inset: 0; background: linear-gradient(160deg, #F2A07B 0%, #B45EA8 45%, #3B3F9E 100%);"></div>'
           f'<div style="position: absolute; left: 40px; top: 40px; display: flex; flex-direction: column; gap: 14px;">'
           f'<span style="font-size: 13px; font-weight: 700; color: rgba(255,255,255,0.9);">Desktop widgets</span><div style="display: flex; gap: 18px;">{widget_small}{widget_medium}</div></div>'
           f'<div style="position: absolute; right: 24px; top: 24px; display: flex; flex-direction: column; gap: 10px;">'
           f'<span style="font-size: 13px; font-weight: 700; color: rgba(255,255,255,0.9); text-align: right;">Notifications</span>'
           f'{notification("Copy finished", "72 files · 1.79 GB from myGalaxy are on your Mac. 2 need attention.")}'
           f'{notification("myGalaxy connected", "74 new photos and videos since your last copy.", "2 min ago")}'
           f'{notification("Copy paused", "Reconnect myGalaxy to continue. Nothing is lost.", "5 min ago")}</div>{shortcuts}')
FILES["Desktop.dc.html"] = (page("Notifications, widgets, Shortcuts", desktop, "home"), "Notifications · widgets · Shortcuts")

# ---------------------------------------------------------------- organising, duplicates, notifications in Settings
groups = [group([row("Copy to", "Where new copies go unless you choose another folder.", popup("Pictures › From phone", "folder")),
                 row("Organise copies", "Photos and videos go into folders by the date they were taken.", popup("By year and month", "calendar")),
                 trow("Skip files already on my Mac", "Found by content, even under other names, in the destination and Pictures.", True)]),
          f'<div style="padding: 12px 14px; border-radius: 14px; font-size: 12.5px; color: {T2}; {PANEL}">Example: <strong style="color: {T1};">Pictures › From myGalaxy › 2026 › 09 › 20260917_081544.jpg</strong></div>',
          group([trow("Notify me about copies", "When a copy finishes or needs you, and when a phone with new photos connects.", True),
                 trow("Copy new photos when a phone connects", "Only phones you choose; Relay asks the first time.", False)])]
FILES["SettingsOrganise.dc.html"] = (page("Settings: organising", settings_window("General", groups), "slate", SW, 640, radius=14), "Settings · organise, duplicates, notifications")
