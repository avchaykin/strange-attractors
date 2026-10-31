#!/bin/zsh
# Builds Attractors.app (universal) from ../index.html; pass --install to copy it to /Applications
set -euo pipefail
cd "${0:A:h}"

OUT=build/Attractors.app
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -module-name Attractors \
    -framework AppKit -framework WebKit -framework ServiceManagement \
    -o "build/Attractors-$arch" AttractorsApp.swift
done
lipo -create build/Attractors-arm64 build/Attractors-x86_64 -output "$OUT/Contents/MacOS/Attractors"
rm build/Attractors-arm64 build/Attractors-x86_64

cp Info.plist "$OUT/Contents/Info.plist"
cp ../index.html "$OUT/Contents/Resources/index.html"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
xattr -cr "$OUT"   # iCloud Drive adds extended attributes that codesign rejects
codesign --force --sign - "$OUT"
echo "Built $PWD/$OUT"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications/Attractors.app
  [[ -w /Applications ]] || DEST="$HOME/Applications/Attractors.app"
  mkdir -p "${DEST:h}"
  pkill -x Attractors 2>/dev/null || true
  rm -rf "$DEST"
  ditto --norsrc --noextattr "$OUT" "$DEST"
  codesign --force --sign - "$DEST"
  echo "Installed to $DEST"
fi
