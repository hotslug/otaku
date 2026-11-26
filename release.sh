#!/bin/sh
set -e
cd "$(dirname "$0")"
./build-app.sh
rm -rf .dmg Otaku.dmg && mkdir .dmg
cp -R Otaku.app .dmg/ && ln -s /Applications .dmg/Applications
cp Otaku.icns .dmg/.VolumeIcon.icns
mkdir .dmg/.background
OTAKU_DMG_BG=.dmg/.background Otaku.app/Contents/MacOS/Otaku
tiffutil -cathidpicheck .dmg/.background/bg.png .dmg/.background/bg@2x.png -out .dmg/.background/bg.tiff 2>/dev/null
rm .dmg/.background/bg*.png
hdiutil create -volname Otaku -srcfolder .dmg -format UDRW -o .rw.dmg -quiet
[ -d /Volumes/Otaku ] && hdiutil detach /Volumes/Otaku -quiet
hdiutil attach .rw.dmg -quiet
osascript <<'EOS'
tell application "Finder"
  tell disk "Otaku"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set pathbar visible of container window to false
    end try
    set bounds of container window to {200, 120, 860, 548}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set extension hidden of item "Otaku.app" to true
    set position of item "Otaku.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOS
SetFile -a C /Volumes/Otaku
sync; hdiutil detach /Volumes/Otaku -quiet
hdiutil convert .rw.dmg -format UDZO -o Otaku.dmg -quiet && rm .rw.dmg
rm -rf .dmg
echo "Built $(pwd)/Otaku.dmg"

[ "$1" = publish ] || exit 0
v=v$(sed -n 's#.*CFBundleShortVersionString</key><string>\(.*\)</string>.*#\1#p' build-app.sh)
gh release create "$v" Otaku.dmg --repo hotslug/otaku --title "$v" --notes "$2"

t=$(security find-generic-password -s scout-gitea -w 2>/dev/null) && [ -n "$GITEA_URL" ] || { echo "Gitea skipped: no scout-gitea token or GITEA_URL"; exit 0; }
api="$GITEA_URL/api/v1/repos/hotslug/otaku/releases"
id=$(jq -n --arg v "$v" --arg n "$2" --arg c "$(git rev-parse HEAD)" '{tag_name: $v, name: $v, body: $n, target_commitish: $c}' |
  curl -sf -H "Authorization: token $t" -H "Content-Type: application/json" -d @- "$api" | jq -r .id)
curl -sf -H "Authorization: token $t" -F "attachment=@Otaku.dmg" "$api/$id/assets?name=Otaku.dmg" >/dev/null
echo "$GITEA_URL/hotslug/otaku/releases/tag/$v"
