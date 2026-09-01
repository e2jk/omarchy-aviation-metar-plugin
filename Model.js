// Pure helper functions for the METAR/TAF widget: parsing the configured
// airport list, deriving/normalizing flight category, and unit conversion.
// Kept dependency-free (no QML imports) so it can be unit tested with plain
// node/qmljs if desired.

function parseAirportList(raw) {
  var parts = String(raw || "").split(/[,\s]+/)
  var seen = {}
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var code = parts[i].replace(/^\s+|\s+$/g, "").toUpperCase()
    if (code.length < 3 || code.length > 5) continue
    if (!/^[A-Z0-9]+$/.test(code)) continue
    if (seen[code]) continue
    seen[code] = true
    out.push(code)
    if (out.length >= 12) break
  }
  return out
}

function letterForCategory(category) {
  switch (String(category || "").toUpperCase()) {
    case "VFR": return "V"
    case "MVFR": return "M"
    case "IFR": return "I"
    case "LIFR": return "L"
    default: return "?"
  }
}

// aviationweather.gov reports visibility in statute miles as either a plain
// number, a numeric string ("2.49"), or "6+" for anything at/above the
// station's reportable ceiling. Fractions ("1/2") show up for very low vis.
function parseVisib(visib) {
  if (visib === undefined || visib === null || visib === "") return { miles: null, plus: false }
  if (typeof visib === "number") return { miles: visib, plus: false }

  var s = String(visib).replace(/^\s+|\s+$/g, "")
  var plus = s.indexOf("+") !== -1
  s = s.replace("+", "")

  if (s.indexOf("/") !== -1) {
    var fraction = s.split("/")
    var num = parseFloat(fraction[0])
    var den = parseFloat(fraction[1])
    if (!isNaN(num) && !isNaN(den) && den !== 0) return { miles: num / den, plus: plus }
    return { miles: null, plus: plus }
  }

  var n = parseFloat(s)
  return { miles: isNaN(n) ? null : n, plus: plus }
}

// aviationweather.gov's JSON `visib` field is not the value the station
// actually transmitted: it's translated onto the US reportable-visibility
// scale (quarter/half-mile steps up to 3, whole miles above that, capped at
// "10+"). For a non-US METAR coded in meters, that translation is lossy —
// EBAW's raw "9999" (ICAO code for "10km or more") comes back as "6+", which
// then reconverts to a nonsensical "9.7+ km". Parse the visibility group
// straight out of the raw METAR/TAF text instead; it is exactly what the
// station transmitted, in its original unit, with no intermediate rounding.
//
// Strips the leading report-type/station/time/modifier tokens so the
// visibility group can be found positionally (it follows the wind group).
function significantTokens(rawText) {
  var tokens = String(rawText || "").trim().split(/\s+/).filter(function(t) { return t.length > 0 })
  var i = 0
  if (tokens[i] === "METAR" || tokens[i] === "SPECI" || tokens[i] === "TAF") i++
  if (/^[A-Z0-9]{4}$/.test(tokens[i])) i++ // ICAO station id
  if (/^\d{6}Z$/.test(tokens[i])) i++ // DDHHMMZ observation/issue time
  while (i < tokens.length && /^(AUTO|COR|AMD|NIL|CNL)$/.test(tokens[i])) i++
  return tokens.slice(i)
}

// TAF change-group segment, e.g. "BECMG 3118/3120 25008KT" or
// "TEMPO 3115/3116 4000 SHRA SCT015 BKN020CB" — strips the change keyword
// and its validity window so the wind/visibility groups can be found the
// same way as in a METAR.
function tafSegmentSignificantTokens(segment) {
  var tokens = String(segment || "").trim().split(/\s+/).filter(function(t) { return t.length > 0 })
  var i = 0
  if (/^PROB\d{2}$/.test(tokens[i])) i++
  if (/^(BECMG|TEMPO)$/.test(tokens[i])) i++
  else if (/^FM\d{6}$/.test(tokens[i])) i++
  if (/^\d{4}\/\d{4}$/.test(tokens[i])) i++
  return tokens.slice(i)
}

