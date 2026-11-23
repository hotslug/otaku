#!/bin/sh
# ./release.sh            -> builds Otaku.dmg
# ./release.sh publish "notes" -> also creates the GitHub + Gitea release for the version in build-app.sh
set -e
cd "$(dirname "$0")"
./build-app.sh
rm -rf .dmg Otaku.dmg && mkdir .dmg
cp -R Otaku.app .dmg/ && ln -s /Applications .dmg/Applications
cp Otaku.icns .dmg/.VolumeIcon.icns
hdiutil create -volname Otaku -srcfolder .dmg -format UDRW -o .rw.dmg -quiet
m=$(mktemp -d) && hdiutil attach .rw.dmg -mountpoint "$m" -nobrowse -quiet
SetFile -a C "$m" && hdiutil detach "$m" -quiet
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
