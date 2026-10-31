#!/bin/zsh
# Builds Attractors.saver (universal) from ../index.html; pass --install to copy it to ~/Library/Screen Savers
set -euo pipefail
cd "${0:A:h}"

OUT=build/Attractors.saver
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

for arch in arm64 x86_64; do
  # screensaver hosts expect a Mach-O bundle (MH_BUNDLE), not a dylib
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" -module-name Attractors \
    -framework ScreenSaver -framework WebKit -Xlinker -bundle -o "build/Attractors-$arch" AttractorsView.swift
done
lipo -create build/Attractors-arm64 build/Attractors-x86_64 -output "$OUT/Contents/MacOS/Attractors"
rm build/Attractors-arm64 build/Attractors-x86_64

cp Info.plist "$OUT/Contents/Info.plist"
cp ../index.html thumbnail.png thumbnail@2x.png "$OUT/Contents/Resources/"
xattr -cr "$OUT"   # iCloud Drive adds extended attributes that codesign rejects
codesign --force --sign - "$OUT"
echo "Built $PWD/$OUT"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Library/Screen Savers/Attractors.saver"
  mkdir -p "$HOME/Library/Screen Savers"
  rm -rf "$DEST"
  ditto --norsrc --noextattr "$OUT" "$DEST"
  xattr -cr "$DEST" 2>/dev/null || true
  codesign --force --sign - "$DEST"
  # the screensaver host caches loaded bundles; restart it so the new build is used
  killall legacyScreenSaver 2>/dev/null || true
  echo "Installed to $DEST"
fi
