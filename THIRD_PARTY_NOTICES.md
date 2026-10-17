# Third-party notices

Pulli is built with the following third-party code. Each keeps its own licence; the full texts
are bundled in the app at `Pulli.app/Contents/Resources/Licenses/`.

| Component | Version | Licence | Used for | How it is included |
|---|---|---|---|---|
| [libmtp](https://github.com/libmtp/libmtp) | 1.1.23 | LGPL 2.1 or later | Talking MTP to the phone | Dynamically linked (`Contents/Frameworks/libmtp.9.dylib`), built from the pinned source in `Vendor/versions.lock` |
| [libusb](https://github.com/libusb/libusb) | 1.0.30 | LGPL 2.1 or later | USB access for libmtp | Dynamically linked (`Contents/Frameworks/libusb-1.0.0.dylib`), built from pinned source |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT | Automatic updates | Embedded framework (`Contents/Frameworks/Sparkle.framework`) |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | The transfer journal (SQLite) | Swift package |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache 2.0 | `pulli-cli` only (not in the app) | Swift package |
| [Plus Jakarta Sans](https://github.com/tokotype/PlusJakartaSans) | — | SIL Open Font Licence 1.1 | The app's typeface | Bundled font (`Sources/Pulli/Resources/Fonts`) |
| [dmgbuild](https://github.com/dmgbuild/dmgbuild) | latest | MIT | Building the disk image (build tool only) | Installed into `build/tools` by `scripts/make-dmg.sh`; not shipped |

## LGPL (libmtp, libusb)

Both libraries are linked dynamically and shipped as separate dylibs, unmodified, so they can be
replaced. Their exact sources are pinned with checksums in `Vendor/versions.lock` and rebuilt by
`Vendor/build-deps.sh`; Pulli's own source is in this repository, so anyone can rebuild Pulli
against a modified libmtp or libusb.
