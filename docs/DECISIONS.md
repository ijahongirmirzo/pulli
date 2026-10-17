# Decisions

Each entry: what we chose, why, and what evidence it rests on. Newest decisions go at the end.
Status is **Accepted** unless noted. "Verify in P1" means the claim comes from reading source
and docs, and still needs confirming on a real phone.

---

## D-001 Separate processes: app, helper, per-device MTP worker

**Choice.** Three kinds of process:

- `Pulli.app` is the SwiftUI UI.
- `pulli-helper` is a LaunchAgent that owns the journal and runs TransferCore.
- `pulli-mtp-worker` runs one process per connected phone and is the only code that links libmtp.

**Why.**
- The brief requires the transfer to survive a UI hang or crash, which rules out running it in the app.
- The worker split comes from how libmtp behaves:
  - `LIBMTP_GetPartialObject` cannot be cancelled, and blocks for up to 60 s per USB bulk read (`USB_TIMEOUT_LONG` for Android devices).
  - The only in-process way to abandon a wedged read is `LIBMTP_Release_Device`. For Android devices that triggers a forced USB reset (`DEVICE_FLAG_FORCE_RESET_ON_CLOSE`), and on Pixel phones a reset can kill MTP until the cable is replugged.
  - SIGKILL on a worker aborts the read at once. The kernel then releases the USB interface without a reset, and the helper keeps its XPC clients and journal.

**Cost.** One more process boundary, which puts chunk bytes over a socketpair.

## D-002 Persistence: SQLite through GRDB 7

**Choice.** GRDB.swift 7 (MIT licence).

**Why.**
- Full Swift 6 strict-concurrency support since 7.0.
- Migrations, WAL `DatabasePool`, Codable records.
- Raw `sqlite3` would mean hand-managing statement lifetimes and thread confinement, and would gain us nothing.

Only the helper opens the journal, enforced with `flock` on a lock file.

## D-003 Build libusb and libmtp ourselves, from pinned release tarballs

**Choice.** `Vendor/build-deps.sh` builds libusb 1.0.30 and libmtp 1.1.23 as dylibs, one architecture at a time, then merges them with `lipo`.

**Why.**
- Both libraries are LGPL-2.1+, so we link dynamically and bundle the dylibs.
- Homebrew bottles are single-architecture, have absolute install names, and change underneath us. Our build has `@rpath` install names and a pinned deployment target (macOS 26.0).
- Checksums are in `Vendor/versions.lock`. They were verified against both the upstream release assets and Homebrew's formula checksums.

**Details.**
- Release tarballs include a generated `configure`, so autoconf and automake are not needed.
- libmtp is configured with `--disable-mtpz`, so libgcrypt is not needed. MTPZ is only used by old Zune-era devices.
- `lt_cv_sys_max_cmd_len` is pinned. When libtool cannot run `sysctl` it falls back to incremental `ld -r` links, and those turn libusb's hidden internal symbols into locals, which breaks the link.
- pkg-config is restricted to our own prefix, so a Homebrew libusb can never leak in.

## D-004 Device identity: USB vendor ID + USB serial number

**Choice.** A phone is identified by `(idVendor, kUSBSerialNumberString)` from IOKit. The MTP serial is stored as secondary data.

**Why.**
- `LIBMTP_Get_Serialnumber` returns the MTP DeviceInfo serial. On current Android this is a random 32-hex ID stored in MediaProvider preferences (`MtpServer.java`), not the USB serial. It can change when app data is cleared.
- The USB product ID changes with USB mode (for example when ADB is toggled), so it is not part of the key.
- Known junk serials (all zeros, `0123456789ABCDEF`, shorter than 4 characters) fall back to the MTP serial.

## D-005 Resume identity: path + size + mtime, plus a tail guard

**Choice.** A file on the phone is found again by path, and must match size and modification time. When resuming a file with committed bytes, the last 1 MiB before the resume point is re-read from the phone and compared with the `.part`. A mismatch restarts the file from zero and logs an event.

**Why.**
- MTP object handles are not stable across sessions.
- mtime alone is weak:
  - Android writes dates as local time with no time zone (`MtpUtils.cpp`).
  - libmtp parses them with `mktime()` in the Mac's time zone.
  - Resolution is 1 s, and the value is ambiguous across daylight saving changes.
- The worker process runs with `TZ=UTC`. The parsed value is then the phone's wall-clock time, which is stable across Mac time zone changes. The mtime applied to the destination file is computed separately.

## D-006 Commit granularity and durability

**Choice.**
- Commits are aligned to fixed 4 MiB blocks (Q), independent of the read chunk size.
- On resume, `R = floor(min(journal offset, .part size) / Q) * Q`, and the `.part` is truncated to R before writing.
- A commit happens every 32 MiB or 2 s, whichever comes first, and on pause, disconnect or sleep.
- The `.part` is synced with `F_FULLFSYNC`. If a volume returns `ENOTSUP` (exFAT, network), it falls back to `fsync`, and the batch records which one was used.

**Why.**
- The brief's "round down to the last full chunk" is undefined once reads are short. libmtp's Samsung offset-bug workaround can return a byte less than requested.
- `fsync` alone does not flush the drive cache on macOS (`man fsync`).
- The journal is designed to be correct even if its last few transactions are lost. Apple's system SQLite reportedly issues barrier syncs even with `PRAGMA fullfsync`.

