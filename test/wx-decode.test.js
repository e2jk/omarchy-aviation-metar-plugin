const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("decodeWxToken", () => {
  it("returns null for an unrecognized code", () => {
    assert.equal(M.decodeWxToken("ZZ"), null)
  })

  it("decodes a bare phenomenon at moderate intensity", () => {
    assert.equal(M.decodeWxToken("RA"), "rain")
  })

  it("decodes light and heavy intensity prefixes", () => {
    assert.equal(M.decodeWxToken("-RA"), "light rain")
    assert.equal(M.decodeWxToken("+RA"), "heavy rain")
  })

  it("decodes the vicinity (VC) prefix", () => {
    assert.equal(M.decodeWxToken("VCSH"), "showers in the vicinity")
  })

  it("does not recognize an intensity prefix before VC (not a real METAR combination — VC replaces intensity, it doesn't follow it)", () => {
    assert.equal(M.decodeWxToken("+VCTS"), null)
  })

  it("special-cases thunderstorm with a phenomenon", () => {
    assert.equal(M.decodeWxToken("TSRA"), "thunderstorm with rain")
  })

  it("special-cases showers with a phenomenon", () => {
    assert.equal(M.decodeWxToken("SHRA"), "rain showers")
  })

  it("joins a non-TS/SH descriptor with its phenomenon", () => {
    assert.equal(M.decodeWxToken("FZFG"), "freezing fog")
    assert.equal(M.decodeWxToken("BLSN"), "blowing snow")
    assert.equal(M.decodeWxToken("MIFG"), "shallow fog")
    assert.equal(M.decodeWxToken("BCFG"), "patches of fog")
  })

  it("joins multiple phenomena with 'and'", () => {
    assert.equal(M.decodeWxToken("RASN"), "rain and snow")
  })

  it("decodes a descriptor with no phenomenon", () => {
    assert.equal(M.decodeWxToken("TS"), "thunderstorm")
  })

  it("stops at the first unrecognized 2-character code", () => {
    assert.equal(M.decodeWxToken("RAZZ"), "rain")
  })
})

describe("decodeWxString", () => {
  it("returns '' for a falsy value", () => {
    assert.equal(M.decodeWxString(null), "")
    assert.equal(M.decodeWxString(""), "")
  })

  it("decodes and joins multiple tokens", () => {
    assert.equal(M.decodeWxString("SHRA VCTS"), "rain showers, thunderstorm in the vicinity")
  })

  it("drops unrecognized tokens rather than failing", () => {
    assert.equal(M.decodeWxString("RA ZZ"), "rain")
  })
})

describe("decodeMetarText", () => {
  it("returns '' for a null metar", () => {
    assert.equal(M.decodeMetarText(null, false), "")
  })

  it("describes calm wind", () => {
    var metar = { wspd: 0, temp: 20, dewp: 10, altim: 1013, rawOb: "" }
    assert.match(M.decodeMetarText(metar, false), /^Wind calm\./)
  })

  it("omits the wind sentence entirely when wspd is missing", () => {
    var metar = { temp: 20, dewp: 10, altim: 1013, rawOb: "" }
    assert.doesNotMatch(M.decodeMetarText(metar, false), /Wind/)
  })

  it("describes CAVOK distinctly and skips the separate clouds line", () => {
    var metar = {
      wdir: 240, wspd: 12, temp: 19, dewp: 10, altim: 1015,
      rawOb: "METAR EHAM 311555Z 24012KT CAVOK 19/10 Q1015 NOSIG"
    }
    var text = M.decodeMetarText(metar, false)
    assert.match(text, /CAVOK/)
    assert.doesNotMatch(text, /Clouds:/)
  })

  it("includes a visibility line when parseable", () => {
    var metar = {
      wdir: 270, wspd: 14, temp: 21, dewp: 11, altim: 1014, clouds: [{ cover: "SCT", base: 3800 }],
      rawOb: "METAR EBAW 311550Z 27014KT 9999 SCT038 21/11 Q1014"
    }
    assert.match(M.decodeMetarText(metar, false), /Visibility 10\+ km/)
  })

  it("includes decoded weather when wxString is present", () => {
    var metar = {
      wdir: 220, wspd: 12, wxString: "SHRA", temp: 18, dewp: 15, altim: 1009, clouds: [{ cover: "BKN", base: 1800 }],
      rawOb: "METAR EDDF 311550Z 22012KT 6000 SHRA BKN018 18/15 Q1009 NOSIG"
    }
    assert.match(M.decodeMetarText(metar, false), /Rain showers/)
  })

  it("appends the NOSIG/BECMG/TEMPO trend sentence", () => {
    var base = { wspd: 0, temp: 20, dewp: 10, altim: 1013 }
    assert.match(M.decodeMetarText({ ...base, rawOb: "... NOSIG" }, false), /No significant change expected\.$/)
    assert.match(M.decodeMetarText({ ...base, rawOb: "... BECMG 3118/3120" }, false), /Conditions expected to become different/)
    assert.match(M.decodeMetarText({ ...base, rawOb: "... TEMPO 3115/3116" }, false), /Temporary fluctuations expected/)
    assert.doesNotMatch(M.decodeMetarText({ ...base, rawOb: "..." }, false), /expected/)
  })
})

