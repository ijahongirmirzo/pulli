# Device matrix

What each tested phone supports and how it behaves. Filled in from `docs/phase1-device-test.md`.

| | Samsung Galaxy Z Fold7 (SM-F966B) | Google Pixel | Other |
|---|---|---|---|
| Firmware | F966BXXSCBZH3 | untested | |
| USB vendor:product | 04e8:6860 | | |
| libmtp device flags | UNLOAD_DRIVER, LONG_TIMEOUT, PROPLIST_OVERRIDES_OI, SAMSUNG_OFFSET_BUG (no FORCE_RESET_ON_CLOSE) | | |
| Vendor extensions | microsoft.com 1.0, samsung.com/kies 6.0, samsung.com/devicestatus (no android.com) | | |
| Advertises 0x95C1 (GetPartialObject64) | yes (also 0x101B, 0x95C2-0x95C5) | | |
| `readStrategy` detected | partial64 | | |
| USB serial vs MTP serial | differ (MTP serial is a random 32-hex id) | | |
| Link speed (cable/port used) | USB 2, 480 Mb/s, both through the monitor's USB 2.1 hub and on a direct Mac port with a Thunderbolt cable (phone reports bcdUSB 0x0210). Spec sheet: USB Type-C 3.2 | | |
| ptpcamerad grabs on plug-in | yes, `UsbExclusiveOwner = "pid N, ptpcamerad"` on the MTP interface; released without admin rights; respawns on the next camera request | | |
| Clean close resets USB | no | | |
| Unclean end (kill -9 mid-read) | phone keeps sending the rest of the chunk; OpenSession fails; libmtp's fallback USB reset makes the phone hide storage until unlocked. Fixed by MTPQuiesce (D-016) | | |
| PTP Get Device Status (0x67) | no answer after an interrupted read | | |
| Bulk-read timeout (libusb aborts pipe, clears halt) | phone drops off the USB bus; must be replugged | | |
| `ls /DCIM/Camera` | 74 files, 1.83 GB: 0.34 s (~4.5 ms per file) | | |
| Throughput by chunk (read only, 256 MB) | 4 MiB 31.1, 8 MiB 31.8, 16 MiB 31.4, 32 MiB 29.7, 64 MiB 25.7 MB/s | | |
| Slowest single read by chunk | 4 MiB 0.15 s, 8 MiB 0.28 s, 32 MiB 1.2 s, 64 MiB 2.8 s | | |
| Copy to disk (32 MiB chunks) | 30.1 MB/s | | |
| Kills survived / byte-identical | 3 of 3, SHA-256 identical to an uninterrupted copy, date preserved | | |
| Worker process (pulli-mtp-worker) | 162 MB at 29.3 MB/s; worker killed twice mid-copy, recovered by itself, byte-identical; Camera folder 74 files / 1.83 GB in 63 s (28.8 MB/s) | | |
| Cable pulls survived | not yet tested (needs the owner) | | |
| Notes | storage hidden after any USB reset until the phone is unlocked | | |