**Consequence found in testing (Phase 1).** A session only makes durable progress once it lives past one commit window. If a link drops more often than every ~32 MiB, nothing is ever committed. The engine will get an adaptive rule (Phase 2): after repeated disconnects with no committed progress, commit at every 4 MiB block boundary until the link is stable again. The cost is one extra sync per 4 MiB, which only matters on a link that is already failing.

## D-007 No libmtp patches for v1

**Choice.** Ship upstream libmtp unmodified. `Vendor/patches/` exists but is empty.

**Why.**
- Each candidate patch has a patch-free alternative:
  - stderr logging is captured from the worker's pipe.
  - The extra metadata round trip per partial read is negligible.
  - Reset-on-close is avoided because the worker exits without closing.
- Fewer patches keep LGPL compliance and upgrades simple.

## D-008 ptpcamerad handling

**Choice.**
- Read `UsbExclusiveOwner` on the phone's MTP interface.
- If the holder is `/usr/libexec/ptpcamerad`, verify it: executable path, same uid, and Apple code signature. Then SIGKILL it and claim the interface immediately, retrying at 0 / 150 / 400 / 1000 / 2000 ms, and hold the session while a batch runs.
- If a user app holds the phone (Preview, Photos, Samsung Smart Switch, Google Drive, and so on), show its name and ask the user to quit it. Pulli never kills user apps.

**Why.**
- ptpcamerad is a per-user, on-demand LaunchAgent (`/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`: `RunAtLoad` false, no `KeepAlive`). A same-user process can kill it without admin rights.
- `launchctl disable` needs admin rights and is reported unreliable with SIP on.
- libusb's capture and kernel-driver detach need root or a restricted entitlement.

**Status.** Proposed. Verify in P1 that holding the session prevents a re-grab.

**Open.** Killing processes is not allowed in the App Sandbox. A future App Store build depends on the ImageCaptureCore transport spike (D-009).

## D-009 ImageCaptureCore transport spike

**Status.** Open, time-boxed to 2 days in Phase 1.

**Question.** Does an Android phone in MTP mode appear in `ICDeviceBrowser`? If so, can `ICCameraDevice.requestSendPTPCommand` run the Android `GetPartialObject64` (0x95C1) command with at least 8 MiB of data, and list a large folder without enumerating the whole device? If yes, this is a second `DeviceSession` implementation that cooperates with ptpcamerad instead of fighting it, and it is sandbox compatible.

## D-010 XPC: Swift-native `XPCSession` / `XPCListener`

**Choice.** Codable message envelopes. The peer check is `XPCPeerRequirement.isFromSameTeam`.

**Why.** Both types are `Sendable`, which fits Swift 6 strict concurrency better than `NSXPCConnection`'s `@objc` protocols. Peer requirements arrived in macOS 26, our minimum.

**Dev builds.** Unsigned builds use a same-uid check. The release script asserts the team check.

## D-011 Design before UI code

**Choice.** Before Phase 4, the screens are designed in Claude Design and signed off by the owner. Phase 4 then implements the approved designs in SwiftUI.

**Why.** The owner asked for this (2026-09-27). Look and feel matters as much as the engine, and it is cheaper to iterate on a design than on SwiftUI code.

**Menu bar extra (owner request, 2026-09-27).** Clicking the menu bar item shows every copy that is running, paused or queued, across all connected phones. Each copy gets a progress bar, its speed and time left, and its state. There are also "Pause all" and "Open Pulli". The helper's XPC snapshot must carry every batch, not only the one the window shows.

**First pass.** Published 2026-09-27: 12 screens, generated by `design/generate.py`, canvas linked from `design/README.md`.

## D-012 Toolchain notes (Command Line Tools)

- SwiftPM's default build engine does not work inside the agent sandbox. It builds normally in a regular shell.
- With only the Command Line Tools, Swift Testing's macro plugin path is not passed to the compiler. `scripts/test.sh` adds it, and does nothing when Xcode is selected.
- `pulli-cli` and the packages build with the Command Line Tools. The app and helper bundles need Xcode (asset catalogs, signing, `SMAppService`).

## D-013 Development journals are erased on schema change (pre-release only)

**Choice.** `Journal.migrator` sets GRDB's `eraseDatabaseOnSchemaChange` while the schema is still being designed.

**Why.** No user data exists yet, and hand-written migrations between throwaway schemas would be wasted work.

**Must change.** Remove it before the first public build. After that, every schema change is a real migration with a test.

## D-014 Folder transfers: batches, lazy scans, byte-exact names

**Choice.**
- A copy is a **batch**: a selection of files and folders from one storage into one destination folder.
- Selected folders become `folder` rows and are scanned lazily. Each folder is listed once, and its children (sub-folders to scan, files to copy, renamed names) plus the folder's `done` state are written in one transaction. An interrupted scan lists that folder again, with no partial or duplicate rows.
- Files are copied in scan order, so the destination fills folder by folder.
- `TransferSupervisor` owns the loop around a batch:
  - reconnect by `DeviceKey`
  - wait while the phone is locked, in "Charging only" mode, or held by another app
  - back off on transient errors
  - pause in place while the destination is full or missing
  - switch to per-block commits on a flaky link (D-006)

  The CLI uses it now; the helper will use it in Phase 3.
- `BatchRunner` moves a file to **needs attention** when it fails for good, and the batch continues. That covers a file deleted on the phone, access denied, 8 failed attempts in a row without progress, or a file that changed more than 3 times. An empty `.part` is removed at that point; a `.part` with committed bytes is kept for "Try again".
- **Duplicate policies**:
  - `auto` (default): skip if same size and date, otherwise keep both
  - `skip`
  - `overwrite`: atomic rename over the existing file
  - `keep_both`: "name (1).ext"
