const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("parseVisibilityFromTokens", () => {
  it("returns null when nothing follows the wind group", () => {
    assert.equal(M.parseVisibilityFromTokens(["27014KT"]), null)
  })

  it("returns null for an empty token list", () => {
    assert.equal(M.parseVisibilityFromTokens([]), null)
  })

  it("skips a variable-wind-direction group before the visibility group", () => {
    var result = M.parseVisibilityFromTokens(["27014G25KT", "240V300", "9999"])
    assert.equal(result.meters, 9999)
  })

  it("recognizes CAVOK", () => {
    assert.deepEqual(M.parseVisibilityFromTokens(["24012KT", "CAVOK"]), {
      meters: 10000, plus: true, lessThan: false, cavok: true
    })
  })

  it("parses an ICAO meters group, flagging plus only at 9999", () => {
    assert.deepEqual(M.parseVisibilityFromTokens(["27014KT", "9999"]), {
      meters: 9999, plus: true, lessThan: false, cavok: false
    })
    assert.deepEqual(M.parseVisibilityFromTokens(["27014KT", "4000"]), {
      meters: 4000, plus: false, lessThan: false, cavok: false
    })
  })

  it("parses an ICAO meters group with a minimum-visibility direction suffix", () => {
    var result = M.parseVisibilityFromTokens(["27014KT", "1400W"])
    assert.equal(result.meters, 1400)
  })

  it("parses a plain statute-mile group (10SM)", () => {
    var result = M.parseVisibilityFromTokens(["13005KT", "10SM"])
    assert.equal(result.meters, 10 * 1609.344)
    assert.equal(result.plus, false)
    assert.equal(result.lessThan, false)
  })

  it("parses a fractional statute-mile group (1/2SM)", () => {
    var result = M.parseVisibilityFromTokens(["18010KT", "1/2SM"])
    assert.equal(result.meters, 0.5 * 1609.344)
  })

  it("parses a whole-number-plus-fraction pair (1 1/2SM)", () => {
    var result = M.parseVisibilityFromTokens(["25006KT", "1", "1/2SM"])
    assert.equal(result.meters, 1.5 * 1609.344)
  })

  it("parses P6SM as greater-than", () => {
    var result = M.parseVisibilityFromTokens(["21013G23KT", "P6SM"])
    assert.equal(result.meters, 6 * 1609.344)
    assert.equal(result.plus, true)
    assert.equal(result.lessThan, false)
  })

  it("parses M1/4SM as less-than", () => {
    var result = M.parseVisibilityFromTokens(["18010KT", "M1/4SM"])
    assert.equal(result.meters, 0.25 * 1609.344)
    assert.equal(result.plus, false)
    assert.equal(result.lessThan, true)
  })

  it("returns null for a token that matches nothing", () => {
    assert.equal(M.parseVisibilityFromTokens(["27014KT", "SCT038"]), null)
  })

  it("returns null for a bare 'SM' with no leading number", () => {
    assert.equal(M.parseVisibilityFromTokens(["27014KT", "SM"]), null)
  })
})

describe("parseVisibilityFromRaw", () => {
  it("parses visibility out of a full raw METAR", () => {
    var result = M.parseVisibilityFromRaw("METAR EBAW 311550Z 27014G25KT 240V300 9999 SCT038 21/11 Q1014 NOSIG")
    assert.equal(result.meters, 9999)
  })
})

describe("parseVisibilityFromTafSegment", () => {
  it("parses visibility out of a TAF change-group segment", () => {
    var result = M.parseVisibilityFromTafSegment("TEMPO 3115/3116 4000 SHRA SCT015")
    assert.equal(result.meters, 4000)
  })
})
