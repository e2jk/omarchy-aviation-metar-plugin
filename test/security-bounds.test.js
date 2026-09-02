// Regression coverage for the bounds/sanitization added in response to the
// marketplace security review on the plugin submission issue: an unbounded
// fetch response, an unbounded remote schema/collection, and an unbounded
// `airports` setting were all flagged as ways a faulty or compromised
// aviationweather.gov response (or a corrupt config value) could make this
// shell retain/render/allocate far more than any real input ever needs.
const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const { spawn } = require("node:child_process")
const http = require("node:http")
const M = require("../Model.js")

describe("airports setting is bounded before parsing", () => {
  it("truncates a raw value far longer than any real airport list before splitting", () => {
    // A single 4001-character token followed by ",EBAW" — if the raw value
    // weren't bounded before splitting, EBAW would still be found after the
    // giant garbage token. Bounded to 4000 chars, the comma (at index 4001)
    // and everything after it is sliced away, so EBAW never gets a chance
    // to be seen as a separate token at all.
    var raw = "X".repeat(4001) + ",EBAW"
    assert.deepEqual(M.parseAirportList(raw), [])
    assert.equal(M.invalidAirportCount(raw), 1)
  })
})

describe("invalidAirportEntries / invalidAirportCount", () => {
  it("caps the number of retained/rendered entries, but invalidAirportCount reports the true total", () => {
    var codes = []
    for (var i = 0; i < 25; i++) codes.push("badcode" + i) // 25 distinct, wrong-length (7-8 char) entries
    var raw = codes.join(",")
    var entries = M.invalidAirportEntries(raw)
    assert.equal(entries.length, 20)
    assert.equal(M.invalidAirportCount(raw), 25)
  })

  it("truncates an individual entry longer than 40 characters", () => {
    var longToken = "y".repeat(50)
    var entries = M.invalidAirportEntries(longToken)
    assert.equal(entries.length, 1)
    assert.equal(entries[0], "Y".repeat(40) + "…")
  })

  it("leaves a short invalid entry untouched", () => {
    assert.deepEqual(M.invalidAirportEntries("bad"), ["BAD"])
  })
})

describe("sanitizeApiList", () => {
  it("returns [] for a non-array response", () => {
    assert.deepEqual(M.sanitizeApiList(null), [])
    assert.deepEqual(M.sanitizeApiList(undefined), [])
    assert.deepEqual(M.sanitizeApiList("not an array"), [])
    assert.deepEqual(M.sanitizeApiList({ 0: "x", length: 1 }), [])
  })

  it("passes a small array through unchanged", () => {
    var list = [{ icaoId: "EBAW" }, { icaoId: "EBBR" }]
    assert.deepEqual(M.sanitizeApiList(list), list)
  })

  it("caps an oversized array at 50 items", () => {
    var list = []
    for (var i = 0; i < 60; i++) list.push({ icaoId: "A" + i })
    var result = M.sanitizeApiList(list)
    assert.equal(result.length, 50)
    assert.equal(result[0].icaoId, "A0")
  })
})