- Running the same copy again creates a new batch, whose `auto` policy skips everything already copied. "Copy new photos since last time" needs no special mode.

**Names.**
- Android names are case-sensitive and may contain any byte sequence. Most Mac volumes are case-insensitive and normalisation-insensitive.
- `NameMapper` replaces `/`, NUL and control characters, handles `.` and `..`, and truncates names over 244 UTF-8 bytes (leaving room for `.part` and ` (999)`).
- It resolves case and Unicode-normalisation clashes within a folder by numbering them.
- Every change is recorded in `name_mapping` with its reason.

**Byte-exact comparisons.** Swift's `String ==` treats NFC and NFD forms as equal, but a phone can hold both as different files. So `RemotePath` equality, `ExactName`, the MTP folder cache and scan ordering all compare UTF-8 bytes. Without this, two distinct phone files could be conflated.

**Small files.** Files under 4 MiB are copied in one go, with one journal write when done. When the journal is on the same volume as the destination they use `F_BARRIERFSYNC`: ordering is enough, because the "done" row is written after the file and its rename. Otherwise they use `F_FULLFSYNC`.

A job tag xattr (`com.relay.job`) on each finished file lets a re-run recognise our own completed file after a crash between the rename and the journal update.

Measured on MockDevice in a debug build: 3,000 small files in about 10 s, including scanning, journal and file-system work.

## D-015 Phase 2 findings: durability gaps, whole-object reads, bookkeeping cost

**Durability gaps found by `SimulatedVolume`.** This test sink keeps only synced contents and synced directory entries across a simulated power loss. It found two real gaps, both now fixed:
1. `createDirectory` did not sync each new folder into its parent. A power loss could remove a folder, and every finished file in it, after the journal said "done".
2. A new `.part` file's name was not durable before its first commit, so a power loss could remove the `.part` the journal claimed bytes in. The fix syncs the folder once, before a file's first commit in each run.

APFS probably commits these names along with the data anyway, but POSIX does not promise it, and SQLite takes the same precaution.

**Whole-object reads.** Some phones cannot read by offset, and some cannot read beyond 4 GiB by offset. For those files Pulli streams the whole file with `LIBMTP_Get_File_To_Handler`.
- A bounded pipe (8 × 4 MiB) blocks the dedicated MTP thread when the destination is slower than USB, so memory does not grow with the file.
- These files cannot resume: an interruption restarts them from zero, and the job records `read_strategy = whole`.

**Bookkeeping at 50,000 files** (release build, MockDevice, journal work only):

| Stage | Time |
|---|---|
| Scan (listing plus 50,000 inserted rows) | 1.6 s |
| Per-file bookkeeping, one transaction per file | 10.8 s |
| Per-file bookkeeping, grouped: 128 files per transaction, one folder sync per group | 6.4 s |

Grouping brings the total to about 8 s, against the 5 s target. What remains is mostly two indexed reads per file, which the runner can fetch in pages later. On a real phone, USB is still the bottleneck for small files: each needs its own MTP round trips.

**Randomised verification.** Run locally for this commit: 300 seeds each of the fault matrix, power loss and journal rollback, with every run byte-identical. The default test run uses 24 seeds per suite.

## D-016 Recovering a phone after a killed transfer (verified on a Galaxy Z Fold7)

**Problem.**
- After a `kill -9` during a partial read, the phone keeps sending the rest of the interrupted chunk. Its MTP server answers nothing until the host reads that data.
- libmtp's next OpenSession fails with `PTP_ERROR_IO`, and its fallback is `libusb_reset_device`.
- After the reset, ptpcamerad re-grabs the phone and Samsung hides the storage until the phone is unlocked.

**What did not work on the Fold7.**
- PTP class requests: Get Device Status (0x67) got no answer.
- Draining the IN pipe with short timed-out reads. On macOS, a timed-out libusb transfer aborts the pipe and clears the endpoint halt, and the Fold7 dropped off the USB bus entirely. It happened twice, each time seconds after the drain ran.

**Choice.** `MTPQuiesce` runs only when `SessionMarker` shows the previous session did not end cleanly. It works like this:
- A marker file per USB serial is written at open, removed at a clean close, and also removed when the phone leaves the bus (it comes back fresh).
- A helper thread sends a fresh OpenSession while the main thread reads the IN pipe.
- Stale chunk data, the old transaction's response and then our reply arrive in turn, so no read ever waits on silence.
- It then sends CloseSession and hands libmtp an idle phone.

**Verified.** The copy survived 3 of 3 kills. The stale data discarded was 12.9 MB and 0.7 MB. The phone replied to our OpenSession with 0x201E (session already open) and to CloseSession with 0x2001. There was no reset, the storage stayed visible, and the result is byte-identical.

**Chunk size.** The default is now 8 MiB (was 32 MiB). On the Fold7 it was fastest, and it keeps each uncancellable read under 0.3 s and the stale data after a kill small. Figures are in `docs/device-matrix.md`.

**Also noted.** A process killed inside a USB call can take a few seconds to exit, and holds the journal lock until then. The helper (Phase 3) must wait for the old worker to exit before starting a new one.

## D-017 Helper architecture as built (Phase 3)

**Processes.**
- `Pulli.app` talks only XPC.
- `pulli-helper` is a LaunchAgent (`Helper/app.pulli.mac.helper.plist`, registered with `SMAppService.agent`). It owns the journal and every copy.
- `pulli-mtp-worker` runs one process per open phone session, and is the only process that loads libmtp.

