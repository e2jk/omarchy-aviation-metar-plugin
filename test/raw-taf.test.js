const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

// Shape returned by /api/data/taf?ids=EBAW,EBBR&format=raw.
const raw = "TAF EBAW 111400Z 1115/1124 04004KT 6000 SCT004 BKN006 \n"
  + "  PROB40 \n  TEMPO 1115/1124 2500 RADZ BR BKN004"
const jsonTaf = { icaoId: "EBAW", rawTAF: raw.replace(/\s+/g, " ") }

describe("provider-formatted raw TAFs", () => {
  it("preserves change-group newlines and indentation without reformatting", () => {
    assert.equal(M.parseRawTafs(raw).EBAW, raw)
    assert.equal(M.formattedTafText(jsonTaf, M.parseRawTafs(raw)), raw)
  })

  it("separates stations and keeps the first forecast when duplicate ids occur", () => {
    const second = raw.replaceAll("EBAW", "EBBR")
    const map = M.parseRawTafs(second + "\n" + raw + "\n" + raw.replace("6000", "7000"))
    assert.deepEqual(Object.keys(map), ["EBBR", "EBAW"])
    assert.equal(map.EBAW, raw)
    assert.equal(map.EBBR, second)
  })

  it("handles amended/corrected headers, optional TAF prefix, and CRLF", () => {
    for (const header of ["TAF AMD EBAW", "TAF COR EBAW", "EBAW"]) {
      const text = raw.replace("TAF EBAW", header).replaceAll("\n", "\r\n")
      const taf = { icaoId: "ebaw", rawTAF: text.replace(/\s+/g, " ") }
      assert.equal(M.formattedTafText(taf, M.parseRawTafs(text)), text)
    }
  })

  it("falls back to JSON raw text while formatting is absent or for a different forecast", () => {
    assert.equal(M.formattedTafText(jsonTaf, {}), jsonTaf.rawTAF)
    assert.equal(M.formattedTafText(jsonTaf, { EBAW: raw.replace("6000", "7000") }), jsonTaf.rawTAF)
    assert.equal(M.formattedTafText({ rawTAF: "No identifier" }, {}), "No identifier")
    assert.equal(M.formattedTafText(null, {}), "")
  })

  it("rejects non-text, oversized responses, and unrecognized bodies", () => {
    for (const text of [null, {}, "", "invalid response", "x".repeat(M.MAX_RESPONSE_BYTES + 1)]) {
      assert.deepEqual(M.parseRawTafs(text), {})
    }
    assert.deepEqual(M.parseRawTafs(raw + "x".repeat(8000)), {})
  })

  it("retains no more than the existing API item cap", () => {
    const text = Array.from({ length: 60 }, (_, i) => raw.replaceAll("EBAW", "A" + String(i).padStart(3, "0"))).join("\n")
    const map = M.parseRawTafs(text)
    assert.equal(Object.keys(map).length, 50)
    assert.ok(map.A049)
    assert.equal(map.A050, undefined)
  })
})
