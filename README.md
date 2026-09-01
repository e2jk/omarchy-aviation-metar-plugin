# Aviation Weather (METAR/TAF) — an Omarchy bar plugin

A bar-widget plugin for [Omarchy](https://omarchy.org)'s Quickshell-based
shell (Quattro and later) that shows **aviation** flight-category weather —
**V**FR, **M**VFR, **I**FR, **L**IFR — for a list of airports you configure.
It lives in the bar's center section by default, alongside the clock,
weather, and the other status indicators. Click it for the full picture:
METAR and TAF for every configured station, decoded to plain English by
default (hover to see the raw coded text, or flip the default).

```
Mon 31 Aug 18:06   V V V
```

Click opens a popup with one card per airport — decoded stats, and the
METAR/TAF report itself (coded or decoded, your choice — see below).

![The detail popup, showing three airport cards](preview.png)

## Why letters, not colors

The bar shows plain letters (`V`/`M`/`I`/`L`, plus `–` while refreshing, `…`
while loading for the first time, and `?` for no data — see below) rather
than color-coding by category, so the indicator stays legible and consistent
across themes and doesn't compete with the rest of the bar for visual
weight. The full word (`VFR`, `MVFR`, ...) and station name are in the popup
and in the hover tooltip.

## Coded vs. decoded

Each station's METAR/TAF can be shown as the raw coded text pilots read
(`METAR EBAW 311550Z 27014G25KT 9999 SCT038 21/11 Q1014 NOSIG`) or as a
plain-English sentence built from the same underlying fields. Hovering the
report always shows whichever form isn't currently the primary one, so
neither reading is more than a hover away.

There's no external decode API to lean on for this — checked first:
aviationweather.gov rejects a `units`/`decoded` query parameter outright,
and its JSON/XML responses only ever carry the coded text plus separate
numeric fields, never a narrative string. A capable npm library
(`metar-taf-parser`) exists, but this plugin ships as flat files that
`omarchy plugin add` git-clones straight onto people's machines with no
`npm install` step, and runs unsandboxed inside their shell — so pulling in
a third-party dependency here would mean everyone installing this plugin is
also trusting that dependency's code, for a feature that's a ~150-line
decoder over fields already parsed in `Model.js`. Decoded to English covers:
wind, visibility, present weather (rain/fog/thunderstorms/...), cloud
layers, temperature/dewpoint, altimeter, and NOSIG/BECMG/TEMPO trend, for
both METAR and each TAF change group.

## Data source

[aviationweather.gov](https://aviationweather.gov)'s public data API — no
API key, no rate-limit surprises for personal use, and it covers ICAO
stations worldwide (not just the US) despite the domain. Flight category is
read straight from the API's `fltCat` field when present, with a fallback
classifier (ceiling/visibility) for the rare station that doesn't report
one, using the official FAA flight-category thresholds (AIM 7-1-7 / 14 CFR
Part 91):

| Category | Ceiling         | Visibility     |
|----------|-----------------|----------------|
| LIFR     | < 500 ft        | < 1 sm         |
| IFR      | 500–999 ft      | 1–<3 sm        |
| MVFR     | 1,000–3,000 ft  | 3–5 sm         |
| VFR      | > 3,000 ft      | > 5 sm         |

Ceiling and visibility are each independently checked; whichever is more
restrictive sets the category (`Model.js`: `classifyFlightCategory`).

**Visibility is parsed from the raw METAR/TAF text, not the API's `visib`
JSON field.** That field re-expresses visibility on the US reportable-miles
scale, which is lossy for anything coded in meters (the ICAO norm outside
North America) — EBAW's raw `9999` (ICAO for "10km or more") comes back from
the API as `"6+"`, which would reconvert to a nonsensical `9.7+ km`. This
plugin instead finds the visibility group in the raw text (for both METAR
and each TAF change group) and converts from there, so what's shown is
exactly what the station transmitted, in its original unit.

**Wind speed always stays in knots** and **cloud base height always stays in
feet AGL** regardless of the unit setting — both are the aviation-standard
units everywhere, metric countries included. The `units` setting only
affects temperature, visibility, and altimeter/QNH.

## No stale data

Aviation weather is hyper-local and changes fast, so this plugin would
rather show nothing than something that might be an hour old and wrong. Two
independent checks feed into that:

- **Reachability** — if a fetch (including its retries) fails outright, the
  affected stations show `?` rather than silently keep displaying whatever
  was last cached.
- **Report age** — even when the fetch itself succeeds, a station's own
  observation time (`obsTime`) is checked against `maxAgeMinutes`. A quiet
  station (equipment fault, no reports outside operating hours, ...) ages
  out on its own schedule, independent of whether aviationweather.gov is
  reachable.

Either way the bar letter becomes `?`, and the popup still shows the
last-known data with an explicit "last observation N ago" banner rather than
hiding it outright — still useful context, just never presented as current.

## Bad airport codes

Two separate cases, told apart rather than both showing a generic `?`:

- A malformed entry in `airports` (wrong length, stray characters — ICAO
  codes are always exactly 4 alphanumeric characters) is dropped before ever
  reaching the API, and called out with a warning banner in the popup, so a
  typo doesn't just make a station silently vanish from the bar.
- A correctly-shaped code that isn't a real/reporting station (typo like
  `EBAX`, or one that's simply never been returned) shows **"Unknown or
  invalid station."** One that *has* been seen before but is absent from the
  latest response shows **"Missing from latest report"** instead — a fetch
  that only ever returns your other configured airports is a real, honest
  answer (verified live: `aviationweather.gov` returns HTTP 204 for a batch
  request where none of the ids are recognized, and silently omits an
  unrecognized id from an otherwise-successful multi-airport response —
  neither case is a network failure, so neither is treated as one).

## Install

```bash
omarchy plugin add https://github.com/e2jk/omarchy-aviation-metar-plugin.git --enable
```

Or by hand, for local development — this repo *is* meant to be cloned or
symlinked straight into place:

```bash
ln -s /path/to/omarchy-aviation-metar-plugin ~/.config/omarchy/plugins/metar-taf
omarchy-shell shell rescanPlugins
omarchy plugin enable metar-taf --section center
```

Saving a `.qml` file under `~/.config/omarchy/plugins/` (symlinks included)
hot-reloads live. **`Model.js` is the exception** — QML caches imported
plain-JS modules independently of the component reload, so a change there
needs `omarchy-restart-shell` to actually take effect, not just
`rescanPlugins`.

## Remove

```bash
omarchy plugin remove metar-taf
```

This deletes `~/.config/omarchy/plugins/metar-taf/` and drops the widget
from the bar layout in `~/.config/omarchy/shell.json`. Nothing else on the
system is touched — no daemons, no other config files.

## Configuration

Set these from Setup → Plugins in the Omarchy menu, or inline in
`~/.config/omarchy/shell.json`:

| Key                        | Type    | Default            | Notes                                                                    |
|-----------------------------|---------|--------------------|---------------------------------------------------------------------------|
| `airports`                  | string  | `EBAW,EBBR,EBCI`   | Comma-separated ICAO codes (exactly 4 characters each), in display order |
| `units`                     | enum    | `Metric`           | `Metric` (°C, km, hPa) or `Imperial` (°F, mi, inHg) — see units note above |
| `showTaf`                   | boolean | `true`             | Include the TAF under each station's METAR                               |
| `refreshMinutes`            | integer | `10`               | How often to re-fetch (5–60 min)                                         |
| `maxAgeMinutes`             | integer | `40`               | A station's last report older than this is treated as no data (10–180)   |
| `hoverRefreshMinutes`       | integer | `2`                | Hovering the bar refreshes in the background past this age (1–30)        |
| `decodeStyle`               | enum    | `Decoded`           | `Decoded` (plain English) or `Coded` (raw text) as the primary view      |
| `showStationNameInTooltip`  | boolean | `true`             | Include the full airport name in the bar's hover tooltip                 |

`allowMultiple` is on, so you can add a second instance of the widget with a
different airport list if you want, e.g. one for home and one for a
cross-country you're planning.

## Interactions

| Action        | Effect                                                          |
|---------------|-------------------------------------------------------------------|
| Left click    | Toggle the detail popup                                         |
| Middle click  | Force a refresh (bar briefly shows `–` while it's in flight)     |
| Right click   | Send a desktop notification with a one-line summary              |
| Hover (bar)   | Tooltip with each airport's full category and (optionally) name  |
| Hover (report)| Reveals whichever of coded/decoded isn't the primary view        |
| Click (report)| Copies that station's METAR or TAF (whichever block was clicked, exactly as currently displayed — coded or decoded, following `decodeStyle`) to the clipboard, with a desktop notification confirming it |

Hovering the bar also refreshes in the background if the data is older than
`hoverRefreshMinutes` (default 2 min) — silently. It only becomes visible
(a brief color flash on the bar letters) if the refreshed METAR/TAF text
actually differs from what was already showing; a hover refresh that comes
back identical is a complete no-op, so hovering to check freshness never
adds visual noise for its own sake.

## Development

`Model.js` is plain, dependency-free JS with a full test suite (`test/`,
using Node's built-in `node:test` — no test framework dependency):

```bash
npm test    # runs the suite, fails if line/branch/function coverage < 100%
```

`npm install` wires up a `pre-push` git hook (`scripts/git-hooks/pre-push`)
that blocks the push if any of the following fail — the same checks run in
`.github/workflows/test.yml`. All of it currently takes well under a
second, so it's a hard gate rather than advisory; if that ever grows slow
enough to be friction, that's worth revisiting rather than just dropping a
check. Every check runs even after an earlier one fails, so one push
attempt surfaces everything wrong at once. Quiet on success — a one-line
`ok: <check>` (plus the test suite's own count/coverage summary, the one
thing worth seeing in full even when it passes); a failing check always
prints its full output, so it stays fully diagnosable.

| Check | What | Locally when unavailable |
|---|---|---|
| `npm test` | The suite above, 100% coverage enforced | Skipped with a note if `npm` isn't found |
| `scripts/run-qmllint.sh` | Syntax errors on `BarWidget.qml`/`Panel.qml` stay fatal; every semantic/type-checking category qmllint reports (extracted from its own `--help`, not a hardcoded list) is forced to non-fatal `info`, since Quickshell's `qs.*` namespace and base types (`BarWidget`, `Panel`, ...) aren't resolvable without its full build and can trip essentially any type-aware check — not a fixed, nameable set, and not even a stable one: Qt 6.4.2 (Ubuntu 24.04's package, what CI uses) calls the same checks `property`/`type`/`signal` where a typical dev machine's Qt 6.11+ calls them `missing-property`/`unresolved-type`/`signal-handler-parameters` | Skips with a note if not found (checks both `qmllint` on `PATH` and Qt6's usual `/usr/lib/qt6/bin/qmllint`) |
| `scripts/validate-manifest.sh` | Portable manifest.json schema check (valid JSON, `schemaVersion`, required fields, entry points exist, id not in the reserved `omarchy.*` namespace) — no Omarchy install required, so it's what actually runs in CI | Always runs |
| `omarchy plugin validate` | The real, stricter Omarchy validator (symlinks, exact entry-point safety, ...) | Only runs if the `omarchy` CLI is present (i.e. on an actual Omarchy machine) — CI can't run this one |
| `shellcheck` | Lints this hook and the manifest validator script themselves | Not installed as a system package on purpose (its real dependency chain — a full GHC/Haskell runtime — is ~200MB installed for linting two small scripts); runs via `docker run koalaman/shellcheck` if `docker` is present, otherwise skipped with a note. Pre-installed on GitHub's `ubuntu-latest` runners, so CI always runs it natively |

The QML files (`BarWidget.qml`, `Panel.qml`) aren't covered by the `Model.js`
unit-test suite — there's no QML test harness set up for this repo, `qmllint`
above is static analysis, not behavioral testing. Behavior changes there are
verified by hand: symlink into `~/.config/omarchy/plugins/metar-taf`,
`omarchy-shell shell rescanPlugins` (`.qml` changes) or
`omarchy-restart-shell` (`Model.js` changes — QML caches imported JS modules
independently of the component reload), and check `journalctl --user -b`
for QML warnings.

## License

MIT — see [LICENSE](LICENSE).