**Helper core (transport-independent, `HelperCore`).**
- `DeviceHub` lists phones from IOKit. It opens a phone only while the app shows phones or a copy needs it, so a helper that starts at login never takes phones away from Photos and other apps. Sessions are shared as leases, and a lease that saw an error makes the next open start fresh.
- `TransferService` runs one batch at a time per phone, with phones in parallel. A user's pause is persisted (`batch.state = paused`) and survives restarts. Unfinished batches restart by themselves when the helper starts, including after a reboot.
- `HelperEngine` answers requests and fans events out to clients. It keeps a ring of the last 2,048 numbered events so a reconnecting app can replay what it missed; otherwise the app gets a snapshot.

**Protocol (`PulliProtocol`, v1.0).**
- The snapshot carries every phone and every batch, which the menu bar extra needs.
- Batch progress events are throttled to about 4 per second.
- Folder listings stream as unnumbered pages to the client that asked.

**XPC.**
- Swift-native `XPCListener` and `XPCSession`, with Codable messages.
- When the process is team-signed, both sides require `isFromSameTeam`. Ad-hoc development builds rely on launchd's per-user domain.
- Listeners start active; calling `activate()` again traps (found in testing).

**Workers.**
- Length-prefixed frames with a JSON header and a raw payload for file data, over the worker's stdin and stdout.
- The worker keeps a private copy of stdout for frames and points fd 1 at stderr, because libmtp prints to stdout.
- The helper's watchdog kills a worker when a request makes no progress for 30 s (120 s for opening). The next worker waits for the old one to exit plus 3 s, then recovers the phone (D-016).
- In testing, a worker that hangs on every 4th read, or crashes on its 3rd read, still completes the batch byte-identical.

**Found while building it.**
1. A newly attached phone was not announced unless something else changed.
2. Engine events were applied out of order.
3. Stalls and crashed workers did not count towards the flaky-link rule, so a phone that stalls before every commit made no progress. Any lost session without progress now counts (D-006).

## D-018 Appearance and sound (owner requests, 2026-09-27)

**Light and dark.**
- The app follows the Mac's appearance setting.
- The designs show both modes: every screen has a light twin, and a Theme tweak on each board.
- The palettes are themes of the same tokens:

| Token | Dark | Light |
|---|---|---|
| Background | #0E1114 | #F3F4F6 |
| Primary text | #F2F4F5 | #15181C |
| Secondary text | #A9B2BA | #48515A |
| Tertiary text | #8A949D | #5E6770 |
| Accent ink (links, check marks) | #8FE6DB | #0A7A6D |
| Amber | #F2B24C | #9A5B00 |

- Light mode darkens the accent ink and amber so text and icons keep contrast.
- The teal accent fill and its dark label work in both modes.
- In SwiftUI these become asset-catalog colours with Any/Dark appearances. Glass stays system material, so it adapts by itself.

**Sound, like CleanMyMac.** Six short cues:

| Cue | Sound |
|---|---|
| Phone connected | two rising notes |
| Copy started | airy swell into a low tone |
| Paused | two gentle falling notes |
| Resumed | quick rising pair |
| Copy finished | four-note arpeggio with a shimmer: the signature |
| Needs attention | two soft muted ticks |

- On by default, with a "Play sounds" switch in Settings.
- Silent when the Mac's "Play user interface sound effects" is off, during Focus, and while another app is full screen.
- At most one cue per second, and never one per file.
- The recipes live in the design canvas's Sound board (Web Audio). The app ships the same recipes rendered offline to short .caf files, so no licensed audio is involved. Played with AVAudioPlayer at the system alert volume.

## D-019 Native macOS window structure (owner request, 2026-09-27)

The owner asked for "real mac native design like sidebars, topbars, glass UI". Design pass 3 replaces
the custom single-window look with standard macOS 26 structure:

- **NavigationSplitView** with a floating Liquid Glass sidebar holding the window buttons. Sections:
  Phones (each phone with its link badge), Copies (Copying with a progress ring, History), and Needs
  attention when anything does.
- **Unified toolbar**: title and subtitle on the left, glass capsule controls on the right; the main
  action uses the prominent (accent-filled) glass style. Related controls share one capsule.
- Content stays in the content layer: tables (`Table`), grouped forms (`Form` with `.grouped`), cards.
  Glass is only for controls and the floating bars, never for lists, and never glass on glass.
- **Settings** is a separate native Settings window with toolbar tabs: General, Sounds, Advanced.
- System font (SF Pro), 13 pt body. Teal accent unchanged; greys follow the system.
- **Cable advice is visible where it matters:** the phone overview shows the negotiated USB version,
  what the phone supports, a better-cable suggestion and per-selection times now and with USB 3
  (from `CableAdvice`); the choose bar and the copying screen repeat it in one line; the menu bar
  extra adds one line under a copy on a slow link. A "Suggest a faster cable" switch in Settings
  turns the suggestions off.

## D-020 Immersive CleanMyMac-style look (owner request, 2026-09-27; supersedes D-019's styling)

The owner shared CleanMyMac screenshots and asked for that kind of design. Design pass 4 keeps
D-019's structure (sidebar sections, a Settings window with tabs, cable advice placement) and
changes the look:

- **Colour scenes.** Each section fills the window with its own gradient: phone and connect in
  teal, copying in blue, paused in amber, done in green, history in violet, and settings in a
  neutral slate. Light mode uses pastel versions with dark text. In SwiftUI the scene is a
  `MeshGradient` behind the content; changing section cross-fades it.
