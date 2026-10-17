# Contributing to Pulli

Thanks for helping. A few things make changes easy to accept.

## Before you start

- Open an issue first for anything larger than a fix, so we can agree on the approach.
- Read [docs/DECISIONS.md](docs/DECISIONS.md): most "why is it done this way?" questions are
  answered there (the worker process per phone, the journal, the resume rules).

## Building

```bash
Vendor/build-deps.sh       # libusb + libmtp from pinned sources (once)
swift build && swift test  # the packages and their tests
scripts/make-app.sh        # build/Pulli.app (signed with a Developer ID if one is in your keychain)
build/Pulli.app/Contents/MacOS/Pulli --mock   # the app with a simulated phone
```

`Pulli --snapshot DIR` renders every screen to PNGs (dark and light) without a phone; use it to
check UI changes.

## Changes

- Keep the style of the code around you: short doc comments that say why, British spelling in UI
  text and comments, no new dependencies without discussing them first.
- Add a test for every fix (the simulated phone in `Sources/MockDevice` can inject faults:
  disconnects, stalls, short reads).
- Anything that touches copying must keep the guarantee: nothing copied is ever lost, and a resumed
  file is byte-identical to the phone's.
- Never delete or rename files on a real phone while testing, except a clearly named test file.

## Reporting bugs

Include the phone model, macOS version, what you did, and the activity log (Window › Activity Log).

## Licensing of contributions

Pulli is licensed under the GNU GPL v3 or later (see [LICENSE](LICENSE) and [NOTICE](NOTICE));
`Packages/FinderLocations` is licensed under the Apache License 2.0. By sending a contribution you
agree that:

- it is your own work (or you have the right to submit it), and it is licensed under the same
  licence as the part of the project it changes; and
- the project's author, Jakhongirmirzo Ibrokhimov, may also distribute it as part of Pulli under
  other terms, such as through the Mac App Store, whose terms the GPL does not allow on its own.

Sign off each commit to confirm this (`git commit -s` adds a `Signed-off-by:` line).
