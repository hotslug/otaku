#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -q
rm -rf Otaku.iconset && mkdir Otaku.iconset
OTAKU_ICON=Otaku.iconset/icon_512x512@2x.png .build/debug/Otaku
for s in 16 32 128 256 512; do
  sips -z $s $s Otaku.iconset/icon_512x512@2x.png --out Otaku.iconset/icon_${s}x${s}.png >/dev/null
  [ $s = 512 ] || sips -z $((s * 2)) $((s * 2)) Otaku.iconset/icon_512x512@2x.png --out Otaku.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns Otaku.iconset -o Otaku.icns
rm -rf Otaku.iconset
echo "Built $(pwd)/Otaku.icns"
