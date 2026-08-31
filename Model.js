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
  var vis = parseVisib(metar.visib)
  var ceiling = ceilingFtFromClouds(metar.clouds)
  return classifyFlightCategory(ceiling, vis.miles)
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

function formatVisibility(visib, imperial) {
  var parsed = parseVisib(visib)
  if (parsed.miles === null || isNaN(parsed.miles)) return "—"
  var value = imperial ? parsed.miles : milesToKm(parsed.miles)
  var rounded = value >= 10 ? Math.round(value) : Math.round(value * 10) / 10
  return rounded + (parsed.plus ? "+" : "") + " " + (imperial ? "mi" : "km")
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
    var base = clouds[i].base
    parts.push(name + (base !== undefined && base !== null ? " " + Math.round(base) + "ft" : ""))
  }
  return parts.length ? parts.join(", ") : "Clear / no cloud reported"
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

function buildEntries(airportList, metarByIcao) {
  var out = []
  for (var i = 0; i < airportList.length; i++) {
    var icao = airportList[i]
    var metar = metarByIcao[icao] || null
    var category = metar ? categoryForMetar(metar) : ""
    out.push({
      icao: icao,
      letter: metar ? letterForCategory(category) : "…",
      category: category || (metar ? "Unknown" : "Loading…"),
      stationName: (metar && metar.name) ? metar.name : "",
      metar: metar
    })
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
    ceilingFtFromClouds: ceilingFtFromClouds,
    classifyFlightCategory: classifyFlightCategory,
    categoryForMetar: categoryForMetar,
    celsiusToFahrenheit: celsiusToFahrenheit,
    milesToKm: milesToKm,
    hpaToInHg: hpaToInHg,
    formatTemp: formatTemp,
    formatVisibility: formatVisibility,
    formatAltimeter: formatAltimeter,
    formatWind: formatWind,
    formatClouds: formatClouds,
    buildByIcao: buildByIcao,
    buildEntries: buildEntries,
    summaryLine: summaryLine
  }
}
