const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("parseAirportList", () => {
  it("returns [] for empty/undefined/null input", () => {
    assert.deepEqual(M.parseAirportList(""), [])
    assert.deepEqual(M.parseAirportList(undefined), [])
    assert.deepEqual(M.parseAirportList(null), [])
  })

  it("splits on commas, spaces, and newlines, uppercasing and trimming", () => {
    assert.deepEqual(M.parseAirportList(" ebaw, ebbr\nebci "), ["EBAW", "EBBR", "EBCI"])
  })

  it("keeps only exactly-4-character codes (the ICAO format)", () => {
    assert.deepEqual(M.parseAirportList("AB,ABC,ABCD,ABCDE,ABCDEF"), ["ABCD"])
  })

  it("drops codes with non-alphanumeric characters", () => {
    assert.deepEqual(M.parseAirportList("EB-W,EBAW"), ["EBAW"])
  })

  it("deduplicates, keeping first occurrence's order", () => {
    assert.deepEqual(M.parseAirportList("EBAW,EBBR,EBAW"), ["EBAW", "EBBR"])
  })

  it("caps at 12 airports", () => {
    var codes = []
    for (var i = 0; i < 15; i++) codes.push("A" + String(i).padStart(3, "0"))
    var result = M.parseAirportList(codes.join(","))
    assert.equal(result.length, 12)
  })
})

describe("letterForCategory", () => {
  it("maps each category to its letter", () => {
    assert.equal(M.letterForCategory("VFR"), "V")
    assert.equal(M.letterForCategory("MVFR"), "M")
    assert.equal(M.letterForCategory("IFR"), "I")
    assert.equal(M.letterForCategory("LIFR"), "L")
  })

  it("is case-insensitive", () => {
    assert.equal(M.letterForCategory("vfr"), "V")
  })

  it("returns ? for unknown/empty/undefined", () => {
    assert.equal(M.letterForCategory("BOGUS"), "?")
    assert.equal(M.letterForCategory(""), "?")
    assert.equal(M.letterForCategory(undefined), "?")
  })
})

describe("parseVisib", () => {
  it("returns null miles for undefined/null/empty", () => {
    assert.deepEqual(M.parseVisib(undefined), { miles: null, plus: false })
    assert.deepEqual(M.parseVisib(null), { miles: null, plus: false })
    assert.deepEqual(M.parseVisib(""), { miles: null, plus: false })
  })

  it("passes a numeric value through directly", () => {
    assert.deepEqual(M.parseVisib(2.49), { miles: 2.49, plus: false })
  })

  it("parses a plus-suffixed value", () => {
    assert.deepEqual(M.parseVisib("6+"), { miles: 6, plus: true })
  })

  it("parses a fraction", () => {
    assert.deepEqual(M.parseVisib("1/2"), { miles: 0.5, plus: false })
  })

  it("returns null miles for an unparseable fraction", () => {
    assert.deepEqual(M.parseVisib("a/b"), { miles: null, plus: false })
  })

  it("parses a plain numeric string", () => {
    assert.deepEqual(M.parseVisib("2.49"), { miles: 2.49, plus: false })
  })

  it("returns null miles for garbage", () => {
    assert.deepEqual(M.parseVisib("garbage"), { miles: null, plus: false })
  })
})

describe("significantTokens", () => {
  it("returns [] for empty/undefined input", () => {
    assert.deepEqual(M.significantTokens(""), [])
    assert.deepEqual(M.significantTokens(undefined), [])
  })

  it("strips METAR/SPECI/TAF, ICAO id, and DDHHMMZ time", () => {
    assert.deepEqual(M.significantTokens("METAR EBAW 311550Z 9999"), ["9999"])
    assert.deepEqual(M.significantTokens("SPECI EBAW 311550Z 9999"), ["9999"])
    assert.deepEqual(M.significantTokens("TAF EBAW 311550Z 9999"), ["9999"])
  })

  it("strips AUTO/COR/AMD/NIL/CNL modifiers, including several in a row", () => {
    assert.deepEqual(M.significantTokens("METAR EBAW 311550Z AUTO COR 9999"), ["9999"])
  })

  it("leaves unrecognized leading tokens alone", () => {
    assert.deepEqual(M.significantTokens("OVC038 21/11"), ["OVC038", "21/11"])
  })

  it("misreads a bare 4-alphanumeric-char leading token as an ICAO id (positional, not semantic)", () => {
    // significantTokens has no way to tell a real station id from a
    // visibility group in first position — it only exists to strip a
    // known header shape off a full METAR/TAF, which always starts with
    // METAR/SPECI/TAF, never a bare visibility group.
    assert.deepEqual(M.significantTokens("9999 SCT038"), ["SCT038"])
  })
})

describe("tafSegmentSignificantTokens", () => {
  it("strips a bare PROBnn", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("PROB30 3115/3116 4000"), ["4000"])
  })

  it("strips BECMG and its validity window", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("BECMG 3118/3120 25008KT"), ["25008KT"])
  })

  it("strips TEMPO and its validity window", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("TEMPO 3115/3116 4000"), ["4000"])
  })

  it("strips FMddhhmm (no separate validity window)", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("FM010100 14003KT P6SM"), ["14003KT", "P6SM"])
  })

  it("strips a combined PROBnn TEMPO plus window", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("PROB30 TEMPO 3115/3116 4000"), ["4000"])
  })

  it("leaves tokens alone when there is no recognizable header", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens("9999 SCT020"), ["9999", "SCT020"])
  })

  it("returns [] for undefined/null input", () => {
    assert.deepEqual(M.tafSegmentSignificantTokens(undefined), [])
    assert.deepEqual(M.tafSegmentSignificantTokens(null), [])
  })
})

describe("tafBaseSignificantTokens", () => {
  it("strips the base period's overall validity window", () => {
    assert.deepEqual(
      M.tafBaseSignificantTokens("TAF EBAW 311400Z 3115/3124 27015G25KT 9999"),
      ["27015G25KT", "9999"]
    )
  })

  it("leaves tokens alone when there is no validity window", () => {
    assert.deepEqual(M.tafBaseSignificantTokens("TAF EBAW 311400Z 27015G25KT"), ["27015G25KT"])
  })
})

describe("tafRawSegments", () => {
  it("returns [] for an empty/undefined TAF", () => {
    assert.deepEqual(M.tafRawSegments(""), [])
    assert.deepEqual(M.tafRawSegments(undefined), [])
  })

  it("returns a single segment when there are no change groups", () => {
    assert.deepEqual(M.tafRawSegments("TAF EBAW 311400Z 27015KT 9999 SCT020"), [
      "TAF EBAW 311400Z 27015KT 9999 SCT020"
    ])
  })

  it("treats PROBnn TEMPO as one combined boundary, not two", () => {
    var raw = "TAF EBAW 311400Z 27015KT 9999 SCT020 PROB30 TEMPO 3115/3116 4000 SHRA BECMG 3118/3120 25008KT"
    var segments = M.tafRawSegments(raw)
    assert.equal(segments.length, 3)
    assert.equal(segments[0], "TAF EBAW 311400Z 27015KT 9999 SCT020")
    assert.equal(segments[1], "PROB30 TEMPO 3115/3116 4000 SHRA")
    assert.equal(segments[2], "BECMG 3118/3120 25008KT")
  })

  it("splits on FM/BECMG/TEMPO/bare PROBnn", () => {
    var raw = "TAF KATL 311725Z 07007KT P6SM FM010100 14003KT P6SM FM011500 08005KT P6SM"
    var segments = M.tafRawSegments(raw)
    assert.equal(segments.length, 3)
  })
})
