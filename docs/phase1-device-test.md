# Phase 1 device test (Samsung Galaxy)

The Phase 1 acceptance test: pull the cable mid-transfer, plug it back in, and the copy resumes
from the committed offset and produces a byte-identical file. Each step prints what we need to
record in [device-matrix.md](device-matrix.md).

## 0. Build

```bash
Vendor/build-deps.sh
swift build
```

Every command below is `.build/debug/pulli-cli …`.

## 1. Connection (contention and modes)

1. Plug the phone in, unlocked. On the phone choose **USB → File transfer**.
2. `pulli-cli doctor`: records the USB link speed, the MTP interface, and who holds it.
3. `pulli-cli info --dump > info.txt`. We need:
   - `reads`: we expect `partial64`.
   - The dump's supported-operations list: look for `0x95c1` (GetPartialObject64). This confirms or corrects the `partial64` heuristic.
4. Open **Photos** or **Image Capture**, then `pulli-cli info` again. Expect the line "Released the phone from macOS's camera service". This is the ptpcamerad path in D-008.
5. With Photos still open, run `pulli-cli info` twice more, 10 s apart. This tests whether ptpcamerad re-grabs the phone while we hold a session.

## 2. Listing

```bash
pulli-cli ls /DCIM/Camera --summary
```

Record the entry count, total time, and "first page after". This measures the per-file metadata
cost on Samsung.

## 3. Resumable copy: cable pull (the acceptance test)

Pick a big file, at least 5 GB. A long video works, or record one, or copy a large file to the phone first.

```bash
pulli-cli copy /DCIM/Camera/<big file> ~/Desktop/relay-test
```

1. At about 20%, **pull the cable**. Expect: "Phone disconnected. Plug it back in…".
2. Wait 10 s and plug it back in. Samsung usually falls back to "Charging only"; choose **File transfer** again. Expect "Resuming … from <offset>", and the copy continues.
3. Repeat 5 times at different points.
4. Also 5 times: press **Ctrl-C** (or `kill -9` the process from another terminal) and re-run the same command. This is the "helper killed" case.
5. Once, lock the phone mid-transfer and leave it locked for 2 minutes, then unlock it.

## 3b. Whole folder

```bash
pulli-cli copy /DCIM/Camera ~/Desktop/relay-folder-test
```

Pull the cable once during the scan and once during the copy. Check that:
- it resumes both times;
- the folder structure matches the phone;
- `pulli-cli batches` lists the batch as completed;
- `pulli-cli batches <id>` shows any files that need attention and any renamed names.

Then take one new photo and run the same command again: only the new photo should be copied.

## 4. Verify

Copy the same file with another route (Finder via Android File Transfer, OpenMTP, or `adb pull`)
to `~/Desktop/reference/`, then:

```bash
shasum -a 256 ~/Desktop/relay-test/<file> ~/Desktop/reference/<file>
```

The two hashes must match. Also check the file's modification date matches the phone's.

## 5. Chunk size

```bash
pulli-cli bench /DCIM/Camera/<big file> --mib 1024
```

Run it once on a USB 3 cable and port, and once on USB 2 if you have one.

## What to send back

The terminal output of steps 1–5, the `info.txt` dump, and anything that surprised you.