describe("sanitizeMetarItem", () => {
  it("returns null for a non-object item", () => {
    assert.equal(M.sanitizeMetarItem(null), null)
    assert.equal(M.sanitizeMetarItem(undefined), null)
    assert.equal(M.sanitizeMetarItem("not an object"), null)
    assert.equal(M.sanitizeMetarItem(42), null)
  })

  it("whitelists known fields and drops everything else", () => {
    var out = M.sanitizeMetarItem({
      icaoId: "ebaw", name: "Antwerp Intl", fltCat: "VFR", rawOb: "METAR EBAW 311550Z",
      obsTime: 1000, temp: 21, dewp: 11, wdir: 270, wspd: 14, wgst: 25, visib: "6+",
      altim: 1014, wxString: "RA", clouds: [{ cover: "SCT", base: 3800 }],
      maliciousExtraField: "should be dropped"
    })
    assert.deepEqual(Object.keys(out).sort(), [
      "altim", "clouds", "dewp", "fltCat", "icaoId", "name", "obsTime",
      "rawOb", "temp", "visib", "wdir", "wgst", "wspd", "wxString"
    ].sort())
    assert.equal(out.icaoId, "ebaw")
    assert.equal(out.temp, 21)
    assert.equal(out.wdir, 270)
    assert.equal(out.visib, "6+")
    assert.deepEqual(out.clouds, [{ cover: "SCT", base: 3800 }])
  })

  it("caps rawOb/name/wxString at their max length", () => {
    var out = M.sanitizeMetarItem({ rawOb: "R".repeat(3000), name: "N".repeat(300), wxString: "W".repeat(300) })
    assert.equal(out.rawOb.length, 2000)
    assert.equal(out.name.length, 200)
    assert.equal(out.wxString.length, 200)
  })

  it("drops a non-string value in a string field to an empty string", () => {
    var out = M.sanitizeMetarItem({ icaoId: 12345, name: { nested: true } })
    assert.equal(out.icaoId, "")
    assert.equal(out.name, "")
  })

  it("nulls out non-finite/wrongly-typed numeric fields", () => {
    var out = M.sanitizeMetarItem({ temp: NaN, dewp: Infinity, altim: "1014", obsTime: {} })
    assert.equal(out.temp, null)
    assert.equal(out.dewp, null)
    assert.equal(out.altim, null)
    assert.equal(out.obsTime, null)
  })

  it("accepts wdir/visib as a number or a short string, and nulls out anything else", () => {
    assert.equal(M.sanitizeMetarItem({ wdir: 90 }).wdir, 90)
    assert.equal(M.sanitizeMetarItem({ wdir: "VRB" }).wdir, "VRB")
    assert.equal(M.sanitizeMetarItem({ wdir: true }).wdir, null)
    assert.equal(M.sanitizeMetarItem({ wdir: {} }).wdir, null)
  })

  it("caps the clouds array at 12 entries and drops non-object entries", () => {
    var clouds = [null, "garbage", { cover: "BKN", base: 900 }]
    for (var i = 0; i < 20; i++) clouds.push({ cover: "SCT", base: 1000 + i })
    var out = M.sanitizeMetarItem({ clouds: clouds })
    assert.equal(out.clouds.length, 12)
    assert.equal(out.clouds[0].cover, "BKN")
  })

  it("defaults clouds to [] when missing or not an array", () => {
    assert.deepEqual(M.sanitizeMetarItem({}).clouds, [])
    assert.deepEqual(M.sanitizeMetarItem({ clouds: "not an array" }).clouds, [])
  })
})

describe("sanitizeTafItem", () => {
  it("returns null for a non-object item", () => {
    assert.equal(M.sanitizeTafItem(null), null)
    assert.equal(M.sanitizeTafItem("nope"), null)
  })

  it("whitelists icaoId/rawTAF and sanitizes each fcst", () => {
    var out = M.sanitizeTafItem({
      icaoId: "ebbr", rawTAF: "TAF EBBR 311700Z", extra: "dropped",
      fcsts: [{ fcstChange: "BECMG", probability: 30, timeFrom: 100, timeTo: 200, wdir: "VRB", wspd: 5, wgst: null, wxString: "RA", clouds: [{ cover: "OVC", base: 500 }] }]
    })
    assert.deepEqual(Object.keys(out).sort(), ["fcsts", "icaoId", "rawTAF"])
    assert.equal(out.fcsts.length, 1)
    assert.equal(out.fcsts[0].fcstChange, "BECMG")
    assert.equal(out.fcsts[0].probability, 30)
    assert.deepEqual(out.fcsts[0].clouds, [{ cover: "OVC", base: 500 }])
  })

  it("defaults fcsts to [] when missing or not an array", () => {
    assert.deepEqual(M.sanitizeTafItem({}).fcsts, [])
    assert.deepEqual(M.sanitizeTafItem({ fcsts: "not an array" }).fcsts, [])
  })

  it("drops non-object fcst entries and caps the array at 24 periods", () => {
    var fcsts = [null, "garbage"]
    for (var i = 0; i < 30; i++) fcsts.push({ fcstChange: "FM", wspd: i })
    var out = M.sanitizeTafItem({ fcsts: fcsts })
    assert.equal(out.fcsts.length, 24)
    assert.equal(out.fcsts[0].wspd, 0)
  })

  it("caps rawTAF at its max length", () => {
    assert.equal(M.sanitizeTafItem({ rawTAF: "T".repeat(3000) }).rawTAF.length, 2000)
  })
})

