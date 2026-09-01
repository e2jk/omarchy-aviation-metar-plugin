const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("celsiusToFahrenheit", () => {
  it("returns null for undefined/null/NaN", () => {
    assert.equal(M.celsiusToFahrenheit(undefined), null)
    assert.equal(M.celsiusToFahrenheit(null), null)
    assert.equal(M.celsiusToFahrenheit(NaN), null)
  })

  it("converts correctly", () => {
    assert.equal(M.celsiusToFahrenheit(0), 32)
    assert.equal(M.celsiusToFahrenheit(100), 212)
  })
})

describe("milesToKm / hpaToInHg", () => {
  it("converts miles to km", () => {
    assert.equal(Math.round(M.milesToKm(1) * 1000) / 1000, 1.609)
  })

  it("converts hPa to inHg", () => {
    assert.equal(Math.round(M.hpaToInHg(1013.25) * 100) / 100, 29.92)
  })
})

describe("formatTemp", () => {
  it("returns — for undefined/null/NaN", () => {
    assert.equal(M.formatTemp(undefined, false), "—")
    assert.equal(M.formatTemp(null, false), "—")
    assert.equal(M.formatTemp(NaN, false), "—")
  })

  it("formats in Celsius", () => {
    assert.equal(M.formatTemp(21, false), "21°C")
  })

  it("formats in Fahrenheit", () => {
    assert.equal(M.formatTemp(0, true), "32°F")
  })
})

describe("formatVisibilityFromMetar", () => {
  it("returns — for a null metar", () => {
    assert.equal(M.formatVisibilityFromMetar(null, false), "—")
  })

  it("formats an ICAO meters value in km, with a + for 9999", () => {
    var metar = { rawOb: "METAR EBAW 311550Z 27014KT 9999 SCT038 21/11 Q1014" }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "10+ km")
  })

  it("formats the same value in miles", () => {
    var metar = { rawOb: "METAR EBAW 311550Z 27014KT 9999 SCT038 21/11 Q1014" }
    assert.equal(M.formatVisibilityFromMetar(metar, true), "6.2+ mi")
  })

  it("formats sub-1000m visibility in meters, not km", () => {
    var metar = { rawOb: "METAR LFPO 311600Z 25008KT 0350 FG VV002 12/12 Q1016" }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "350 m")
  })

  it("prefixes < for a less-than value", () => {
    var metar = { rawOb: "METAR KBOS 311554Z 18010KT M1/4SM FG VV003 15/14 A3005" }
    assert.equal(M.formatVisibilityFromMetar(metar, true), "<0.3 mi")
  })

  it("suffixes + for a greater-than value", () => {
    var metar = { rawOb: "METAR KATL 311753Z 21013KT P6SM FEW040 29/19 A2993" }
    assert.equal(M.formatVisibilityFromMetar(metar, true), "6+ mi")
  })

  it("falls back to the lossy visib field, marked approx., when raw text has no visibility group", () => {
    var metar = { rawOb: "GARBAGE", visib: "6+" }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "9.7+ km (approx.)")
    assert.equal(M.formatVisibilityFromMetar(metar, true), "6+ mi (approx.)")
  })

  it("falls back to visib with no + when it isn't plus-suffixed", () => {
    var metar = { rawOb: "GARBAGE", visib: "3" }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "4.8 km (approx.)")
    assert.equal(M.formatVisibilityFromMetar(metar, true), "3 mi (approx.)")
  })

  it("falls back to visib rounding to a whole number at/above 10 (imperial >= 10 boundary)", () => {
    var metar = { rawOb: "GARBAGE", visib: "15" }
    assert.equal(M.formatVisibilityFromMetar(metar, true), "15 mi (approx.)")
  })

  it("returns — when neither raw text nor visib parse", () => {
    var metar = { rawOb: "GARBAGE", visib: null }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "—")
  })

  it("handles CAVOK (exactly 10km/miles<10, both round to a two-digit value)", () => {
    var metar = { rawOb: "METAR EHAM 311555Z 24012KT CAVOK 19/10 Q1015 NOSIG" }
    assert.equal(M.formatVisibilityFromMetar(metar, false), "10+ km")
  })

  it("rounds an exact 10SM to 10 miles (imperial >= 10 boundary)", () => {
    var metar = { rawOb: "METAR KJFK 311551Z 13005KT 10SM FEW040 24/17 A3013" }
    assert.equal(M.formatVisibilityFromMetar(metar, true), "10 mi")
  })
})

describe("formatAltimeter", () => {
  it("returns — for undefined/null/NaN", () => {
    assert.equal(M.formatAltimeter(undefined, false), "—")
    assert.equal(M.formatAltimeter(null, false), "—")
    assert.equal(M.formatAltimeter(NaN, false), "—")
  })

  it("formats in hPa", () => {
    assert.equal(M.formatAltimeter(1014, false), "1014 hPa")
  })

  it("formats in inHg", () => {
    assert.equal(M.formatAltimeter(1013.25, true), "29.92 inHg")
  })
})

describe("formatWind", () => {
  it("returns — when wspd is undefined/null/empty", () => {
    assert.equal(M.formatWind(270, undefined, null), "—")
    assert.equal(M.formatWind(270, null, null), "—")
    assert.equal(M.formatWind(270, "", null), "—")
  })

  it("returns Calm when wspd is 0", () => {
    assert.equal(M.formatWind(0, 0, null), "Calm")
  })

  it("returns — for the direction when wdir is undefined/null/empty", () => {
    assert.equal(M.formatWind(undefined, 10, null), "— 10kt")
  })

  it("uses the raw string when wdir is non-numeric (VRB)", () => {
    assert.equal(M.formatWind("VRB", 4, null), "VRB 4kt")
  })

  it("zero-pads a numeric direction to 3 digits", () => {
    assert.equal(M.formatWind(70, 14, null), "070° 14kt")
  })

  it("appends a gust when present", () => {
    assert.equal(M.formatWind(270, 14, 25), "270° 14kt G25kt")
  })

  it("omits the gust when falsy", () => {
    assert.equal(M.formatWind(270, 14, 0), "270° 14kt")
    assert.equal(M.formatWind(270, 14, undefined), "270° 14kt")
  })
})

