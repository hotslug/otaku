<p align="center"><img src="logo.png" width="128" alt="Otaku icon"></p>

<h1 align="center">Otaku</h1>

A Mac app for finding the world's most popular anime and where to watch them.

- Start page: trending, popular and seasonal rows, plus "Because you liked…" rows from your Favourites
- Search: results as cards
- Click a card: banner, poster, dates, status, seasons, episodes, score, studio, genres, synopsis, trailer, characters and voice cast, streaming links, related shows and recommendations
- Filters (genre, year, season with ‹ › steps, format, status, sort), search as you type, and Surprise me
- Keyboard: ⌘F to search, arrow keys between cards, Return to open
- My list (Watching, Plan to watch, Finished, Favourites) with new-episode alerts, a menu bar list of what airs today, and this week's schedule
- Import your list from AniList or a MyAnimeList export
- Light, Dark and Auto themes

Data comes from [AniList](https://anilist.co), with [Kitsu](https://kitsu.io) as a fallback. The last good results are saved, so the app still works when both are down. Optionally, add a free [Movie of the Night](https://www.movieofthenight.com/about/api) or [TMDB](https://www.themoviedb.org/settings/api) key in Settings to see what's streaming in your country (from your Mac's region) and where a show first aired. Availability data is from JustWatch via TMDB.

## Install

Download `Otaku.dmg` from Releases, open it, and drag Otaku into Applications. It isn't notarized, so the first time macOS will block it: open System Settings → Privacy & Security and click **Open Anyway**.

## Build

```sh
./build-app.sh                       # builds Otaku.app (universal, ad-hoc signed)
./release.sh                         # builds Otaku.dmg; `./release.sh publish "notes"` also makes the release
OTAKU_SELFTEST=1 .build/debug/Otaku  # offline checks; add OTAKU_LIVE=1 to hit the real APIs
```

Needs macOS 15+ and the Swift command line tools.