// The base/initial TAF period keeps the ordinary "TAF ICAO DDHHMMZ" header
// (stripped by significantTokens) plus one thing METAR doesn't have: a
// DDHH/DDHH overall validity window right after it.
function tafBaseSignificantTokens(segment) {
  var tokens = significantTokens(segment)
  return /^\d{4}\/\d{4}$/.test(tokens[0]) ? tokens.slice(1) : tokens
}

// Splits a raw TAF into one segment per change group (base period first,
// then each FMddhhmm/BECMG/TEMPO/PROBnn), in the order they appear — which
// matches the order the API's `fcsts` array is in. "PROBnn TEMPO" has to be
// matched as a single boundary, not two: the API represents that combination
// as one fcst entry (fcstChange: "TEMPO", probability: nn), so splitting on
// both words separately would produce one extra segment and misalign every
// later period against fcsts.
function tafRawSegments(rawTAF) {
  var text = String(rawTAF || "")
  var re = /\b(FM\d{6}|PROB\d{2}\s+TEMPO|BECMG|PROB\d{2}|TEMPO)\b/g
  var indices = []
  var m
  while ((m = re.exec(text)) !== null) indices.push(m.index)
  var segments = []
  var start = 0
  for (var i = 0; i < indices.length; i++) {
    segments.push(text.slice(start, indices[i]))
    start = indices[i]
  }
  segments.push(text.slice(start))
  return segments.map(function(s) { return s.replace(/^\s+|\s+$/g, "") }).filter(function(s) { return s.length > 0 })
}

// Returns { meters, plus, lessThan, cavok} describing the coded visibility,
// or null if no visibility group could be found. `plus` means "this value or
// greater" (ICAO 9999, CAVOK, or FAA "P6SM" — confirmed current and common
// in real TAFs, not just a legacy code: 24 occurrences checked across 6 US
// airports' live TAFs). `lessThan` means "less than this value" (FAA
// "M1/4SM", automated stations only). Shared core for both a full METAR/TAF
// report and a single TAF change-group segment.
function parseVisibilityFromTokens(tokens) {
  var i = 0

  // Skip the surface wind group (ddd/VRB + speed + optional gust + unit)...
  if (i < tokens.length && /^(VRB|\d{3})\d{2,3}(G\d{2,3})?(KT|MPS|KMH)$/.test(tokens[i])) i++
  // ...and a following variable-wind-direction group, if present.
  if (i < tokens.length && /^\d{3}V\d{3}$/.test(tokens[i])) i++
  if (i >= tokens.length) return null

  var token = tokens[i]

  if (token === "CAVOK") return { meters: 10000, plus: true, lessThan: false, cavok: true }

  // ICAO group: exactly 4 digits, optionally followed by a minimum-visibility
  // direction qualifier (e.g. "9999NDV", "1400W"). 9999 means "10km+".
  if (/^\d{4}[A-Z]{0,3}$/.test(token)) {
    var meters = parseInt(token.slice(0, 4), 10)
    return { meters: meters, plus: meters === 9999, lessThan: false, cavok: false }
  }

  // US/Canada statute-mile group: "10SM", "1/2SM", "M1/4SM" (less than),
  // "P6SM" (greater than), or a whole-number token followed by a separate
  // fraction token ("1" "1/2SM").
  var whole = 0
  if (/^\d{1,2}$/.test(token) && /^\d\/\dSM$/.test(tokens[i + 1] || "")) {
    whole = parseInt(token, 10)
    i++
    token = tokens[i]
  }
  var sm = token.match(/^([MP])?(?:(\d{1,2})(?:\/(\d))?)?SM$/)
  if (sm && (sm[2] !== undefined || whole > 0)) {
    // sm[2] is always defined here: the only way to reach this branch with
    // whole > 0 is via the split-token case above, whose own regex already
    // requires a leading digit — so `sm[2] !== undefined` is never false
    // when `whole > 0` is what got us in.
    var num = parseInt(sm[2], 10)
    var den = sm[3] !== undefined ? parseInt(sm[3], 10) : 1
    var miles = whole + num / den
    return { meters: miles * 1609.344, plus: sm[1] === "P", lessThan: sm[1] === "M", cavok: false }
  }

  return null
}

