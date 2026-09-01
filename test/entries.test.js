const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("buildByIcao", () => {
  it("returns {} for null/undefined", () => {
    assert.deepEqual(M.buildByIcao(null), {})
    assert.deepEqual(M.buildByIcao(undefined), {})
  })

  it("keys by uppercased icaoId", () => {
    var map = M.buildByIcao([{ icaoId: "ebaw", x: 1 }])
    assert.deepEqual(Object.keys(map), ["EBAW"])
  })

  it("skips an item with no icaoId", () => {
    assert.deepEqual(M.buildByIcao([{ x: 1 }]), {})
  })

  it("keeps the first sighting of a duplicate id", () => {
    var map = M.buildByIcao([{ icaoId: "EBAW", x: 1 }, { icaoId: "EBAW", x: 2 }])
    assert.equal(map.EBAW.x, 1)
  })
})

describe("buildEntries", () => {
  var freshMetar = { icaoId: "EBAW", fltCat: "VFR", obsTime: 1000, name: "Antwerp Intl", rawOb: "" }

  it("shows the loading dash while a manual refresh is in flight, regardless of other state", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { loading: true })
    assert.equal(out[0].letter, "–")
    assert.equal(out[0].category, "Refreshing…")
  })

  it("shows the ellipsis while waiting for the very first successful fetch", () => {
    var out = M.buildEntries(["EBAW"], {}, { everSucceeded: false })
    assert.equal(out[0].letter, "…")
    assert.equal(out[0].category, "Loading…")
  })

  it("shows 'unknown or invalid' when a code has never once appeared in a successful fetch", () => {
    var out = M.buildEntries(["EBXX"], {}, { everSucceeded: true })
    assert.equal(out[0].letter, "?")
    assert.equal(out[0].category, "Unknown or invalid station")
  })

  it("shows 'missing from latest report' for a code seen before but absent this time", () => {
    var out = M.buildEntries(["EBXX"], {}, { everSucceeded: true, everSeenIcaos: { EBXX: true } })
    assert.equal(out[0].letter, "?")
    assert.equal(out[0].category, "Missing from latest report")
  })

  it("shows the normal letter/category for a fresh, in-range station", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { everSucceeded: true, nowSeconds: 1300, maxAgeMinutes: 40 })
    assert.equal(out[0].letter, "V")
    assert.equal(out[0].category, "VFR")
    assert.equal(out[0].stationName, "Antwerp Intl")
    assert.equal(out[0].stale, false)
  })

  it("shows offline as ? with the last-known category hinted", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { offline: true, everSucceeded: true, nowSeconds: 1300, maxAgeMinutes: 40 })
    assert.equal(out[0].letter, "?")
    assert.match(out[0].category, /^No data \(offline, last known VFR\)$/)
    assert.equal(out[0].stale, true)
    assert.ok(out[0].metar) // kept for the popup, clearly marked stale
  })

  it("shows offline as plain 'No data' when there was never a metar for this station", () => {
    var out = M.buildEntries(["EBXX"], {}, { offline: true, everSucceeded: true })
    assert.equal(out[0].category, "No data")
  })

  it("ages a station out once its own obsTime exceeds maxAgeMinutes, even though the fetch succeeded", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { everSucceeded: true, nowSeconds: 1000 + 41 * 60, maxAgeMinutes: 40 })
    assert.equal(out[0].letter, "?")
    assert.match(out[0].category, /^No data \(last report 41 min ago\)$/)
  })

  it("does not hint a last-known category for an aged-out (expired) station", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { everSucceeded: true, nowSeconds: 1000 + 41 * 60, maxAgeMinutes: 40 })
    assert.doesNotMatch(out[0].category, /last known/)
  })

  it("does not age out when maxAgeMinutes is falsy (disabled)", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { everSucceeded: true, nowSeconds: 1000 + 1000 * 60, maxAgeMinutes: 0 })
    assert.equal(out[0].letter, "V")
  })

  it("does not age out when nowSeconds is not supplied", () => {
    var out = M.buildEntries(["EBAW"], { EBAW: freshMetar }, { everSucceeded: true, maxAgeMinutes: 40 })
    assert.equal(out[0].letter, "V")
    assert.equal(out[0].age, null)
  })

  it("defaults status to {} when not supplied at all", () => {
    var out = M.buildEntries(["EBXX"], {})
    assert.equal(out[0].letter, "…")
  })

  it("defaults stationName to '' when the metar has no name", () => {
    var noName = { icaoId: "EBAW", fltCat: "VFR", obsTime: 1000 }
    var out = M.buildEntries(["EBAW"], { EBAW: noName }, { everSucceeded: true, nowSeconds: 1300, maxAgeMinutes: 40 })
    assert.equal(out[0].stationName, "")
  })

  it("processes multiple airports independently, in list order", () => {
    var out = M.buildEntries(["EBAW", "EBXX"], { EBAW: freshMetar }, { everSucceeded: true, nowSeconds: 1300, maxAgeMinutes: 40 })
    assert.equal(out.length, 2)
    assert.equal(out[0].icao, "EBAW")
    assert.equal(out[1].icao, "EBXX")
    assert.equal(out[1].letter, "?")
  })
})

describe("summaryLine", () => {
  it("returns '' for no entries", () => {
    assert.equal(M.summaryLine([]), "")
  })

  it("joins entries with a middle dot", () => {
    var entries = [{ icao: "EBAW", category: "VFR" }, { icao: "EBBR", category: "MVFR" }]
    assert.equal(M.summaryLine(entries), "EBAW VFR · EBBR MVFR")
  })
})
