# Patches to vendored libraries

`build-deps.sh` applies `patches/<library>/series` (one patch file name per line, `-p1`) after
unpacking each tarball. There are no patches today, by design (see docs/DECISIONS.md, D-007).

Any patch added here must be published with the app to keep the LGPL obligations simple:
the exact sources we ship are the pinned tarball plus these files.
