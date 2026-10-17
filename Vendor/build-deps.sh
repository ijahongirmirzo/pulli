#!/bin/bash
# Builds libusb and libmtp from pinned release tarballs as dynamic libraries.
#
# Output (Vendor/out):
#   include/libmtp.h, include/libusb-1.0/libusb.h
#   lib/libusb-1.0.0.dylib, lib/libmtp.9.dylib   (universal or single-arch, install names @rpath/...)
#   licenses/                                     (LGPL texts to bundle in the app)
#
# Usage: Vendor/build-deps.sh [--archs "arm64 x86_64"] [--clean]
#
# Both are LGPL-2.1+, so they are linked dynamically and shipped as separate dylibs.
# See docs/DECISIONS.md (D-003) for why we build them ourselves.

set -euo pipefail

# Physical path (no symlinks): the compiler and linker record real paths, and the prefix maps
# below must match them.
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CACHE_DIR="$VENDOR_DIR/cache"
BUILD_DIR="$VENDOR_DIR/build"
OUT_DIR="$VENDOR_DIR/out"
PATCH_DIR="$VENDOR_DIR/patches"

ARCHS="arm64 x86_64"
CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archs) ARCHS="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

export MACOSX_DEPLOYMENT_TARGET=26.0
# Reproducibility: fixed timestamps in archives, no build paths in debug info.
export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH=1767225600
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# libtool probes the max command length with sysctl; if that is unavailable (sandboxed shells)
# it falls back to incremental `ld -r` links, which turn hidden symbols into locals and break
# libusb. Pin a sane value so the link is the same everywhere.
export lt_cv_sys_max_cmd_len=262144
# The same install prefix for every checkout. The linker writes it into the install names, and a
# longer name moves the code after the load commands, so a prefix inside the checkout made the
# bytes depend on the checkout's folder. The prefix exists nowhere: `make install DESTDIR=...`
# puts the files under Vendor/build/<arch>/stage, and the install names become @rpath below.
PREFIX=/relay-vendor

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

lock_field() { # lock_field <name> <column 2..4>
  awk -v n="$1" -v c="$2" '$1 == n { print $c }' "$VENDOR_DIR/versions.lock"
}

fetch() { # fetch <name> -> prints tarball path
  local name="$1" version url sha file actual
  version="$(lock_field "$name" 2)"
  url="$(lock_field "$name" 3)"
  sha="$(lock_field "$name" 4)"
  file="$CACHE_DIR/$(basename "$url")"
  mkdir -p "$CACHE_DIR"
  if [[ ! -f "$file" ]]; then
    log "Downloading $name $version" >&2
    curl -fsSL --retry 3 -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "checksum mismatch for $file: expected $sha, got $actual" >&2
    exit 1
  fi
  echo "$file"
}

