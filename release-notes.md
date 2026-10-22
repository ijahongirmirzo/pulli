Two small fixes for smoother copies.

- **A steady speed after a resume.** When a copy carries on after a pulled cable, a pause or a restart, the speed no longer jumps to a silly number for a moment. Pulli now counts only what it has read from the phone since resuming, and shows the speed once it has a real measurement.
- **Real folder dates.** Folders in Pulli's browser now show the date the phone gives them, and anything the phone gives no date shows "-" in Pulli and in Finder, never 1 January 1970.

**Which Macs:** every Mac with Apple silicon - an M1 chip or newer - running macOS 26 Tahoe or later. Intel Macs are not supported.

**Install or update:** Pulli updates itself. New here? Open the disk image and drag Pulli to Applications, or use Homebrew: `brew install --cask ijahongirmirzo/tap/pulli`
