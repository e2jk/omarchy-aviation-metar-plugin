const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("ceilingFtFromClouds", () => {
  it("returns null for no clouds", () => {
    assert.equal(M.ceilingFtFromClouds(null), null)
    assert.equal(M.ceilingFtFromClouds(undefined), null)
    assert.equal(M.ceilingFtFromClouds([]), null)
  })

  it("ignores FEW/SCT layers (they don't count as a ceiling)", () => {
    assert.equal(M.ceilingFtFromClouds([{ cover: "FEW", base: 2500 }, { cover: "SCT", base: 3800 }]), null)
  })

  it("uses the lowest BKN/OVC/VV layer", () => {
    assert.equal(M.ceilingFtFromClouds([{ cover: "OVC", base: 800 }]), 800)
    assert.equal(M.ceilingFtFromClouds([{ cover: "BKN", base: 800 }]), 800)
    assert.equal(M.ceilingFtFromClouds([{ cover: "VV", base: 200 }]), 200)
  })

  it("takes the minimum across multiple ceiling-forming layers", () => {
    assert.equal(M.ceilingFtFromClouds([{ cover: "BKN", base: 2000 }, { cover: "OVC", base: 900 }]), 900)
  })

  it("skips a layer with a non-numeric base", () => {
    assert.equal(M.ceilingFtFromClouds([{ cover: "BKN", base: "n/a" }]), null)
  })

  it("skips a layer with a missing cover", () => {
    assert.equal(M.ceilingFtFromClouds([{ base: 800 }]), null)
  })
})

describe("classifyFlightCategory", () => {
  it("treats a missing ceiling as unlimited and missing/NaN visibility as unlimited", () => {
    assert.equal(M.classifyFlightCategory(null, null), "VFR")
    assert.equal(M.classifyFlightCategory(undefined, undefined), "VFR")
    assert.equal(M.classifyFlightCategory(5000, NaN), "VFR")
  })

  it("classifies LIFR on ceiling or visibility", () => {
    assert.equal(M.classifyFlightCategory(400, 10), "LIFR")
    assert.equal(M.classifyFlightCategory(5000, 0.5), "LIFR")
  })

  it("classifies IFR on ceiling or visibility", () => {
    assert.equal(M.classifyFlightCategory(700, 10), "IFR")
    assert.equal(M.classifyFlightCategory(5000, 2), "IFR")
  })

  it("classifies MVFR on ceiling or visibility", () => {
    assert.equal(M.classifyFlightCategory(2000, 10), "MVFR")
    assert.equal(M.classifyFlightCategory(5000, 4), "MVFR")
  })

  it("classifies VFR when both are comfortably clear", () => {
    assert.equal(M.classifyFlightCategory(5000, 10), "VFR")
  })

  it("handles the exact boundary values", () => {
    assert.equal(M.classifyFlightCategory(500, 10), "IFR") // ceiling === 500 is not < 500
    assert.equal(M.classifyFlightCategory(5000, 1), "IFR") // vis === 1 is not < 1
    assert.equal(M.classifyFlightCategory(1000, 10), "MVFR") // ceiling === 1000 is not < 1000
    assert.equal(M.classifyFlightCategory(5000, 3), "MVFR") // vis === 3 is not < 3
    assert.equal(M.classifyFlightCategory(3000, 10), "MVFR") // ceiling === 3000 is <= 3000
    assert.equal(M.classifyFlightCategory(5000, 5), "MVFR") // vis === 5 is <= 5
    assert.equal(M.classifyFlightCategory(3001, 5.1), "VFR")
  })
})

describe("categoryForMetar", () => {
  it("returns '' for a null metar", () => {
    assert.equal(M.categoryForMetar(null), "")
  })

  it("returns the reported fltCat directly when valid", () => {
    for (const cat of ["VFR", "MVFR", "IFR", "LIFR"]) {
      assert.equal(M.categoryForMetar({ fltCat: cat }), cat)
    }
  })

  it("is case-insensitive on fltCat", () => {
    assert.equal(M.categoryForMetar({ fltCat: "vfr" }), "VFR")
  })

  it("falls back to classification when fltCat is missing or unrecognized", () => {
    var metar = {
      fltCat: "",
      rawOb: "METAR EBAW 311550Z 27014KT 9999 SCT038 21/11 Q1014",
      clouds: [{ cover: "SCT", base: 3800 }]
    }
    assert.equal(M.categoryForMetar(metar), "VFR")

    var garbage = { fltCat: "BOGUS", rawOb: "METAR EBAW 311550Z 27014KT 9999 SCT038 21/11 Q1014", clouds: [] }
    assert.equal(M.categoryForMetar(garbage), "VFR")
  })

  it("falls back to the API's visib field when raw text can't be parsed", () => {
    var metar = { fltCat: "", rawOb: "", visib: "6+", clouds: [] }
    assert.equal(M.categoryForMetar(metar), "VFR")
  })

  it("falls back to LIFR when both ceiling and visibility are poor", () => {
    var metar = {
      fltCat: "",
      rawOb: "METAR KBOS 311554Z 18010KT M1/4SM FG VV003 15/14 A3005",
      clouds: [{ cover: "VV", base: 300 }]
    }
    assert.equal(M.categoryForMetar(metar), "LIFR")
  })
})