- **Sidebar.** Labelled on the welcome screen. Everywhere else it folds into an icon rail, and the
  rail tiles show live status: a pie on Copies, and a dot on Needs attention.
- **Artwork and controls.**
  - Big glossy illustrations, all Pulli's own and not CleanMyMac's: a Fold-style phone with a
    cable, and badge "gems".
  - Frosted glass panels and result cards (Liquid Glass), with round "Review" buttons.
  - One round, glowing primary button per screen: Copy.
  - The ring around the phone is the progress indicator.
- **Brand.** The teal accent and the sounds from D-018 are unchanged. Nothing is copied from
  MacPaw's artwork or branding.

## D-021 The SwiftUI app (Phase 4b, 2026-09-27)

**Where the engine runs.**
- By default the app starts a `HelperEngine` inside its own process (`PulliHost.EmbeddedEngine`)
  and talks to it through the same requests and events as over XPC (a loopback connection). Real
  phones still go through `pulli-mtp-worker` processes, so a wedged phone never hangs the app.
- With "Keep copying when Pulli is closed" on, the app registers the LaunchAgent with
  `SMAppService` and connects over XPC instead. If the helper already holds the journal, the app
  connects to it rather than starting a second engine.
- Why: the helper needs a Developer ID signature to be approved by macOS, and enrolment is still
  pending. The app must work fully without it; copies left unfinished when the app quits resume
  from the journal on the next launch.
- `Pulli` imports `PulliHost` for this (an exception to "the app imports PulliClient only");
  the UI code itself only uses PulliClient and PulliProtocol types.

**Typeface.** Plus Jakarta Sans (SIL OFL 1.1), bundled and registered at launch, as the owner
asked for a typeface other than the default one. SF Symbols stay for icons.

**Introduction.**
- About four seconds, on first launch only (`introShown` in UserDefaults), and skippable. It can be
  brought back from Settings › Advanced.
- The sequence: light gathers into Pulli's mark, the name writes itself, three promises rise in,
  and it ends on a round Get Started button.
- Its sound is rendered by `scripts/render-sounds.py` and timed to the animation. Reduce Motion
  gets a plain fade.

**Sounds.** The six cues and the intro are rendered offline by a dependency-free Python script
into WAV files. They play with `AVAudioPlayer`, at most one per second, and never when the Mac's
interface sounds are off.

**Checking the screens.** `Pulli --snapshot DIR` renders every screen, in dark and light, from
sample data with `ImageRenderer`, so the app can be compared with the canvas without a display.
Scroll views and system link buttons cannot be drawn offscreen, so snapshots use plain stacks and
Pulli's own link style.

**Packaging.** `scripts/make-app.sh` assembles `build/Pulli.app` and signs it ad hoc. The bundle
holds the app, the helper, the worker, libmtp and libusb in Frameworks (rpath rewritten), the
fonts and sounds, the icon rendered from `AppIconArt`, and the LaunchAgent plist.

## D-022 New features (owner request, 2026-09-27)

Design pass 5 on the canvas came first; then each feature was built, tested on the simulated
phone, and committed.

- **Previews.** The phone's own thumbnails (MTP GetThumb). On the Galaxy Z Fold7 a photo's takes
  36 ms (45 KB) and a video's 196 ms. They are cached in memory and on disk, at most three are
  fetched at once, and rows that scroll away are skipped. Other files show Finder's icon.
- **Selection.** Drag across rows, ⌘-click, ⇧-click, Select All and Esc. One gesture handles the
  whole list and there is no double-click recogniser, because that made every click wait.
- **Quick Look.** Space fetches the file into `~/Library/Caches/app.pulli.mac/QuickLook` (skipped
  when a copy of the same size is already there), then opens the system Quick Look panel.
- **Duplicates.** A phone file counts as already on the Mac when a file in the destination or
  `~/Pictures` has the same size, the same first 64 KB and the same last 64 KB. Those 128 KB are
  read from the phone; the file is never copied for this. The Mac size index is cached for two
  minutes. Such files are badged, left unticked, and left out of Camera copies. The setting is
  "Skip files already on my Mac", on by default.
- **Mac → phone.** Drop Finder items on a folder, or use Add from Mac. Folders are created as
  needed. Files are sent with an MTP object format chosen by extension, so the phone's gallery
  indexes photos and videos. An interrupted upload restarts from the beginning, because MTP
  cannot append.
- **Messaging-app media.** WhatsApp, Telegram, Instagram and Viber folders (the Android 11+
  `Android/media/…` location first, then the older one), measured over their whole trees and
  shown as cards.
- **Storage map.** A breadth-first walk of the whole storage, adding every file to each folder on
  its path. Snapshots stream every 0.5 s, trimmed to the 14 biggest children per level, 4 levels
  deep. The map is a squarified treemap.
- **Free up space.** The only feature that deletes anything:
  1. Every finished file is read again from the phone and SHA-256 is compared with the Mac copy.
  2. The confirmation lists what will go and what stays, and its button stays disabled until
     "I understand" is ticked.
  3. Only files found identical, and unchanged on the phone since the check (same size and
     date), are deleted.
  4. A delete without a fresh check is refused, and each check allows only one delete.

  A test damages one Mac copy and checks that its original stays on the phone and that nothing
  outside the copy is touched.
- **Organise by date.** A batch option (journal migration v2, a normal migration so history is
  kept) that places files in `YYYY/MM` by the phone's date, or `Unknown date`.
