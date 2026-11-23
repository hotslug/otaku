<p align="center"><img src="logo.png" width="128" alt="Otaku icon"></p>

<h1 align="center">Otaku</h1>

A Mac app for finding the world's most popular anime and where to watch them.

- Start page: most popular and trending anime as poster cards
- Search: results as cards
- Click a card: banner, poster, dates, status, seasons, episodes, score, studio, genres, synopsis, and streaming links

Data comes from [AniList](https://anilist.co), with [Kitsu](https://kitsu.io) as a fallback. The last good results are saved, so the app still works when both are down. Optionally, add a free [TMDB](https://www.themoviedb.org/settings/api) key in Settings to see what's streaming in your country (from your Mac's region) and where a show first aired. Availability data is from JustWatch via TMDB.

## Install

Download `Otaku.dmg` from Releases, open it, and drag Otaku into Applications. It isn't notarized, so the first time macOS will block it: open System Settings → Privacy & Security and click **Open Anyway**.

## Build

```sh
./build-app.sh                       # builds Otaku.app (universal, ad-hoc signed)
./release.sh                         # builds Otaku.dmg; `./release.sh publish "notes"` also makes the release
OTAKU_SELFTEST=1 .build/debug/Otaku  # offline checks; add OTAKU_LIVE=1 to hit the real APIs
```

Needs macOS 14+ and the Swift command line tools.