function parseVisibilityFromRaw(rawText) {
  return parseVisibilityFromTokens(significantTokens(rawText))
}

function parseVisibilityFromTafSegment(segment) {
  return parseVisibilityFromTokens(tafSegmentSignificantTokens(segment))
}

// Ceiling is the lowest broken/overcast (or vertical-visibility) layer.
// A sky with only scattered/few layers (or none reported) has no ceiling.
function ceilingFtFromClouds(clouds) {
  if (!clouds || !clouds.length) return null
  var min = null
  for (var i = 0; i < clouds.length; i++) {
    var cover = String((clouds[i] && clouds[i].cover) || "").toUpperCase()
    if (cover !== "BKN" && cover !== "OVC" && cover !== "VV") continue
    var base = Number(clouds[i].base)
    if (!isNaN(base) && (min === null || base < min)) min = base
  }
  return min
}

// Standard FAA flight-category thresholds, used worldwide by convention.
function classifyFlightCategory(ceilingFt, visibilityMiles) {
  var ceiling = (ceilingFt === null || ceilingFt === undefined) ? Infinity : ceilingFt
  var vis = (visibilityMiles === null || visibilityMiles === undefined || isNaN(visibilityMiles)) ? Infinity : visibilityMiles
  if (ceiling < 500 || vis < 1) return "LIFR"
  if (ceiling < 1000 || vis < 3) return "IFR"
  if (ceiling <= 3000 || vis <= 5) return "MVFR"
  return "VFR"
}

// aviationweather.gov already computes fltCat for almost every station; only
// fall back to a manual classification when it is missing.
function categoryForMetar(metar) {
  if (!metar) return ""
  var reported = String(metar.fltCat || "").toUpperCase()
  if (reported === "VFR" || reported === "MVFR" || reported === "IFR" || reported === "LIFR") return reported
  var raw = parseVisibilityFromRaw(metar.rawOb)
  var visMiles = raw ? raw.meters / 1609.344 : parseVisib(metar.visib).miles
  var ceiling = ceilingFtFromClouds(metar.clouds)
  return classifyFlightCategory(ceiling, visMiles)
}

function celsiusToFahrenheit(c) {
  if (c === undefined || c === null || isNaN(c)) return null
  return c * 9 / 5 + 32
}

function milesToKm(mi) {
  return mi * 1.609344
}

function hpaToInHg(hpa) {
  return hpa * 0.0295299830714
}

function formatTemp(celsius, imperial) {
  if (celsius === undefined || celsius === null || isNaN(celsius)) return "—"
  var v = imperial ? celsiusToFahrenheit(celsius) : celsius
  return Math.round(v) + "°" + (imperial ? "F" : "C")
}

// Prefers the exact value coded in the raw METAR text; falls back to the
// API's lossy `visib` field (already in statute miles) only if the raw text
// couldn't be parsed, so something is always shown.
function formatVisibilityFromMetar(metar, imperial) {
  if (!metar) return "—"

  var raw = parseVisibilityFromRaw(metar.rawOb)
  if (raw) {
    var prefix = raw.lessThan ? "<" : ""
    var suffix = raw.plus ? "+" : ""
    if (imperial) {
      var miles = raw.meters / 1609.344
      var mRounded = miles >= 10 ? Math.round(miles) : Math.round(miles * 10) / 10
      return prefix + mRounded + suffix + " mi"
    }
    if (!raw.plus && raw.meters < 1000) return prefix + Math.round(raw.meters) + " m"
    var km = raw.meters / 1000
    var kRounded = km >= 10 ? Math.round(km) : Math.round(km * 10) / 10
    return prefix + kRounded + suffix + " km"
  }

  var parsed = parseVisib(metar.visib)
  if (parsed.miles === null || isNaN(parsed.miles)) return "—"
  var value = imperial ? parsed.miles : milesToKm(parsed.miles)
  var rounded = value >= 10 ? Math.round(value) : Math.round(value * 10) / 10
  return rounded + (parsed.plus ? "+" : "") + " " + (imperial ? "mi" : "km") + " (approx.)"
}

