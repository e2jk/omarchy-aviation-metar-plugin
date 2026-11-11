const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

// Captured shape from the official format=decoded endpoint. We separate
// station blocks, never interpret or regenerate their weather wording.
const raw = "METAR EBAW 111520Z 05004KT 2500 -DZRA BKN004 OVC018 07/06 Q1002 TEMPO 4000"
const block = "METAR for EBAW (Antwerp Intl, VA, BE) observed at 1520 UTC 11 Nov 2026\n"
  + "  Text: " + raw + "\n  Temperature: 7C (44.6F)\n  Visibility: 1.55 sm\n"

describe("API-decoded METAR blocks", () => {
  it("keeps the provider's wording and embedded raw report verbatim", () => {
    const parsed = M.parseDecodedMetars(block)
    assert.deepEqual(parsed.EBAW, { rawOb: raw, text: block.trim() })
  })

  it("separates reordered stations, Windows line endings, and duplicate reports", () => {
    const second = block.replaceAll("EBAW", "LFQQ")
    const parsed = M.parseDecodedMetars((second + block + block).replaceAll("\n", "\r\n"))
    assert.deepEqual(Object.keys(parsed), ["LFQQ", "EBAW"])
    assert.equal(parsed.EBAW.rawOb, raw)
    assert.equal(parsed.EBAW.text, block.trim().replaceAll("\n", "\r\n"))
  })

  it("rejects non-text, oversized responses, empty and unrecognized bodies", () => {
    for (const input of [null, {}, "", "unexpected body", "x".repeat(M.MAX_RESPONSE_BYTES + 1)]) {
      assert.deepEqual(M.parseDecodedMetars(input), {})
    }
  })

  it("rejects blocks without raw text or with oversized text instead of truncating", () => {
    const header = "METAR for EBAW (Antwerp) observed now\n"
    assert.deepEqual(M.parseDecodedMetars(header + "  Temperature: 7C"), {})
    assert.deepEqual(M.parseDecodedMetars(header + "  Text: " + "x".repeat(2001)), {})
    assert.deepEqual(M.parseDecodedMetars(block + "x".repeat(8000)), {})
  })

  it("bounds station count before retaining explanations", () => {
    const blocks = Array.from({ length: 60 }, (_, i) => block.replaceAll("EBAW", "A" + String(i).padStart(3, "0")))
    const parsed = M.parseDecodedMetars(blocks.join(""))
    assert.equal(Object.keys(parsed).length, 50)
    assert.ok(parsed.A049)
    assert.equal(parsed.A050, undefined)
  })

  it("does not interpret markup-shaped provider text", () => {
    const parsed = M.parseDecodedMetars(block + '  Note: <img src="https://example.invalid">')
    assert.match(parsed.EBAW.text, /<img/)
  })
})

describe("matching explanations to the displayed observation", () => {
  it("shows an explanation only for the exact same raw report", () => {
    const decoded = M.parseDecodedMetars(block)
    const explanation = M.decodedMetarText({ icaoId: "ebaw", rawOb: raw }, decoded)
    assert.equal(explanation, block.replace("  Text: " + raw + "\n", "").trim())
    assert.doesNotMatch(explanation, /Text: METAR/)
    assert.equal(decoded.EBAW.rawOb, raw)
    assert.equal(M.decodedMetarText({ icaoId: "EBAW", rawOb: raw + " NOSIG" }, decoded), "Decoded METAR unavailable for this report.")
  })

  it("handles a missing station, identifier, or observation honestly", () => {
    assert.equal(M.decodedMetarText(null, {}), "")
    assert.equal(M.decodedMetarText({}, {}), "Decoded METAR unavailable for this report.")
    assert.equal(M.decodedMetarText({ icaoId: "EBBR", rawOb: raw }, M.parseDecodedMetars(block)), "Decoded METAR unavailable for this report.")
  })
})