- **Notifications.** Sent only while Pulli is in the background, for:
  - a copy finished or needing attention
  - a copy paused by unplugging
  - files copied to the phone
  - space freed
  - an automatic copy starting
- **Copy new photos when a phone connects.** Off by default. It applies only to phones Pulli copied
  before, and never while a copy of that phone is running.
- **Shortcuts.** App Intents: Copy New Photos from Phone, Get Phone Status, and Show Phone Storage
  Map. SwiftPM does not produce App Intents metadata, so `make-app.sh` runs
  `appintentsmetadataprocessor` on the compiler's constant values. `relay://copy-new`,
  `relay://storage-map` and `relay://open` do the same from any app.
- **Desktop widget.** A WidgetKit extension (small ring, medium list), bundled and registered by
  `make-app.sh`. With no Developer ID there is no App Group, so the app writes the snapshot into
  the widget's own container, and only once macOS has created it (after the widget is added).
  Revisit with signing: use an App Group.

**Still to test on a real phone:** upload, make-folder and delete over libmtp (`pulli-cli put` and
`pulli-cli rm` exist for this, and should be tried on a test file only), and a timing of the
storage walk (`pulli-cli du`).

## D-023 Drag and drop both ways, opening files directly, the phone in Finder (2026-09-27)

**Dragging out of Pulli.**
- The Choose list's mouse handling is an AppKit view (`ListMouse`). It gives real click counts
  (a double click opens a file, and single clicks never wait), painting ticks, hover and the
  right-click menu.
- Dragging ticked rows out gives Finder file promises. Everything from one drop is copied as one
  ordinary, resumable batch into the drop folder, and the promises are kept when it finishes.
- Painting ticks and then pulling out of the list drags what was ticked.