describe("bounded fetch script (Panel.qml's curl | head pipeline)", () => {
  it("bakes in --max-filesize, a head -c cap one byte over the limit, and PIPESTATUS-forwarded exit status", () => {
    var script = M.buildBoundedFetchScript(1000)
    assert.match(script, /--max-filesize 1000\b/)
    assert.match(script, /head -c 1001\b/)
    assert.match(script, /PIPESTATUS\[0\]/)
    assert.match(script, /"\$1"/) // URL passed as a separate argv element, never interpolated
  })

  // These run the real curl | head -c pipeline (same command Panel.qml
  // builds) against a local HTTP server — not a simulation of what curl is
  // assumed to do. This is the direct regression test for the marketplace
  // security review's "no response-size bound" finding: it proves bytes
  // received are capped even when the response is chunked with no
  // Content-Length (where curl's own --max-filesize has no effect at all).
  function withServer(handler) {
    return new Promise((resolve, reject) => {
      var server = http.createServer(handler)
      server.on("error", reject)
      server.listen(0, "127.0.0.1", () => resolve(server))
    })
  }

  // spawnSync blocks the whole Node event loop for its duration — including
  // the in-process HTTP server's own request handler, which would then
  // never run while it's waiting on exactly that server. Async spawn keeps
  // the event loop free so the server can actually respond concurrently.
  function runScript(url, maxBytes) {
    return new Promise((resolve, reject) => {
      var script = M.buildBoundedFetchScript(maxBytes)
      var child = spawn("bash", ["-c", script, "test-fetch", url])
      var stdoutChunks = []
      var timedOut = false
      var timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL") }, 8000)
      child.on("error", reject)
      child.stdout.on("data", (chunk) => stdoutChunks.push(chunk))
      child.on("close", (code) => {
        clearTimeout(timer)
        if (timedOut) { reject(new Error("bash/curl/head pipeline timed out")); return }
        resolve({ status: code, stdout: Buffer.concat(stdoutChunks) })
      })
    })
  }

  it("passes a small, ordinary response through unchanged", async () => {
    var body = JSON.stringify([{ icaoId: "EBAW", rawOb: "METAR EBAW 311550Z" }])
    var server = await withServer((req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" })
      res.end(body)
    })
    try {
      var port = server.address().port
      var result = await runScript("http://127.0.0.1:" + port + "/", 1024 * 1024)
      assert.equal(result.status, 0)
      assert.equal(result.stdout.toString(), body)
    } finally {
      server.close()
    }
  })

  it("caps bytes received from a chunked, no-Content-Length response and fails rather than returning it in full", async () => {
    var cap = 1024
    var chunkSize = 64 * 1024
    var totalBytes = 5 * 1024 * 1024
    var server = await withServer((req, res) => {
      res.on("error", function() {}) // client (curl) disconnects once the cap is hit — expected, not a test failure
      res.writeHead(200, { "Content-Type": "application/json" }) // no Content-Length -> chunked transfer
      var written = 0
      var chunk = "a".repeat(chunkSize)
      ;(function writeMore() {
        while (written < totalBytes) {
          written += chunkSize
          if (!res.write(chunk)) { res.once("drain", writeMore); return }
        }
        res.end()
      })()
    })
    try {
      var port = server.address().port
      var result = await runScript("http://127.0.0.1:" + port + "/", cap)
      assert.ok(result.stdout.length <= cap + 1,
        "pipeline must never hand back more than cap+1 bytes, got " + result.stdout.length)
      assert.notEqual(result.status, 0, "an oversized chunked response must not report success")
    } finally {
      server.close()
    }
  })

  it("aborts via --max-filesize before downloading when Content-Length itself declares an oversized body", async () => {
    var cap = 1024
    var declaredSize = 5 * 1024 * 1024
    var body = "a".repeat(declaredSize)
    var server = await withServer((req, res) => {
      res.on("error", function() {})
      res.writeHead(200, { "Content-Type": "application/json", "Content-Length": String(declaredSize) })
      res.end(body)
    })
    try {
      var port = server.address().port
      var result = await runScript("http://127.0.0.1:" + port + "/", cap)
      assert.ok(result.stdout.length <= cap + 1)
      assert.notEqual(result.status, 0)
    } finally {
      server.close()
    }
  })
})