function formatAltimeter(hpa, imperial) {
  if (hpa === undefined || hpa === null || isNaN(hpa)) return "—"
  if (imperial) return hpaToInHg(hpa).toFixed(2) + " inHg"
  return Math.round(hpa) + " hPa"
}

function formatWind(wdir, wspd, wgst) {
  if (wspd === undefined || wspd === null || wspd === "") return "—"
  if (Number(wspd) === 0) return "Calm"

  var dirLabel
  if (wdir === undefined || wdir === null || wdir === "") dirLabel = "—"
  else if (isNaN(Number(wdir))) dirLabel = String(wdir) // e.g. "VRB"
  else dirLabel = ("00" + Math.round(Number(wdir))).slice(-3) + "°"

  var s = dirLabel + " " + wspd + "kt"
  if (wgst) s += " G" + wgst + "kt"
  return s
}

var CLOUD_COVER_NAMES = {
  SKC: "Sky clear", CLR: "Clear below 12,000ft", NSC: "No significant cloud",
  NCD: "No cloud detected", FEW: "Few", SCT: "Scattered", BKN: "Broken",
  OVC: "Overcast", VV: "Vertical visibility"
}

function formatClouds(clouds) {
  if (!clouds || !clouds.length) return "Clear / no cloud reported"
  var parts = []
  for (var i = 0; i < clouds.length; i++) {
    var cover = String((clouds[i] && clouds[i].cover) || "").toUpperCase()
    var name = CLOUD_COVER_NAMES[cover] || cover
    if (cover === "SKC" || cover === "CLR" || cover === "NSC" || cover === "NCD") {
      parts.push(name)
      continue
    }
    var base = clouds[i] ? clouds[i].base : undefined
    parts.push(name + (base !== undefined && base !== null ? " " + Math.round(base) + "ft" : ""))
  }
  // Every loop iteration above pushes exactly one entry, and the early
  // return already handled the only way to get here with an empty list —
  // so parts.length is always >= 1.
  return parts.join(", ")
}

// ---- Present-weather (wxString) decoding, e.g. "SHRA", "+TSRA", "-RA",
// "VCTS", "FZFG". Standard ICAO/METAR abbreviations — no external decode
// endpoint exists (checked: aviationweather.gov rejects a units/decoded
// param and its JSON/XML both only ever carry the coded text plus separate
// numeric fields, never a narrative string). This covers the codes actually
// seen in METAR/TAF reports; an unrecognized code is left out rather than
// guessed at.
var WX_DESCRIPTORS = {
  MI: "shallow", PR: "partial", BC: "patches of", DR: "low drifting",
  BL: "blowing", SH: "showers", TS: "thunderstorm", FZ: "freezing"
}
var WX_PHENOMENA = {
  DZ: "drizzle", RA: "rain", SN: "snow", SG: "snow grains", IC: "ice crystals",
  PL: "ice pellets", GR: "hail", GS: "small hail/snow pellets", UP: "unknown precipitation",
  BR: "mist", FG: "fog", FU: "smoke", VA: "volcanic ash", DU: "widespread dust",
  SA: "sand", HZ: "haze", PY: "spray", PO: "dust/sand whirls", SQ: "squalls",
  FC: "funnel cloud", SS: "sandstorm", DS: "duststorm"
}

