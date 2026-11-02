Steadier big copies, after a real test of almost 48 GB from an SD card. Thanks to @ilkerorbay for the detailed report.

- **Memory stays flat.** On long copies Pulli kept copied data in memory, which could fill your Mac's memory. It now stays flat however much you copy.
- **Fewer false alarms.** A file could be reported as "no longer on the phone" when the phone was only slow to answer. Pulli now checks again before saying so.
- **Pausing is not a failure.** Pausing during a read no longer counts as a failed read, so it no longer leads to a suggestion to use smaller chunks.
- **Starting a copy recovers by itself.** If the connection to the phone has just dropped, Pulli reconnects and tries once more before showing an error.
- **Try Again is easier to find.** When files need attention, the button is now on the finished screen too.

**Which Macs:** every Mac with Apple silicon - an M1 chip or newer - running macOS 26 Tahoe or later. Intel Macs are not supported.

**Install or update:** Pulli updates itself. New here? Open the disk image and drag Pulli to Applications, or use Homebrew: `brew install --cask ijahongirmirzo/tap/pulli`
