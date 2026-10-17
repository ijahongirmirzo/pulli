# Developing Pulli

How to build, test, sign and release Pulli. For what Pulli is, see the [README](../README.md);
for why each part exists, see [DECISIONS.md](DECISIONS.md).

## Requirements

- macOS 26 or later on the build machine; the app targets macOS 26.0.
- Xcode (latest). The Command Line Tools are enough for the Swift packages and `pulli-cli`, but
  not for the app and helper bundles.
- Homebrew is not required. The vendored libraries are built from pinned tarballs.

## Build

```bash
# 1. Build libusb + libmtp (universal, ~30 s). Output goes to Vendor/out (git-ignored).
Vendor/build-deps.sh

# 2. Build the Swift packages and the developer CLI.
swift build

# 3. Run the tests.
scripts/test.sh
```

`Vendor/build-deps.sh --archs arm64` builds a single architecture; `--clean` starts from scratch.
The build is reproducible: clean builds give byte-identical dylibs, whatever folder the checkout
is in. It stops if a dylib uses anything newer than macOS 26.0 (docs/DECISIONS.md, D-028).

## The app

```bash
scripts/make-app.sh            # build/Pulli.app (release, ad-hoc signed); --debug builds faster
open build/Pulli.app           # real phones
build/Pulli.app/Contents/MacOS/Pulli --mock        # a simulated Galaxy Z Fold7 on USB 2
.build/debug/Pulli --snapshot /tmp/pulli-shots     # every screen, dark and light, as PNG
scripts/render-sounds.py       # re-render the sound cues into Sources/Pulli/Resources/Sounds
```

The introduction plays once on first launch (Settings › Advanced › Introduction brings it back).

What else it does (D-022):
- Phone previews, Quick Look (Space), drag and ⌘/⇧ selection.
- Duplicates already on the Mac are skipped.
- Mac → phone by drag and drop.
- WhatsApp, Telegram, Instagram and Viber media.
- A storage map of the phone.
- Free up space, only after checking every copy against the phone.
- Notifications, organising by year and month, and auto-copy of new photos.
- Shortcuts actions, `pulli://` links, and a desktop widget.
Copies run in an engine inside the app unless "Keep copying when Pulli is closed" is on, which
registers the background helper (needs a Developer ID signature to be approved; see D-021).

## Try the engine from the command line

```bash
.build/debug/pulli-cli devices                     # phones on USB, without opening them
.build/debug/pulli-cli doctor                      # who holds the phone, link speed, mode
.build/debug/pulli-cli info --dump                 # open a session: model, storages, capabilities
.build/debug/pulli-cli ls /DCIM/Camera --summary   # lazy, paged folder listing
.build/debug/pulli-cli copy /DCIM/Camera ~/Pictures/Phone        # whole folder, resumable
.build/debug/pulli-cli copy /DCIM /Download/a.pdf ~/Desktop/out   # several items, like cp
.build/debug/pulli-cli batches [id]                               # past copies, needs-attention list
.build/debug/pulli-cli bench /DCIM/Camera/VID.mp4  # throughput per chunk size
.build/debug/pulli-cli thumb /DCIM/Camera/IMG.jpg out.jpg        # the phone's own preview
.build/debug/pulli-cli du /                                      # walk and total (storage map)
.build/debug/pulli-cli put notes.txt "/Download/Pulli test"      # Mac → phone
.build/debug/pulli-cli rm "/Download/Pulli test/notes.txt" --yes # delete one file
```

`copy` copies files and whole folders. It survives cable pulls (it waits for the same phone, by
serial), a locked phone, a full disk, Ctrl-C and crashes: run it again to resume from the last
committed byte. Running the same copy later only copies new files.

The full fault-injection matrix: `PULLI_FAULT_SEEDS=1000 scripts/test.sh --filter faultMatrix`.

The background helper can run under launchd during development (this adds a login item):

```bash
scripts/dev-helper.sh install --mock    # simulated phone; drop --mock for real phones
.build/debug/pulli-cli helper --follow  # watch phones and copies through XPC
scripts/dev-helper.sh uninstall
```

## Layout

