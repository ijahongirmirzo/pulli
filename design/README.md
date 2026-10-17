# Screen designs

The design canvas lives in Claude Design: https://claude.ai/artifact/UmB43eUd97GB4pMNNtHrzX
(private to the owner until shared).

`generate.py [existing canvas.json]` produces the canvas's artboards (`project/*.dc.html` and
`project/canvas.json`, keeping the editor's keys from the existing index when given)
so the whole set can be regenerated or restyled in one place. Output goes to `design/project/`
(git-ignored); edits made directly on the canvas are the source of truth once the owner reviews.

Screens (first pass, 2026-09-27):

| Row | Screens |
|---|---|
| Connect | waiting · phone found (USB 2 speed hint) · locked / Charging only guide · another app holds the phone |
| Copy flow | choose · copying · paused (unplugged) · done (needs attention, renamed names) |
| Around the app | menu bar extra (progress bar per copy, every phone) · Settings General · Settings Advanced · log |
| Sound | interactive board: play each of the six sounds |

Pass 2 (2026-09-27): every screen in dark and light (a light row under each dark row, plus a Theme
tweak per board), themed through CSS custom properties with contrast-checked light tokens; the
Sound design board; a "Play sounds" switch in Settings.

Pass 3 (2026-09-27): native macOS 26 structure at the owner's request ("real mac native design like
sidebars, topbars, glass UI").

| Row | Screens |
|---|---|
| Connect | no phone · phone overview (storage, cable advice with time predictions, quick picks) · locked / Charging only guide · another app holds the phone |
| Copy flow | browse and choose (native table, glass bottom bar with time estimate) · copying · paused · done · history |
| Around the app | menu bar extra · Settings General · Sounds · Advanced (native Settings window with toolbar tabs) · activity log |
| Sound | interactive board: play each of the six sounds |

Pass 4 (2026-09-27): immersive style in the spirit of CleanMyMac, at the owner's request. Same
screens as pass 3. Each section has its own full-window colour scene (teal phone, blue copying,
amber paused, green done, violet history). The labelled sidebar appears on the welcome screen
only and folds into an icon rail elsewhere. The screens use glossy artwork drawn in SVG by
`generate.py`, frosted panels and cards, and one round glowing action button. Pass 3 (native
toolbar) is in git history if needed.
