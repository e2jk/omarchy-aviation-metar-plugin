# METAR / TAF — an Omarchy bar plugin

A bar-widget plugin for [Omarchy](https://omarchy.org)'s Quickshell-based
shell (Quattro and later). Shows the flight category — **V**FR, **M**VFR,
**I**FR, **L**IFR — for a list of airports you configure, right in the
center of the bar next to the clock. Click it for the full picture: decoded
METAR (wind, visibility, temperature/dewpoint, altimeter, cloud layers) and
TAF for every configured station.

```
Mon 31 Aug 18:06   V V V
```

Click opens a popup with one card per airport — decoded stats, the raw
METAR, and the raw TAF.

## Why letters, not colors

The bar shows plain letters (`V`/`M`/`I`/`L`) rather than color-coding by
category, so the indicator stays legible and consistent across themes and
doesn't compete with the rest of the bar for visual weight. The full word
(`VFR`, `MVFR`, ...) and station name are in the popup and in the hover
tooltip.

## Data source

[aviationweather.gov](https://aviationweather.gov)'s public data API — no
API key, no rate-limit surprises for personal use, and it covers ICAO
stations worldwide (not just the US) despite the domain. Flight category is
read straight from the API's `fltCat` field when present, with a
FAA-threshold fallback classifier (ceiling/visibility) for the rare station
that doesn't report one.

## Install

```bash
omarchy plugin add https://github.com/<your-username>/omarchy-metar-plugin.git --enable
```

Or by hand, for local development — this repo *is* meant to be cloned or
symlinked straight into place:

```bash
ln -s /path/to/omarchy-metar-plugin ~/.config/omarchy/plugins/metar-taf
omarchy-shell shell rescanPlugins
omarchy plugin enable metar-taf --section center
```

Saving a file under `~/.config/omarchy/plugins/` (symlinks included) hot-reloads
the plugin, so editing this repo updates the live bar immediately.

## Configuration

Set these from Setup → Plugins in the Omarchy menu, or inline in
`~/.config/omarchy/shell.json`:

| Key              | Type    | Default            | Notes                                                                 |
|------------------|---------|--------------------|------------------------------------------------------------------------|
| `airports`       | string  | `EBAW,EBBR,EBCI`   | Comma-separated ICAO codes, in display order                          |
| `units`          | enum    | `Metric`           | `Metric` (°C, km, hPa) or `Imperial` (°F, mi, inHg)                    |
| `showTaf`        | boolean | `true`             | Include the TAF under each station's METAR                            |
| `refreshMinutes` | integer | `10`               | How often to re-fetch (5–60 min)                                      |

Wind speed always stays in knots regardless of the unit setting — that's
the aviation-standard unit everywhere, metric countries included.

`allowMultiple` is on, so you can add a second instance of the widget with a
different airport list if you want, e.g. one for home and one for a
cross-country you're planning.

## Interactions

| Action        | Effect                                                        |
|---------------|-----------------------------------------------------------------|
| Left click    | Toggle the detail popup                                       |
| Middle click  | Force a refresh                                                |
| Right click   | Send a desktop notification with a one-line summary            |
| Hover         | Tooltip with each airport's full category and name             |

## License

MIT — see [LICENSE](LICENSE).