function decodeWxToken(token) {
  var t = token
  var vicinity = false
  if (t.slice(0, 2) === "VC") { vicinity = true; t = t.slice(2) }
  var intensity = ""
  if (t.charAt(0) === "-") { intensity = "light "; t = t.slice(1) }
  else if (t.charAt(0) === "+") { intensity = "heavy "; t = t.slice(1) }

  var descriptors = []
  var phenomena = []
  while (t.length >= 2) {
    var code = t.slice(0, 2)
    if (WX_DESCRIPTORS[code]) { descriptors.push(code); t = t.slice(2); continue }
    if (WX_PHENOMENA[code]) { phenomena.push(WX_PHENOMENA[code]); t = t.slice(2); continue }
    break // unrecognized code — stop rather than guess
  }
  if (!descriptors.length && !phenomena.length) return null

  var text
  if (phenomena.length) {
    var phenomText = phenomena.join(" and ")
    if (descriptors.indexOf("TS") !== -1) text = "thunderstorm with " + phenomText
    else if (descriptors.indexOf("SH") !== -1) text = phenomText + " showers"
    else if (descriptors.length) text = WX_DESCRIPTORS[descriptors[0]] + " " + phenomText
    else text = phenomText
  } else {
    text = descriptors.map(function(d) { return WX_DESCRIPTORS[d] }).join(" ")
  }

  text = intensity + text
  if (vicinity) text += " in the vicinity"
  return text
}

function decodeWxString(wx) {
  if (!wx) return ""
  var tokens = String(wx).trim().split(/\s+/).filter(function(t) { return t.length > 0 })
  var decoded = []
  for (var i = 0; i < tokens.length; i++) {
    var d = decodeWxToken(tokens[i])
    if (d) decoded.push(d)
  }
  return decoded.join(", ")
}

// Full plain-English rendering of a METAR, built from the same structured
// fields (and the raw-text-parsed visibility) used everywhere else in this
// file — not a separate/independent parse, so it can't disagree with the
// coded view or the flight-category letter shown on the bar.
function decodeMetarText(metar, imperial) {
  if (!metar) return ""
  var parts = []

  var wind = formatWind(metar.wdir, metar.wspd, metar.wgst)
  if (wind === "Calm") parts.push("Wind calm")
  else if (wind !== "—") parts.push("Wind " + wind)

  var visRaw = parseVisibilityFromRaw(metar.rawOb)
  if (visRaw && visRaw.cavok) {
    parts.push("CAVOK — visibility 10km+, no cloud below 5,000ft, no significant weather")
  } else {
    var visText = formatVisibilityFromMetar(metar, imperial)
    if (visText !== "—") parts.push("Visibility " + visText)
  }

  var wx = decodeWxString(metar.wxString)
  if (wx) parts.push(wx.charAt(0).toUpperCase() + wx.slice(1))

  if (!visRaw || !visRaw.cavok) parts.push("Clouds: " + formatClouds(metar.clouds).toLowerCase())

  parts.push("Temperature " + formatTemp(metar.temp, imperial) + ", dew point " + formatTemp(metar.dewp, imperial))
  parts.push("Altimeter " + formatAltimeter(metar.altim, imperial))

  var raw = String(metar.rawOb || "")
  var trend = ""
  if (/\bNOSIG\b/.test(raw)) trend = "No significant change expected."
  else if (/\bBECMG\b/.test(raw)) trend = "Conditions expected to become different — see raw report for detail."
  else if (/\bTEMPO\b/.test(raw)) trend = "Temporary fluctuations expected — see raw report for detail."

  var sentence = parts.join(". ") + "."
  return trend ? sentence + " " + trend : sentence
}