describe("decodeTafText", () => {
  it("returns '' when there is no TAF or no fcsts", () => {
    assert.equal(M.decodeTafText(null, false, null), "")
    assert.equal(M.decodeTafText({ fcsts: [] }, false, null), "")
    assert.equal(M.decodeTafText({}, false, null), "")
  })

  function fmtTime(sec) {
    return new Date(sec * 1000).toISOString().slice(11, 16) + "Z"
  }

  it("decodes a base period, a PROB/TEMPO group, and a BECMG group with no restated visibility/clouds", () => {
    var taf = {
      rawTAF: "TAF EBBR 311100Z 3112/0118 23015G25KT 9999 SCT020 TEMPO 3112/3118 25020G35KT 4000 SHRA SCT015 BKN020CB BECMG 3118/3120 26008KT ",
      fcsts: [
        { timeFrom: 1000, timeTo: 2000, fcstChange: null, probability: null, wdir: 230, wspd: 15, wgst: 25, visib: "6+", clouds: [{ cover: "SCT", base: 2000 }] },
        { timeFrom: 1000, timeTo: 1500, fcstChange: "TEMPO", probability: null, wdir: 250, wspd: 20, wgst: 35, visib: 2.49, wxString: "SHRA", clouds: [{ cover: "SCT", base: 1500 }, { cover: "BKN", base: 2000 }] },
        { timeFrom: 1500, timeTo: 3000, fcstChange: "BECMG", probability: null, wdir: 260, wspd: 8, wgst: null, visib: "6+", clouds: [{ cover: "SCT", base: 2000 }] }
      ]
    }
    var text = M.decodeTafText(taf, false, fmtTime)
    assert.match(text, /^Initial period/)
    assert.match(text, /visibility 10\+ km/)
    assert.match(text, /Temporarily/)
    assert.match(text, /visibility 4 km/)
    assert.match(text, /Becoming/)
    // The BECMG group's own raw text has no visibility/cloud group, so
    // neither should leak into its decoded line even though the API
    // backfills them into fcsts[2].visib/.clouds.
    var becmgLine = text.split(". ").filter((l) => l.indexOf("Becoming") === 0)[0]
    assert.doesNotMatch(becmgLine, /visibility/)
    assert.doesNotMatch(becmgLine, /scattered/)
  })

  it("labels a probability percentage", () => {
    var taf = {
      rawTAF: "TAF EBAW 311400Z 3115/3124 27015KT 9999 SCT020 PROB30 TEMPO 3115/3116 4000 SHRA",
      fcsts: [
        { timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 270, wspd: 15, visib: "6+", clouds: [] },
        { timeFrom: 1000, timeTo: 1500, fcstChange: "TEMPO", probability: 30, wdir: null, wspd: null, visib: 2.49, wxString: "SHRA", clouds: [] }
      ]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /Temporarily \(30% chance\)/)
  })

  it("labels an FM group and a mid-list unlabeled group as 'Then'", () => {
    var taf = {
      rawTAF: "TAF KATL 311725Z 07007KT P6SM FM010100 14003KT P6SM",
      fcsts: [
        { timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 70, wspd: 7, visib: "6+", clouds: [] },
        { timeFrom: 2000, timeTo: 3000, fcstChange: "FM", wdir: 140, wspd: 3, visib: "6+", clouds: [] },
        { timeFrom: 3000, timeTo: 4000, fcstChange: undefined, wdir: 80, wspd: 5, visib: "6+", clouds: [] }
      ]
    }
    var text = M.decodeTafText(taf, false, fmtTime)
    assert.match(text, /From \(/)
    assert.match(text, /Then \(/)
  })

  it("shows CAVOK for a segment that codes it", () => {
    var taf = {
      rawTAF: "TAF EHAM 311400Z 3115/3124 24012KT CAVOK",
      fcsts: [{ timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 240, wspd: 12, visib: "6+", clouds: [] }]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /CAVOK/)
  })

  it("falls back to 'no significant change' when a period has nothing to say", () => {
    var taf = {
      rawTAF: "TAF EBAW 311400Z 3115/3124 27015KT 9999 SCT020 BECMG 3118/3120 26008KT",
      fcsts: [
        { timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 270, wspd: 15, visib: "6+", clouds: [{ cover: "SCT", base: 2000 }] },
        { timeFrom: 2000, timeTo: 3000, fcstChange: "BECMG", wdir: null, wspd: null, visib: null, clouds: [] }
      ]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /no significant change/)
  })

  it("omits the time window when formatTime is not supplied", () => {
    var taf = {
      rawTAF: "TAF EBAW 311400Z 3115/3124 27015KT 9999 SCT020",
      fcsts: [{ timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 270, wspd: 15, visib: "6+", clouds: [] }]
    }
    var text = M.decodeTafText(taf, false, null)
    assert.doesNotMatch(text, /\(/)
  })

  it("formats visibility in imperial units and sub-1000m segments in meters", () => {
    var taf = {
      rawTAF: "TAF LFPO 311400Z 3115/3124 25008KT 0350 FG",
      fcsts: [{ timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 250, wspd: 8, visib: 0.25, clouds: [] }]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /visibility 350m/)
    assert.match(M.decodeTafText(taf, true, fmtTime), /visibility/)
  })

  it("prefixes < for a less-than segment visibility", () => {
    var taf = {
      rawTAF: "TAF KBOS 311554Z 3115/3124 18010KT M1/4SM FG",
      fcsts: [{ timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 180, wspd: 10, visib: 0.25, wxString: "FG", clouds: [] }]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /visibility <\d/)
  })

  it("rounds an exact 10SM to 10 (val >= 10 boundary, both units)", () => {
    var taf = {
      rawTAF: "TAF KJFK 311551Z 3115/3124 13005KT 10SM",
      fcsts: [{ timeFrom: 1000, timeTo: 2000, fcstChange: null, wdir: 130, wspd: 5, visib: 10, clouds: [] }]
    }
    assert.match(M.decodeTafText(taf, false, fmtTime), /visibility 16 km/)
    assert.match(M.decodeTafText(taf, true, fmtTime), /visibility 10 mi/)
  })
})
