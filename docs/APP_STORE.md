# A Mac App Store edition of Pulli

Status: spike 1 done (2026-10-17, see results below); the owner decided to publish on the App Store.
Stage 1, the ImageCaptureCore phone backend, is built and waits for a test on a phone (see below).

## The short answer

The Mac App Store requires the **App Sandbox**. Several of the things that make Pulli reliable
today are not allowed inside it. The realistic path is **two editions from one codebase**:

| | Direct download (GitHub releases, notarised DMG) | Mac App Store |
|---|---|---|
| Phone access | libmtp in a worker process (today's design) | **ImageCaptureCore** (Apple's framework, through macOS's own camera service) |
| What it can copy | Every file and folder on the phone | Photos and videos the phone exposes to Image Capture (to be confirmed: see spike 1) |
| Resume after a cable pull | Yes, from the exact byte | Likely yes: `ICCameraFile.requestReadData(atOffset:length:)` reads ranges (spike 1) |
| Phone in Finder | Yes (local WebDAV drive) | Later, as a File Provider extension (spike 3) |
| Copy from Mac to phone, delete, rename | Yes | Probably not (Image Capture is read-mostly) |
| LGPL libraries | Bundled as dylibs | **None**: libmtp and libusb are not in this edition |

Everything above the phone layer (the journal and resume engine, the UI, the storage map, Free Up
Space's verification, Porcelain, the menu bar, widget and Shortcuts) is shared. The code already
has the seam for this: every phone backend is a `DeviceConnector` / `DeviceSession`
(`Sources/DeviceAPI`), and the engine only talks to those.

## What the sandbox rules out, and what replaces it

| Today | Sandbox problem | App Store replacement |
|---|---|---|
| Stopping macOS's camera service (`ptpcamerad`) so libmtp can claim the phone | A sandboxed app cannot signal other processes | Use ImageCaptureCore, which goes *through* that service instead of fighting it |
| libmtp + libusb claiming the USB interface | Possible with the `com.apple.security.device.usb` entitlement, but the camera service still holds the phone (above), and LGPL in the store is a legal grey area | Not shipped in this edition |
| A worker process per phone, killed when a read hangs | Child processes are allowed (they inherit the sandbox) | Not needed: ImageCaptureCore calls can be cancelled; keep a watchdog that closes the session |
| Background helper (LaunchAgent via `SMAppService`) | Allowed if the helper is sandboxed too, with an app group for XPC | Keep, sandboxed, with an app group |
| Mounting the phone with `mount_webdav` | Running `/sbin` tools is not allowed | File Provider extension (`NSFileProviderReplicatedExtension`): the phone appears under Locations in Finder |
| Writing copies anywhere | Only places the user chose, or entitled folders | Default to **Downloads** (`com.apple.security.files.downloads.read-write`); other folders via the open panel and a security-scoped bookmark |
| Finding duplicates in Pictures | Needs access | `com.apple.security.assets.pictures.read-only` |
| Widget reading the app's state | Needs a shared container | App group shared by app, helper and widget |
| `pulli-cli` | Not part of the app | Not shipped |

## Licence

If the code is published under a licence that conflicts with the App Store terms (GPL-3.0, for
example; VLC was removed from the App Store over this), the owner can still ship it there, since
they hold the copyright, but contributors' code would need a contributor agreement. A permissive
licence (MIT or Apache 2.0) avoids the question. The App Store edition ships no LGPL code.

## Spikes before deciding (each a few days, needs a real phone)

1. **ImageCaptureCore with Android phones.** List a Galaxy's and the Lenovo's files with
   `ICDeviceBrowser`; which folders appear in "File transfer" and "Transferring images" modes;
   do ranged reads (`requestReadData(atOffset:length:)`) work, and how fast; what happens on a
   cable pull mid-read. Built: `pulli-cli icc` (2026-10-14), not yet run on a phone:

   ```sh
   swift build --product pulli-cli
   R=$(swift build --show-bin-path)/pulli-cli
   $R icc list --depth 3                              # what ImageCaptureCore sees
   $R icc read DCIM/Camera/<photo>.jpg --offset 1000000 --length 65536   # a ranged read
   $R icc bench DCIM/Camera/<video>.mp4               # speed per chunk size
   $R icc pull DCIM/Camera/<video>.mp4 ~/Desktop      # resumable copy; pull the cable, run again
   ```

   Quit Pulli first: only one app at a time can talk to the phone.
2. **The sandboxed build.** The app, helper and widget with the entitlements above, the journal in
   the app group container, copying into Downloads and into a bookmarked folder.
3. **File Provider extension.** A read-only phone location in Finder backed by the same session.

## Spike 1 results (2026-10-17, Samsung Galaxy Z Fold7, USB 2, macOS 27)

Run with `pulli-cli icc` while Pulli was quit, through macOS's camera service (nothing stopped).

| Phone USB mode | What ImageCaptureCore sees |
|---|---|
| File transfer (MTP) | The phone, but **no files** (an empty, complete catalogue) |
| Transferring images (PTP) | **772 items, 6.01 GB**: 749 images, 21 videos, 2 other - camera photos and videos, screenshots, images saved by messaging apps - as one flat list; each file knows its folder (`DCIM/Camera/…`) |

- **Ranged reads work:** 4 MB from the middle of a 385 MB video in 137 ms.
- **Speed:** 36.6 MB/s with 4-16 MiB reads (1 MiB: 30.7 MB/s) - faster than libmtp on the same cable (about 29 MB/s).
- **Resume works:** a copy killed at 147 MB continued from there; the result matched the
  chained SHA-256 recorded for the same file by an earlier libmtp copy.
- Not visible: documents, Downloads, other folders; copying to the phone and deleting need
  testing (`ICCameraDeviceCanDeleteOneFile` is reported).

**Conclusion:** the App Store edition is viable as **"photos and videos"**: it asks the user to
choose "Transferring images" on the phone, and gets resumable, checked copies at full speed. The
direct-download edition stays the full-phone tool.

## Stage 1: the ImageCaptureCore phone backend (2026-10-17)

The phone layer only; no UI, sandbox or packaging changes yet.

- **`ICCKit`** (depends on DeviceAPI only): `ICCDeviceWatcher` (cameras from one shared
  `ICDeviceBrowser`, USB only, iPhones left out), `ICCDeviceConnector` and `ICCSession`, a
  `DeviceSession` with one storage, "Photos and videos", whose folders (`DCIM/Camera`,
  `Pictures/Screenshots`, …) are synthesised from Image Capture's flat catalogue
  (`ICCFolderIndex`, pure and tested). Reads are ranged (at most 16 MiB, short reads allowed), so
  copies resume from the last commit like libmtp's. Writing, deleting and renaming throw
  `.unsupported`.
- **Identity:** the USB serial when Image Capture reports one (the same `DeviceKey` as libmtp
  gives), otherwise Image Capture's persistent ID (`DeviceKey.Kind.imageCapture`, `icc:…`). The
  storage ID (`0x1CC00001`) differs from MTP's, so a batch started over one backend is never
  resumed over the other.
- **Errors:** phone removed or session closed suddenly → `.deviceGone`; empty catalogue (the
  phone is in "File transfer" mode) → `.noStorage`, with `ICCGuidance.chooseTransferringImages`
  for the user; timeouts and busy phones → `.transient`; a read that gets no answer in 30 s counts
  as a stall (`.transient`).
- `DeviceWatcher` and `DeviceCandidate` moved from HelperCore to DeviceAPI, so backends do not
  depend on the helper.
- **Choosing it:** `PULLI_PHONE_BACKEND=icc` for the helper and the in-app engine (libmtp stays
  the default); `--backend icc` for `pulli-cli ls` and `pulli-cli copy`.

To try it (quit Pulli first; on the phone choose "Transferring images"):

```sh
swift build --product pulli-cli
R=$(swift build --show-bin-path)/pulli-cli
$R ls --backend icc /                        # the synthesised folders
$R ls --backend icc /DCIM/Camera
$R copy --backend icc /DCIM/Camera ~/Desktop/ICC-test   # pull the cable mid-copy, plug back in
$R copy --backend icc /DCIM/Camera ~/Desktop/ICC-test   # or Ctrl-C and run again: it resumes
$R batches                                   # the journal's view
```

Still to check on a phone: whether Image Capture reports the USB serial, whether paths carry a
storage-root folder, files over 4 GiB (offsets above 32 bits), and how the dates compare with
libmtp's for the same files.

## Stage 2: the sandboxed build (2026-10-17)

A second build of Pulli for the Mac App Store, compiled with `-DPULLI_APP_STORE` from the same
source tree without modifying direct-download builds.

### How to build and test locally

Compile and assemble the developer test build:

```sh
# Build the App Store release bundle (signed with Developer ID for testing on this Mac)
scripts/make-appstore.sh --dev
```

Inspect entitlements:

```sh
codesign -d --entitlements - build/AppStore/Pulli.app
```

Verify that no un-entitled daemons or third-party dylibs are present:

```sh
find build/AppStore/Pulli.app -type f
otool -L build/AppStore/Pulli.app/Contents/MacOS/Pulli
```

### What differs from the direct download build

| Feature / Detail | Direct download | App Store edition (`PULLI_APP_STORE`) |
|---|---|---|
| **Bundle ID & Group** | `app.pulli.mac`, `8Q2D6948R4.app.pulli.mac` | `app.pulli.store`, `8Q2D6948R4.app.pulli.store` |
| **Widget ID** | `app.pulli.mac.widget` | `app.pulli.store.widget` |
| **File Provider ID** | `app.pulli.mac.fileprovider` | `app.pulli.store.fileprovider` |
| **Phone Access** | libmtp/libusb worker processes | ImageCaptureCore (`ICCKit`) in-process |
| **Engine Host** | Background LaunchAgent helper or embedded | In-process embedded engine (`EmbeddedEngine`) |
| **Dylibs & Daemons** | Bundles libmtp, libusb, Sparkle, worker, helper | Zero third-party dylibs, worker and helper omitted |
| **Phone Mode Guidance** | Prompts for "File transfer" | Prompts for "Transferring images" (PTP) |
| **Default Destination** | `~/Downloads/<phone name>` | `~/Downloads/Pulli` (sandboxed Downloads entitlement) |
| **Custom Destination** | Plain filesystem path | Security-scoped bookmark accessed during copies and Finder reveal |
| **Duplicate Detection** | Reads destination and `~/Pictures` | Reads destination (bookmark) and `~/Pictures` (entitled) |
| **Updates** | Sparkle framework and in-app update checks | Managed by the Mac App Store; Sparkle stripped |
| **Omitted Features** | Full filesystem access | No Mac-to-phone copying (drag/paste/Add), no phone deletion / Free Up Space, no storage map, no legacy migration |
| **Privacy Manifest** | None | `PrivacyInfo.xcprivacy` with reasons for UserDefaults, timestamps, and disk space |

### Owner's checklist for Stage 3 (App Store Connect submission)

1. **Certificates in Keychain (macOS):**
   - Create an **Apple Distribution** certificate on developer.apple.com and install it in Keychain.
   - Create a **Mac Installer Distribution** (or 3rd Party Mac Developer Installer) certificate and install it in Keychain.
2. **Identifiers on developer.apple.com:**
   - Create App ID `app.pulli.store`, App ID `app.pulli.store.widget` and App ID
     `app.pulli.store.fileprovider` (Certificates, Identifiers & Profiles › Identifiers › +).
   - The App Group `8Q2D6948R4.app.pulli.store` starts with the team ID, which macOS accepts
     without registering it (the portal only registers `group.` names), so there is nothing to
     create for it. If a profile is refused over the group, register `group.app.pulli.store`
     and tell the assistant to switch the build to it.
3. **Provisioning Profiles:**
   - Generate three Mac App Store provisioning profiles and place them in `Config/AppStore/profiles/`:
     - `Config/AppStore/profiles/app.pulli.store.provisionprofile`
     - `Config/AppStore/profiles/app.pulli.store.widget.provisionprofile`
     - `Config/AppStore/profiles/app.pulli.store.fileprovider.provisionprofile`
4. **App Store Connect App Record** (only possible on the website):
   - App Store Connect › Apps › + › New App: platform macOS, name "Pulli - Phone Photos to
     Mac", bundle ID `app.pulli.store`, SKU `pulli-store`. The listing text, privacy answers and
     screenshots are ready in docs/APP_STORE_LISTING.md (on main) and
     docs/appstore-screenshots/.
   - Optional but fastest: App Store Connect › Users and Access › Integrations › create an API
     key (role App Manager) and put the .p8 file in ~/.appstoreconnect/private_keys/, so the
     assistant can upload builds and fill in the listing for you.
5. **Package and Upload:**
   - Run:
     ```sh
     scripts/make-appstore.sh --store
     ```
     This produces `build/AppStore/Pulli.pkg`.
   - Upload using Transporter or CLI:
     ```sh
     xcrun altool --upload-package build/AppStore/Pulli.pkg --type osx --apiKey <API_KEY> --apiIssuer <ISSUER_ID>
     ```