// Plain-English rendering of a TAF, one line per change group. `formatTime`
// is a callback (epochSeconds -> string) supplied by the QML side, since
// this file has no access to Qt.formatDateTime.
function decodeTafText(taf, imperial, formatTime) {
  if (!taf || !taf.fcsts || !taf.fcsts.length) return ""

  var segments = tafRawSegments(taf.rawTAF)
  var lines = []

  for (var i = 0; i < taf.fcsts.length; i++) {
    var p = taf.fcsts[i]
    var change = p.fcstChange

    var label
    if (change === "BECMG") label = "Becoming"
    else if (change === "TEMPO") label = "Temporarily"
    else if (change === "FM") label = "From"
    else label = i === 0 ? "Initial period" : "Then"
    if (p.probability) label += " (" + p.probability + "% chance)"

    var fromText = (formatTime && p.timeFrom) ? formatTime(p.timeFrom) : ""
    var toText = (formatTime && p.timeTo) ? formatTime(p.timeTo) : ""
    var window = (fromText && toText) ? (fromText + "–" + toText) : ""

    var bits = []
    var wind = formatWind(p.wdir, p.wspd, p.wgst)
    if (wind !== "—") bits.push("wind " + wind)

    // Segment-precise visibility, parsed from this change group's own raw
    // text — same fix as the METAR one. Deliberately no fallback to the
    // API's `visib` field when this segment states no visibility group: a
    // BECMG/TEMPO/FM group only lists what's *changing*, so "not restated"
    // means "unchanged from the prior period" in TAF grammar. The API
    // backfills the previous period's (already lossy, statute-mile-bucketed)
    // value into `visib` regardless — e.g. EBBR's BECMG group is genuinely
    // wind-only in the raw text, but its `visib` field still carries the
    // earlier lossy "6+" forward, which is exactly the bug this avoids.
    var segVis = segments[i]
      ? parseVisibilityFromTokens(i === 0 ? tafBaseSignificantTokens(segments[i]) : tafSegmentSignificantTokens(segments[i]))
      : null
    if (segVis && !segVis.cavok) {
      var visPrefix = segVis.lessThan ? "<" : ""
      var visSuffix = segVis.plus ? "+" : ""
      var val = imperial ? segVis.meters / 1609.344 : segVis.meters / 1000
      if (!imperial && segVis.meters < 1000) bits.push("visibility " + visPrefix + Math.round(segVis.meters) + "m")
      else bits.push("visibility " + visPrefix + (val >= 10 ? Math.round(val) : Math.round(val * 10) / 10) + visSuffix + " " + (imperial ? "mi" : "km"))
    } else if (segVis && segVis.cavok) {
      bits.push("CAVOK")
    }

    var wx = decodeWxString(p.wxString)
    if (wx) bits.push(wx)

    // Same "not restated = unchanged" reasoning for clouds: only show them
    // for the base period, or a change-group segment whose own raw text
    // actually contains a cloud group.
    var segHasClouds = i === 0 || /\b(FEW|SCT|BKN|OVC|VV)\d{3}|\b(SKC|NSC|NCD)\b/.test(segments[i] || "")
    if (segHasClouds) {
      var cloudsText = formatClouds(p.clouds)
      if (cloudsText && cloudsText !== "Clear / no cloud reported") bits.push(cloudsText.toLowerCase())
    }

    var line = label + (window ? " (" + window + ")" : "") + ": " + (bits.length ? bits.join(", ") : "no significant change") + "."
    lines.push(line)
  }
  return lines.join(" ")
}

// The API returns most-recent-first; keep the first sighting of each id.
function buildByIcao(list) {
  var map = {}
  if (!list) return map
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    var id = String((item && item.icaoId) || "").toUpperCase()
    if (id && !map[id]) map[id] = item
  }
  return map
}

// Minutes since a METAR's own observation time (`obsTime`, epoch seconds) —
// not since our last successful fetch. A station that has simply stopped
// reporting (gone quiet outside operating hours, equipment fault, ...) needs
// to age out even if aviationweather.gov itself is perfectly reachable.
function ageMinutes(metar, nowSeconds) {
  if (!metar || !metar.obsTime) return null
  return (nowSeconds - Number(metar.obsTime)) / 60
}

function formatAge(minutes) {
  if (minutes === null || minutes === undefined || isNaN(minutes)) return ""
  var m = Math.round(minutes)
  if (m < 60) return m + " min"
  var h = Math.floor(m / 60)
  var rem = m % 60
  return h + "h" + (rem > 0 ? " " + rem + "min" : "")
}

