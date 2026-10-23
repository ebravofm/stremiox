#!/usr/bin/env bash
# Remove libVLC's libc compatibility objects that shadow libSystem in the tvOS app.
#
# SwiftVLC ships libVLC as a static library, so its compat replacements for clock_gettime,
# clock_getres, timespec_get and aligned_alloc get linked into the app executable and win over
# libSystem for every other static library in it. stremio-core (Rust) then reads its monotonic
# clock through VLC's clock_gettime, which only knows the realtime and monotonic clocks, gets
# EINVAL for CLOCK_UPTIME_RAW and panics at startup ("Loading library" forever). tvOS has all
# four natively, so the compat objects are dropped from the archive before the build links it.
#
# Usage: patch-libvlc.sh <xcodeproj> <scheme> <derivedDataPath>
set -euo pipefail

project="$1" scheme="$2" derived="$3"

xcodebuild -project "$project" -scheme "$scheme" -derivedDataPath "$derived" \
  -resolvePackageDependencies >/dev/null

found=0
while IFS= read -r archive; do
  found=1
  xcrun ar d "$archive" clock_gettime.o clock_getres.o timespec_get.o aligned_alloc.o 2>/dev/null || true
  xcrun ranlib "$archive"
  if nm -g -U "$archive" 2>/dev/null | grep -qE ' T _(clock_gettime|clock_getres|timespec_get|aligned_alloc)$'; then
    echo "::error::libVLC compat symbols still defined in $archive"
    exit 1
  fi
  echo "patched $archive"
done < <(find "$derived/SourcePackages/artifacts" -path '*libvlc.xcframework*' -name 'libvlc.a')

if [ "$found" = 0 ]; then
  echo "::error::libvlc.a not found under $derived/SourcePackages/artifacts"
  exit 1
fi
