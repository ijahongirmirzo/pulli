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
| Transferring images (PTP) | **772 items, 6.01 GB**: 749 images, 21 videos, 2 other — camera photos and videos, screenshots, images saved by messaging apps — as one flat list; each file knows its folder (`DCIM/Camera/…`) |

- **Ranged reads work:** 4 MB from the middle of a 385 MB video in 137 ms.
- **Speed:** 36.6 MB/s with 4–16 MiB reads (1 MiB: 30.7 MB/s) — faster than libmtp on the same cable (about 29 MB/s).
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

## Suggested order

1. Release the direct-download edition first (it is ready: signed and notarised) and open the
   GitHub repository.
2. Run spike 1. If ImageCaptureCore cannot read ranges or sees too little of the phone, the App
   Store edition becomes "photos and videos only" and says so clearly.
3. Build the App Store edition as a second app target sharing everything but the phone backend.