**Opening without copying.**
- Open, Open With (Finder's list of apps for the type, plus Other…) and Quick Look stream the file
  into `~/Library/Caches/app.pulli.mac/QuickLook` and open it there. The user never manages a
  copy. Edits there stay on the Mac; to change the phone's file, open it from the Finder drive.

**The phone as a drive in Finder.**
- A WebDAV server inside the engine (`HTTPServer` plus `PhoneDrive`) is mounted with NetFS, so
  the phone appears in Finder's sidebar under its own name.
- Why WebDAV: it needs no kernel extension, no FSKit or File Provider entitlement, and no
  Developer ID; macOS's own client does the work. Revisit File Provider or FSKit after enrolment.
- Reads are ranged MTP reads, so files open and videos play without copying.
- Writes send the new content under a temporary name before replacing, so a failed upload never
  loses the old file. Finder's own bookkeeping files (dot files it writes) stay in memory and
  never reach the phone.
- Deleting and renaming the phone's files from Finder is off until Settings › Advanced allows it.
  Files Finder itself just created are always manageable, as its copy sequence needs.
- Moving between folders is not supported yet.
- The server is reachable only on 127.0.0.1, under a random path segment. It stops when the phone
  leaves, and the app unmounts the volume then and on quit.
- Tested over HTTP (listing, ranges, Finder's write sequence, the delete guard, rename) and by
  mounting with `mount_webdav`: list, read and write through the file system
  (`RELAY_MOUNT_TEST=1`).

## D-024 Copy button outside the window, parallax art, icon view, nested storage map

- The Copy button hangs over the window's bottom-right corner, half outside it (as CleanMyMac's
  Scan button). A view cannot draw outside its window, so the button is in a small borderless
  child window that moves with the main window. When there is no room below the window (full
  screen, or the window reaches the Dock), it sits inside the corner. It never becomes key; Return
  still copies through a hidden button in the main window.
- Gems are drawn as separate flattened layers (shadow, body, gloss, symbol) that shift apart and
  tilt toward the pointer. On the phone screen the whole card drives its gem, and a click anywhere
  on a card does what its button does (Review, Browse, Which Cable?); the tick box keeps its own click.
- The Choose list has an icon view beside the list (⌘1, ⌘2), an icon size slider, and a Sort menu
  (Name, Kind, Date Modified, Size; order; folders on top), remembered across launches. The order
  is computed once per listing or sort change, never per tick.
- The storage map shows big folders' contents inside them (one level), gathers tiles smaller than
  about 60 × 60 points into one "smaller items" tile, labels by the room a tile has, and lists
  the largest items beside the map. A phone with one huge folder no longer draws one flat block
  and a column of slivers.

## D-025 Art as real 3D objects (SceneKit)

- Gems, the hero phone and the app icon are 3D models, not drawings: shapes extruded with
  rounded bevels, physically based materials (lacquered colour, milky white, satin metal, glass),
  lit by a generated studio environment (soft boxes, strip lights) with a key light casting a soft
  shadow onto an invisible backdrop, and a rim light.
- SF Symbols become solid shapes by tracing a large monochrome rendering with Vision
  (`VNDetectContoursRequest`); holes are found by containment and wound the other way, as SceneKit
  fills by direction.
- Views are larger than the object they show, so shadows and turns are never cut off (the flat
  version's blurred layers were clipped to squares).
- Big art is a live transparent view that turns toward the pointer; the Done disc and other big
  pieces also drift. Icons under 90 points (lists, rows, result lines) are flat vector badges
  in the same colours (3D reads as noise at that size) and do not move. Screen snapshots render every piece to images the same way.
- The flat phone drawing remains only as `PhoneDrawing` (unused by screens).

## D-026 Copy and paste with the Mac, drops from any app

- ⌘C on phone items (the ticked ones, else the highlighted one) puts them on the clipboard as
  files on the phone's Finder drive, mounting it if needed. Finder pastes them with its own
  progress; any app that takes files can paste them too. File promises would be neater, but
  Finder only honours them for drags, not for Paste.
- ⌘V in a phone folder copies what is on the clipboard there: files; a picture (a browser's
  Copy Image, a screenshot to the clipboard), saved as a file first; or a web address of a file,
  downloaded first.
- Drops accept item providers from any app: file URLs, files the app writes on request (Telegram,
  WhatsApp, Photos, Safari), picture or document data, and web links (downloaded). Received
  files wait in Caches/Incoming until they are on the phone; a day later they are removed.
- The list takes the keyboard (first responder) so the Edit menu's Copy and Paste reach it; the
  search field keeps its own Copy and Paste while it is typed in.

## D-027 Installing, opening at login, and running light in the background

- The disk image opens as an installer window: art drawn by Pulli (`--dmg-background`), laid out
  by dmgbuild. Finder shows only a still picture there, so the motion is in the app: opened from
  the disk image (or from a temporary copy macOS runs a download from), Pulli offers to move
  itself to Applications, with the icon flying into the folder. Moving copies it, puts an older
  copy in the Trash, reopens from Applications and ejects the disk image.
- Open Pulli at login uses SMAppService.mainApp. A login launch (the launch Apple event says so)
  puts the window away and hides the Dock icon; the engine starts with the app, not the window.
  With the window closed, the views, 3D scenes and preview caches go (about 38 MB in use, against
  about 110 MB with the window open). Phones are watched with no window only when opening at
  login; a phone plugged in then brings the window forward (or sends a notification).
- Closing the window keeps Pulli running while the menu bar item is shown or it opens at login.

## D-028 libusb is built without `pipe2`, which is macOS 27 only (found 2026-09-29)

**Problem.**
- The build uses the macOS 27 SDK, which declares `pipe2` with `__API_AVAILABLE(macos(27.0))`.
  libusb's configure only checks that it links, so it set `HAVE_PIPE2`.
- With our 26.0 deployment target the compiler then imports `_pipe2` weakly (`nm -m` showed
  `weak external _pipe2` in both slices of `libusb-1.0.0.dylib`). macOS 26 does not have the
  symbol, so it resolves to NULL there. `libusb_init` calls it unchecked when it creates its event
  pipe (`usbi_create_event`), so every phone detection (`LIBMTP_Detect_Raw_Devices`) would crash
  the worker on macOS 26.
- A Mac running macOS 27 has the symbol, so the problem never shows there.

**Choice.** `build-deps.sh` passes `ac_cv_func_pipe2=no` to libusb's configure. libusb then uses
`pipe` and sets close-on-exec with `fcntl`, its own fallback for systems without `pipe2`.

**Cost.** Close-on-exec is set just after the pipe is created instead of atomically. That only
matters if another thread starts a program in that moment.

**The build checks itself.** After assembling, `build-deps.sh` lists each dylib's weak imports
(`nm -m -arch all`; without `-arch all`, `nm` reads only the Mac's own slice). If there are any,
it prints them, deletes `Vendor/out` so nothing links or bundles the libraries, and fails. Tested
by building without the `pipe2` override.

**Reproducible from any folder (found while checking the fix).** libmtp's bytes differed between
the main checkout and a worktree, for two reasons:
1. The install prefix was inside the checkout. The linker writes it into the install names, and
   a longer name moves all the code after the load commands.
2. The debug map listed each object file by absolute path. That also put the builder's home
   folder into the shipped libraries.

The fixes:
- Configure with a fixed prefix, `/relay-vendor`, that exists nowhere, and stage the files with
  `make install DESTDIR=...`.
- Trim the object paths with the linker's `-oso_prefix`.
- Install only libmtp's `src/` (the library and `libmtp.h`), not its example programs.

As a side effect libmtp no longer lists `libobjc`, an unused dependency it inherited from
libusb's libtool archive. libusb still loads it.

**Verified (on macOS 27, macOS 27 SDK).**
- configure reports `checking for pipe2... (cached) no`, and libusb now imports plain `_pipe`.
- Neither dylib has a weak import or a weakly linked library in either slice. Both have
  `minos 26.0`.
- libmtp never had a weak import. libusb's other configure checks (`pthread_threadid_np`,
  `nfds_t`) are for long-standing APIs.
- Clean builds from paths of 88 and 214 characters are byte-identical. No path from the build
  machine is left in the dylibs.
- `scripts/test.sh` passes. `MTPLibraryTests` runs phone detection through the new `pipe` path.
- Not yet run on a macOS 26 Mac.

## D-028 Suggesting a smaller chunk for a struggling phone

- Some phones (seen: a Lenovo A1000) fail repeatedly on large partial reads (8 MiB) and drop
  off USB, whilst copying steadily with smaller pieces. Chunk size was previously one global
  setting (`HelperSettings.chunkMiB`).
- `BatchEvent` reports failed partial reads as `.readFailed(job, error)` when a transfer throws
  `.transient` or `.staleHandle`.
- `TransferService` keeps recent read failure timestamps per phone over a 10-minute sliding
  window. When 3 or more failures occur in that window and the phone's effective chunk size is
  at least 4 MiB, Pulli offers a step-down to `max(1, current / 4)` MiB (8 → 2, 4 → 1, 16 → 4).
- The suggestion is overlaid onto `DeviceSnapshot` as `chunkSuggestion` and shown as a card on
  the phone overview and the copying and paused screens.
- Accepting persists the override in `HelperSettings.chunkMiBByDevice` and immediately restarts
  any running batch on that phone with the new chunk size, without marking it paused by the user.
  Declining clears the suggestion and remembers the decline for that phone and chunk size until
  the engine restarts.
- Settings › Advanced lists any per-phone chunk overrides beneath the global chunk size picker,
  with a button to revert each phone to the default size.


## D-029 Mounting the phone drive with mount_webdav, not NetFS

- NetFS (the framework behind Finder's Connect to Server) refused Pulli's drive: with no dialogs
  allowed it tries to sign in and fails at once (NetAuth -6600). As a guest it mounts, but every
  mount of a server on this Mac waits 90 seconds before finishing, whatever the options; the drive
  itself has answered every request within a few milliseconds by then.
- Pulli now runs macOS's WebDAV client directly (`mount_webdav -S`): about two seconds, no
  account, no dialogs. Only system tools can create folders in /Volumes, so the mount point is in
  ~/Library/Application Support/Pulli/Drives/<phone>; Finder opens it and lists it as a drive.
- The mount folder is removed with rmdir only: it fails on a folder that is still mounted, so a
  failed unmount can never turn into deleting files on the phone.
- The icon view no longer sets its own width (it only fills the width it is given): the column
  count follows the measured width, and a grid wider than its container kept the list from ever
  getting narrower after a window resize.

## D-030 Product name: Pulli

- "Relay" is crowded (Firefox Relay and many others) and hard to find.
- Pulli is short, says what it does (pulls files off the phone), and was free on the App Store with no conflicting products or trademarks found (2026-10-14).
- Internal names renamed from Relay to Pulli (Step 1); runtime identities stay Relay until migration (Step 2).

## D-031 Internal names and identity follow the product (2026-10-14)

- The code's names are Pulli too: package, targets (Pulli, PulliProtocol, PulliClient, PulliHost,
  PulliWidget, PulliFileProvider), programs (pulli-helper, pulli-mtp-worker, pulli-cli) and types.
- Identity: bundle ids `app.pulli.mac` (+ `.widget`, `.fileprovider`), App Group
  `8Q2D6948R4.app.pulli.mac`, helper `app.pulli.mac.helper`, link scheme `pulli://` (`relay://`
  still accepted), data in `~/Library/Application Support/Pulli`.
- Kept on purpose: stored format names users' data already carries (`relay-chain-v1` in every
  journal, the `com.relay.job` tag on unfinished files), the notarisation profile `relay-notary`,
  and checks that recognise an older Relay helper, worker or app.
- One-time migration on first launch (`LegacyMigration`, `DataFolder`): stops the old helper and
  its workers, copies settings from `app.relay.mac`, re-enables open at login and the background
  helper if they were on, and moves the data folder in one rename (never while an old process holds
  the journal; a still-mounted phone's folder stays where it is). Checked on the owner's Mac: 12
  copies and 3,461 file records arrived intact. The widget, notifications and the File Provider
  switch are tied to the bundle id and are set up again by the user.

## D-032 Auto-updates with Sparkle 2 (2026-10-15)

- **Why Sparkle 2.** Pulli is distributed outside the App Store as a notarised Developer ID DMG.
  Sparkle 2 is the standard macOS auto-update framework: it handles background checks, user prompts,
  delta and full updates, EdDSA cryptographic signature verification, and in-place relaunch.
  A future App Store build will omit Sparkle via build configuration.
- **Feed and hosting.** The appcast feed is hosted in Pulli's own public repository `ijahongirmirzo/pulli`
  (a separate `pulli-releases` repository was used for one day on 2026-10-17, then merged in)
  on its `main` branch at `https://raw.githubusercontent.com/ijahongirmirzo/pulli/main/appcast.xml`.
  Release DMGs are published as GitHub Release assets in that repository.
- **Key handling.** EdDSA signatures (`ed25519`). The private key is generated once using Sparkle's
  `generate_keys` tool and stored strictly in the owner's macOS Keychain — it is never committed or
  present in the repository. The public key is stored in `Config/sparkle-public-key.txt` and embedded
  as `SUPublicEDKey` into `Info.plist` during release builds (`make-app.sh`).
- **Safety during active copies.** Updates must never interrupt active file transfers.
  `SPUUpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` detects running
  or scanning copy batches and defers installation, displaying a banner in the app:
  "Pulli will update when this copy finishes." Once all batches finish, the app instructs the helper
  to prepare for the update (`.prepareForUpdate`), and allows Sparkle to proceed with the relaunch.

## D-033 Licences: GPL v3 for Pulli, Apache 2.0 for FinderLocations (2026-10-17)

- **Pulli** (everything outside `Packages/FinderLocations`): GNU GPL version 3 or later, with one
  additional term under section 7(b): versions of Pulli keep the attribution "Pulli, created by
  Jakhongirmirzo Ibrokhimov" in their About window and NOTICE file. Anyone may copy, change and
  sell Pulli, but only as open source under the same licence, so no one can sell a closed copy.
- **FinderLocations**: Apache License 2.0 with a NOTICE file, so other Mac apps (open or closed)
  can use it, and must carry the owner's credit in their notices.
- **Why:** the owner wanted protection from closed resale of the app, credit when the code is
  used, and wide use of the reusable package (D-031).
- The owner holds all copyright, so the owner can still ship Pulli on the App Store. Before
  accepting outside contributions, add a contributor agreement that keeps this possible.
- The name "Pulli" and its logo are not covered by the GPL; modified versions use another name.

