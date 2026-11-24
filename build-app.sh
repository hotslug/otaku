#!/bin/sh
set -e
cd "$(dirname "$0")"
[ -f Otaku.icns ] || ./make-icon.sh
swift build -c release --arch arm64 --arch x86_64
rm -rf Otaku.app && mkdir -p Otaku.app/Contents/MacOS Otaku.app/Contents/Resources
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Otaku" Otaku.app/Contents/MacOS/
cp Otaku.icns Otaku.app/Contents/Resources/
cat > Otaku.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Otaku</string>
  <key>CFBundleIdentifier</key><string>local.otaku</string>
  <key>CFBundleExecutable</key><string>Otaku</string>
  <key>CFBundleIconFile</key><string>Otaku</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
</dict></plist>
PLIST
codesign -s - --force Otaku.app
echo "Built $(pwd)/Otaku.app"
