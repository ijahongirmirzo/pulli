# A Mac App Store edition of Pulli

Status: plan, not started. Written 2026-10-14 for the owner's decision.

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

## Suggested order

1. Release the direct-download edition first (it is ready: signed and notarised) and open the
   GitHub repository.
2. Run spike 1. If ImageCaptureCore cannot read ranges or sees too little of the phone, the App
   Store edition becomes "photos and videos only" and says so clearly.
3. Build the App Store edition as a second app target sharing everything but the phone backend.