```
Package.swift        Swift packages (one package, many targets)
Sources/DeviceAPI    the seam: DeviceSession protocol and value types
Sources/USBKit       IOKit: USB identity, link speed, interface holders, ptpcamerad, sleep
Sources/CLibMTP      C module over the vendored libmtp header
Sources/MTPKit       libmtp wrapper; every call on one dedicated thread
Sources/MockDevice   simulated phone with fault injection
Sources/TransferCore journal (GRDB), batches and folder scans, resumable file transfer,
                     supervisor (reconnect, waits, backoff), name mapping, chained digest
Sources/PulliProtocol  app/helper vocabulary (versioned, Codable)
Sources/PulliClient  XPC client and state reducer (the app's side)
Sources/HelperCore   helper engine: phones, batches, events, XPC server
Sources/WorkerIPC    helper/worker frames, worker connector, stall watchdog
Sources/PulliHost    starts an engine: in the helper, or inside the app; the simulated phone
Sources/Pulli        the SwiftUI app (screens, intro, sounds, menu bar, Settings, snapshots)
Sources/pulli-helper the background helper (LaunchAgent)
Sources/pulli-mtp-worker  one phone's MTP session per process
Helper/              LaunchAgent plist
design/              screen design generator (canvas in Claude Design)
Sources/pulli-cli    developer CLI
Tests/               Swift Testing suites
Vendor/              build-deps.sh, versions.lock (pinned sha256), patches/
scripts/             test.sh, make-app.sh, render-sounds.py, dev-helper.sh
docs/                DECISIONS.md
```

## Third-party code

- **libusb 1.0.30** and **libmtp 1.1.23**, LGPL-2.1-or-later. Linked dynamically and shipped as
  separate dylibs, with their licence texts (`Vendor/out/licenses`). The exact sources are
  listed in `Vendor/versions.lock`.
- **GRDB.swift 7** (MIT), the journal.
- **swift-argument-parser** (Apache 2.0), used only by the developer CLI.
- **Plus Jakarta Sans** (SIL Open Font License 1.1), the app's typeface, bundled with its licence.

## Testing with friends

```sh
scripts/make-app.sh && scripts/make-dmg.sh   # → build/Pulli-<version>-<build>.dmg
build/Pulli.app/Contents/MacOS/Pulli --flyer build   # → build/Pulli-flyer.pdf (one-page flyer)
```

Send the disk image (AirDrop, iCloud Drive or Google Drive link). Testers need a Mac with Apple
silicon and macOS 26 or later. With the Developer ID certificate and the `relay-notary` profile
in place (see "Signing and notarisation"), builds are signed and the disk image is notarised, so
Pulli opens with a double-click. Without them, testers allow it once with **Open Anyway** in
System Settings › Privacy & Security.

## Signing and notarisation

With an Apple Developer account, once:

1. Xcode › Settings › Accounts: add the Apple Account, then Manage Certificates › + ›
   **Developer ID Application**.
2. account.apple.com › Sign-In and Security › App-Specific Passwords: create one.
3. Save it for notarisation (asks for the password; Team ID is on developer.apple.com › Account):

   ```sh
   xcrun notarytool store-credentials relay-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

From then on `scripts/make-app.sh && scripts/make-dmg.sh` signs everything with the Developer ID
and notarises the disk image: it opens on any Mac with a double-click.

## Releasing

Pulli uses Sparkle 2 for auto-updates. The update feed is `appcast.xml` in this repository; the disk
images are attached to this repository's GitHub Releases.

### 1. First-time setup

1. **Sparkle keys:** Generate an EdDSA key pair using Sparkle's `generate_keys` tool (available from Sparkle's SwiftPM artifact).
   The private key is stored in your login Keychain. Back it up with `generate_keys -x <file>` to a
   safe place outside the repository (without it, existing installs cannot receive updates); never commit it.
   Paste the generated public key line into `Config/sparkle-public-key.txt`.
2. **Support email:** Set `PULLI_FEEDBACK_EMAIL="support@yourdomain.com"` in `Config/release.env` (or via environment variable). If left empty, the "Send Feedback…" menu item remains hidden.
3. **Feed:** nothing to set up: `scripts/release.sh` updates `appcast.xml` here, and `--publish`
   creates the GitHub release, then commits and pushes the feed.
4. **Homebrew:** clone `ijahongirmirzo/homebrew-tap` next to this repository (or set
   `PULLI_TAP_DIR`); `--publish` then updates the cask's version and checksum and pushes it.

### 2. Creating a release

1. Raise `short_version` in `scripts/make-app.sh` (each release has its own version: the tag is
   `v<version>` and the download `Pulli-<version>.dmg`), and write the user-facing release notes
   in `release-notes.md`.
2. Run the release script:

   ```sh
   scripts/release.sh
   ```

   This builds a signed Developer ID app and notarised DMG (`PULLI_RELEASE=1`), signs the DMG with `sign_update`, and prepends the new release `<item>` to `appcast.xml`.
3. Review the change to `appcast.xml`, then publish:

   ```sh
   scripts/release.sh --publish
   ```

   (Alternatively, run the `gh release create` and `git push` commands printed at the end of `scripts/release.sh`.)