describe("formatClouds", () => {
  it("returns the clear message for no clouds", () => {
    assert.equal(M.formatClouds(null), "Clear / no cloud reported")
    assert.equal(M.formatClouds([]), "Clear / no cloud reported")
  })

  it("names a clear-sky cover code without a height", () => {
    assert.equal(M.formatClouds([{ cover: "SKC" }]), "Sky clear")
    assert.equal(M.formatClouds([{ cover: "CLR" }]), "Clear below 12,000ft")
    assert.equal(M.formatClouds([{ cover: "NSC" }]), "No significant cloud")
    assert.equal(M.formatClouds([{ cover: "NCD" }]), "No cloud detected")
  })

  it("names a layer with its height", () => {
    assert.equal(M.formatClouds([{ cover: "BKN", base: 2000 }]), "Broken 2000ft")
  })

  it("omits the height when base is missing", () => {
    assert.equal(M.formatClouds([{ cover: "SCT" }]), "Scattered")
  })

  it("falls back to the raw cover code when unrecognized", () => {
    assert.equal(M.formatClouds([{ cover: "XYZ", base: 1000 }]), "XYZ 1000ft")
  })

  it("treats a missing cover as an empty string rather than throwing", () => {
    assert.equal(M.formatClouds([{ base: 1000 }]), " 1000ft")
    assert.equal(M.formatClouds([null]), "")
  })

  it("joins multiple layers with a comma", () => {
    assert.equal(
      M.formatClouds([{ cover: "FEW", base: 2500 }, { cover: "SCT", base: 3800 }]),
      "Few 2500ft, Scattered 3800ft"
    )
  })
})

describe("ageMinutes", () => {
  it("returns null for a null metar or missing obsTime", () => {
    assert.equal(M.ageMinutes(null, 1000), null)
    assert.equal(M.ageMinutes({}, 1000), null)
  })

  it("computes minutes since obsTime", () => {
    assert.equal(M.ageMinutes({ obsTime: 1000 }, 1600), 10)
  })
})

describe("formatAge", () => {
  it("returns '' for null/undefined/NaN", () => {
    assert.equal(M.formatAge(null), "")
    assert.equal(M.formatAge(undefined), "")
    assert.equal(M.formatAge(NaN), "")
  })

  it("formats under an hour in minutes", () => {
    assert.equal(M.formatAge(37), "37 min")
  })

  it("formats an hour or more as hours and minutes", () => {
    assert.equal(M.formatAge(90), "1h 30min")
  })

  it("omits the minutes when they're exactly 0", () => {
    assert.equal(M.formatAge(120), "2h")
  })
})

describe("isSameLocalDay", () => {
  it("is true for two timestamps on the same calendar day", () => {
    var morning = new Date(2026, 0, 15, 8, 0, 0).getTime() / 1000
    var evening = new Date(2026, 0, 15, 23, 0, 0).getTime() / 1000
    assert.equal(M.isSameLocalDay(morning, evening), true)
  })

  it("is false across a day boundary, even close in time", () => {
    var lateNight = new Date(2026, 0, 15, 23, 59, 0).getTime() / 1000
    var earlyNext = new Date(2026, 0, 16, 0, 1, 0).getTime() / 1000
    assert.equal(M.isSameLocalDay(lateNight, earlyNext), false)
  })

  it("is false across a month/year boundary", () => {
    var dec31 = new Date(2025, 11, 31, 12, 0, 0).getTime() / 1000
    var jan1 = new Date(2026, 0, 1, 12, 0, 0).getTime() / 1000
    assert.equal(M.isSameLocalDay(dec31, jan1), false)
  })
})

describe("lastUpdatedTier", () => {
  it("returns tier 'none' when there's no last-updated time yet", () => {
    assert.deepEqual(M.lastUpdatedTier(0, 1000), { tier: "none", minutes: null })
    assert.deepEqual(M.lastUpdatedTier(null, 1000), { tier: "none", minutes: null })
  })

  it("returns 'justNow' under a minute", () => {
    var now = Math.floor(Date.now() / 1000)
    assert.equal(M.lastUpdatedTier(now - 30, now).tier, "justNow")
  })

  it("returns 'minutesAgo' with a rounded minute count from 1 up to (not including) 5 minutes", () => {
    var now = Math.floor(Date.now() / 1000)
    var result = M.lastUpdatedTier(now - 150, now) // 2.5 min -> rounds to 3
    assert.equal(result.tier, "minutesAgo")
    assert.equal(result.minutes, 3)
  })

  it("returns 'today' from 5 minutes up to the next local-day boundary", () => {
    var now = new Date(2026, 0, 15, 12, 0, 0).getTime() / 1000
    var earlierToday = new Date(2026, 0, 15, 8, 0, 0).getTime() / 1000
    assert.equal(M.lastUpdatedTier(earlierToday, now).tier, "today")
  })

  it("returns 'other' once it's a different calendar day", () => {
    var now = new Date(2026, 0, 15, 8, 0, 0).getTime() / 1000
    var yesterday = new Date(2026, 0, 14, 20, 0, 0).getTime() / 1000
    assert.equal(M.lastUpdatedTier(yesterday, now).tier, "other")
  })
})
