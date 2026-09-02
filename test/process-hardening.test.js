// Regression coverage for the marketplace security review's second
// process/request-remediation round: environment inheritance beyond PATH,
// the notification path, and request supersession when the *new* desired
// state is "nothing should be fetched" (empty airports / TAF turned off).
const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const { spawn, execFileSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const M = require("../Model.js")

describe("notification path is fixed and absolute", () => {
  it("TRUSTED_NOTIFICATION_SEND_PATH is an absolute path, never a bare name", () => {
    assert.equal(M.TRUSTED_NOTIFICATION_SEND_PATH.charAt(0), "/")
  })
})

describe("fetchPlan", () => {
  it("requests both when airports are configured and TAF is on", () => {
    assert.deepEqual(M.fetchPlan(["EBAW"], true), { metar: "request", taf: "request" })
  })

  it("abandons TAF (not just 'don't fetch it') when TAF is turned off", () => {
    assert.deepEqual(M.fetchPlan(["EBAW"], false), { metar: "request", taf: "abandon" })
  })

  it("abandons both when the airport list is empty", () => {
    assert.deepEqual(M.fetchPlan([], true), { metar: "abandon", taf: "abandon" })
    assert.deepEqual(M.fetchPlan([], false), { metar: "abandon", taf: "abandon" })
  })

  it("treats a missing/null airport list the same as empty", () => {
    assert.deepEqual(M.fetchPlan(null, true), { metar: "abandon", taf: "abandon" })
    assert.deepEqual(M.fetchPlan(undefined, true), { metar: "abandon", taf: "abandon" })
  })
})

// Direct regression test for "Panel.qml overrides only PATH while
// inheriting the rest of the environment" — proves both halves for real
// against the exact command Panel.qml builds, using the exact mechanic
// difference between the old (buggy) and new (fixed) behavior: merging an
// override onto the inherited environment vs. replacing it outright.
// child_process.spawn's own `env` option models this precisely — pass an
// object *merged* from process.env and it inherits everything else in it
// (no intermediate shell/`env` process involved to muddy the result, since
// spawn hands the given object straight to the underlying exec syscall);
// pass a *standalone* object and process.env is not consulted at all, the
// same effect as Quickshell's clearEnvironment: true.
//
// LD_PRELOAD (not BASH_ENV) is the case actually exercised here. Checked
// first, not assumed: BASH_ENV is only honored by bash for a *script
// file* invocation (`bash script.sh`) — verified directly (`bash -c` with
// BASH_ENV set does not source it; `bash /path/to/script` does), so it
// doesn't apply to Panel.qml's actual `bash -c '<script>'` invocation.
// LD_PRELOAD has no such restriction: the dynamic linker honors it for
// *any* dynamically linked executable regardless of how it's invoked,
// including /usr/bin/timeout — the very first thing Panel.qml's fetch
// command execs — which is exactly why a full environment clear (not a
// per-variable allowlist of "the ones known to matter for -c mode") is
// the right fix: it closes this whole category uniformly regardless of
// which specific variable a future invocation shape might newly honor.
describe("environment clearing prevents loader-level injection (LD_PRELOAD)", () => {
  var gccAvailable = (() => {
    try { execFileSync("gcc", ["--version"], { stdio: "ignore" }); return true }
    catch (e) { return false }
  })()
  var skipReason = gccAvailable ? undefined : "gcc not available to build the LD_PRELOAD test library"

  async function withPreloadLibrary(fn) {
    var dir = fs.mkdtempSync(path.join(os.tmpdir(), "metar-taf-preload-test-"))
    var marker = path.join(dir, "marker")
    var src = path.join(dir, "inject.c")
    var lib = path.join(dir, "inject.so")
    fs.writeFileSync(src,
      "#include <stdio.h>\n"
      + "__attribute__((constructor)) static void inject(void) {\n"
      + "  FILE *f = fopen(\"" + marker + "\", \"w\");\n"
      + "  if (f) fclose(f);\n"
      + "}\n")
    execFileSync("gcc", ["-shared", "-fPIC", "-o", lib, src])
    try {
      // Must await here, not just return the promise: fn spawns a process
      // that loads `lib` and writes `marker` asynchronously, and the
      // directory holding both gets deleted in `finally` right below —
      // without awaiting, cleanup was racing the spawn itself and deleting
      // the library out from under it before it could ever be loaded,
      // which made both tests below pass for the wrong reason (the "fix"
      // test) or fail for the wrong reason (the "vulnerable" test).
      return await fn(lib, marker)
    } finally {
      try { fs.rmSync(dir, { recursive: true, force: true }) } catch (e) { /* best-effort cleanup */ }
    }
  }

  function runFetchCommand(env) {
    return new Promise((resolve, reject) => {
      // Any reachable target works here — this is testing environment
      // handling, not network behavior, so a guaranteed-fast local
      // rejection (nothing listening) is enough to let it run and exit
      // quickly either way; LD_PRELOAD, if honored, loads at exec time,
      // before the command even gets that far.
      var cmd = M.buildFetchCommand("http://127.0.0.1:1/", 1024, "test-env")
      var child = spawn(cmd[0], cmd.slice(1), { env: env })
      child.on("error", reject)
      var timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("timed out")) }, 8000)
      child.on("close", () => { clearTimeout(timer); resolve() })
    })
  }

  it("LD_PRELOAD merged onto an inherited environment (the pre-fix shape: PATH overridden, everything else kept) loads into /usr/bin/timeout itself", { skip: skipReason }, async () => {
    await withPreloadLibrary(async (lib, marker) => {
      var mergedEnv = Object.assign({}, process.env, { PATH: M.TRUSTED_PATH_ENV, LD_PRELOAD: lib })
      await runFetchCommand(mergedEnv)
      assert.ok(fs.existsSync(marker), "LD_PRELOAD should have been honored by the dynamic linker — this is the vulnerability the review flagged")
    })
  })

  it("a standalone PATH-only environment (Panel.qml's actual fix) prevents that same injection even when LD_PRELOAD is set in the surrounding process", { skip: skipReason }, async () => {
    await withPreloadLibrary(async (lib, marker) => {
      var previous = process.env.LD_PRELOAD
      process.env.LD_PRELOAD = lib // simulates a poisoned *surrounding* environment (e.g. omarchy-shell's own)
      try {
        await runFetchCommand({ PATH: M.TRUSTED_PATH_ENV }) // standalone object — process.env not consulted at all
        assert.ok(!fs.existsSync(marker), "a fully restricted environment (PATH only, not merged) must not honor LD_PRELOAD")
      } finally {
        if (previous === undefined) delete process.env.LD_PRELOAD
        else process.env.LD_PRELOAD = previous
      }
    })
  })
})