unpack() { # unpack <tarball> <dest dir> <name>
  local tarball="$1" dest="$2" name="$3"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xf "$tarball" -C "$dest" --strip-components 1
  if [[ -f "$PATCH_DIR/$name/series" ]]; then
    while read -r patch; do
      [[ -z "$patch" || "$patch" == \#* ]] && continue
      log "Applying $name/$patch"
      patch -d "$dest" -p1 --forward < "$PATCH_DIR/$name/$patch"
    done < "$PATCH_DIR/$name/series"
  fi
}

host_triple() {
  case "$1" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "unsupported arch $1" >&2; exit 2 ;;
  esac
}

build_arch() { # build_arch <arch>
  local arch="$1" stage="$BUILD_DIR/$arch/stage" src
  local cflags="-arch $arch -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2 -g"
  cflags+=" -ffile-prefix-map=$BUILD_DIR/$arch/src=. -ffile-prefix-map=$stage=."
  local ldflags="-arch $arch -isysroot $SDKROOT -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wl,-headerpad_max_install_names"
  # The debug map names each object file; without this it holds the checkout's absolute path.
  ldflags+=" -Wl,-oso_prefix,$BUILD_DIR/$arch/src/"

  # Only our own staged libusb is visible to pkg-config, so a Homebrew libusb can never leak in.
  export PKG_CONFIG_LIBDIR="$stage$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_SYSROOT_DIR="$stage"

  log "libusb for $arch"
  src="$BUILD_DIR/$arch/src/libusb"
  unpack "$LIBUSB_TARBALL" "$src" libusb
  # configure's link test finds pipe2 in the SDK, but it exists only from macOS 27. With our 26.0
  # target it would be weakly imported and NULL on macOS 26, where libusb_init calls it. Without
  # it libusb uses pipe and sets FD_CLOEXEC with fcntl.
  (cd "$src" && CC=clang CFLAGS="$cflags" LDFLAGS="$ldflags" ac_cv_func_pipe2=no ./configure \
      --host="$(host_triple "$arch")" --prefix="$PREFIX" \
      --enable-shared --disable-static --disable-dependency-tracking --disable-silent-rules \
      > "$BUILD_DIR/$arch/libusb-configure.log" \
    && make -j"$JOBS" > "$BUILD_DIR/$arch/libusb-make.log" \
    && make install DESTDIR="$stage" > "$BUILD_DIR/$arch/libusb-install.log" 2>&1)
  # The install logs catch libtool's warning that nothing is in $PREFIX, which is on purpose.
  # libusb's libtool archive points at $PREFIX too. Without it, libmtp links the staged libusb as
  # a plain library.
  rm -f "$stage$PREFIX/lib/"*.la

  log "libmtp for $arch"
  src="$BUILD_DIR/$arch/src/libmtp"
  unpack "$LIBMTP_TARBALL" "$src" libmtp
  # Only src/ is installed: the library and libmtp.h. The example programs are not needed.
  (cd "$src" && CC=clang CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
      --host="$(host_triple "$arch")" --prefix="$PREFIX" \
      --enable-shared --disable-static --disable-dependency-tracking --disable-silent-rules \
      --disable-mtpz --disable-doxygen --disable-rpath \
      > "$BUILD_DIR/$arch/libmtp-configure.log" \
    && make -j"$JOBS" > "$BUILD_DIR/$arch/libmtp-make.log" \
    && make -C src install DESTDIR="$stage" > "$BUILD_DIR/$arch/libmtp-install.log" 2>&1)
}

[[ $CLEAN == 1 ]] && rm -rf "$BUILD_DIR" "$OUT_DIR"

LIBUSB_TARBALL="$(fetch libusb)"
LIBMTP_TARBALL="$(fetch libmtp)"

for arch in $ARCHS; do build_arch "$arch"; done

log "Assembling $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/lib" "$OUT_DIR/include" "$OUT_DIR/licenses"
first_arch="${ARCHS%% *}"
cp "$BUILD_DIR/$first_arch/stage$PREFIX/include/libmtp.h" "$OUT_DIR/include/"
cp -R "$BUILD_DIR/$first_arch/stage$PREFIX/include/libusb-1.0" "$OUT_DIR/include/"

for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
  inputs=()
  for arch in $ARCHS; do inputs+=("$BUILD_DIR/$arch/stage$PREFIX/lib/$lib"); done
  lipo -create "${inputs[@]}" -output "$OUT_DIR/lib/$lib"
done

# Install names: everything is found through the loader's @rpath, both in dev builds
# (rpath points at Vendor/out/lib) and in the app bundle (Contents/Frameworks).
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$OUT_DIR/lib/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libmtp.9.dylib" "$OUT_DIR/lib/libmtp.9.dylib"
install_name_tool -change "$PREFIX/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" \
  "$OUT_DIR/lib/libmtp.9.dylib"
if otool -L "$OUT_DIR/lib/libmtp.9.dylib" | grep -q -F -e $'\t'"$PREFIX/" -e $'\t'"$BUILD_DIR/"; then
  echo "libmtp still references a build path:" >&2
  otool -L "$OUT_DIR/lib/libmtp.9.dylib" >&2
  exit 1
fi
# A weak import is a function the SDK has but our oldest supported macOS may lack. There it is
# NULL, and calling it crashes (docs/DECISIONS.md, D-028).
for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
  if nm -m -arch all "$OUT_DIR/lib/$lib" | grep '(undefined) weak' >&2; then
    echo "$lib imports the functions above weakly: they may be missing on macOS $MACOSX_DEPLOYMENT_TARGET" >&2
    rm -rf "$OUT_DIR"  # so nothing links or bundles it by mistake
    exit 1
  fi
done
# install_name_tool invalidates the linker's ad-hoc signature; re-sign ad hoc for local use.
# Release signing (scripts/sign.sh) replaces this with the Developer ID signature.
codesign --force --sign - "$OUT_DIR/lib/libusb-1.0.0.dylib" "$OUT_DIR/lib/libmtp.9.dylib" 2>/dev/null

ln -sf libusb-1.0.0.dylib "$OUT_DIR/lib/libusb-1.0.dylib"
ln -sf libmtp.9.dylib "$OUT_DIR/lib/libmtp.dylib"

cp "$BUILD_DIR/$first_arch/src/libusb/COPYING" "$OUT_DIR/licenses/libusb-COPYING.txt"
cp "$BUILD_DIR/$first_arch/src/libmtp/COPYING" "$OUT_DIR/licenses/libmtp-COPYING.txt"
cp "$VENDOR_DIR/versions.lock" "$OUT_DIR/licenses/SOURCES.txt"

log "Done"
for lib in "$OUT_DIR"/lib/*.*.dylib; do
  printf '  %s: %s\n' "$(basename "$lib")" "$(lipo -archs "$lib")"
done
otool -L "$OUT_DIR/lib/libmtp.9.dylib" | sed 's/^/  /'