// status: { loading, everSucceeded, offline, nowSeconds, maxAgeMinutes }
//   loading       — a manual refresh is in flight; shown as a transient dash
//                   so pressing refresh visibly does something.
//   everSucceeded — at least one fetch has ever completed successfully.
//   offline       — the most recent fetch attempt (all its retries included)
//                   failed.
//   maxAgeMinutes — a METAR older than this (by its own obsTime) is treated
//                   as no data at all rather than shown as current. Aviation
//                   weather is hyper-local and changes fast, so a stale
//                   reading presented as current is worse than an honest
//                   "nothing" — see [categoryForMetar]/README for the
//                   fltCat/threshold logic this sits in front of.
function buildEntries(airportList, metarByIcao, status) {
  status = status || {}
  var maxAge = status.maxAgeMinutes
  var now = status.nowSeconds
  var out = []

  for (var i = 0; i < airportList.length; i++) {
    var icao = airportList[i]
    var metar = metarByIcao[icao] || null
    var age = (metar && now) ? ageMinutes(metar, now) : null
    var expired = maxAge && age !== null && age > maxAge

    if (status.loading) {
      out.push({ icao: icao, letter: "–", category: "Refreshing…", stationName: "", metar: metar, stale: false, age: age })
      continue
    }

    if (status.offline || expired) {
      // Only hint the last-known category for "offline but still within
      // maxAgeMinutes" — an entry that has aged out is deliberately not
      // softened with a category that may itself be long stale.
      var lastKnown = metar && !expired ? categoryForMetar(metar) : ""
      var reason = status.offline ? "offline" : "last report " + formatAge(age) + " ago"
      out.push({
        icao: icao,
        letter: "?",
        category: metar ? "No data (" + reason + (lastKnown ? ", last known " + lastKnown : "") + ")" : "No data",
        stationName: "",
        metar: metar, // kept so the popup can still show it, clearly marked stale
        stale: true,
        age: age
      })
      continue
    }

    if (metar) {
      var category = categoryForMetar(metar)
      out.push({ icao: icao, letter: letterForCategory(category), category: category, stationName: metar.name || "", metar: metar, stale: false, age: age })
      continue
    }

    if (!status.everSucceeded) {
      out.push({ icao: icao, letter: "…", category: "Loading…", stationName: "", metar: null, stale: false, age: null })
      continue
    }

    // A fetch has succeeded overall, just not for this station specifically
    // — most likely an unrecognized or mistyped ICAO code.
    out.push({ icao: icao, letter: "?", category: "Unknown station", stationName: "", metar: null, stale: false, age: null })
  }
  return out
}

function summaryLine(entries) {
  var parts = []
  for (var i = 0; i < entries.length; i++) {
    parts.push(entries[i].icao + " " + entries[i].category)
  }
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseAirportList: parseAirportList,
    letterForCategory: letterForCategory,
    parseVisib: parseVisib,
    significantTokens: significantTokens,
    tafSegmentSignificantTokens: tafSegmentSignificantTokens,
    tafBaseSignificantTokens: tafBaseSignificantTokens,
    tafRawSegments: tafRawSegments,
    parseVisibilityFromTokens: parseVisibilityFromTokens,
    parseVisibilityFromRaw: parseVisibilityFromRaw,
    parseVisibilityFromTafSegment: parseVisibilityFromTafSegment,
    ageMinutes: ageMinutes,
    formatAge: formatAge,
    ceilingFtFromClouds: ceilingFtFromClouds,
    classifyFlightCategory: classifyFlightCategory,
    categoryForMetar: categoryForMetar,
    celsiusToFahrenheit: celsiusToFahrenheit,
    milesToKm: milesToKm,
    hpaToInHg: hpaToInHg,
    formatTemp: formatTemp,
    formatVisibilityFromMetar: formatVisibilityFromMetar,
    formatAltimeter: formatAltimeter,
    formatWind: formatWind,
    formatClouds: formatClouds,
    decodeWxToken: decodeWxToken,
    decodeWxString: decodeWxString,
    decodeMetarText: decodeMetarText,
    decodeTafText: decodeTafText,
    buildByIcao: buildByIcao,
    buildEntries: buildEntries,
    summaryLine: summaryLine
  }
}
