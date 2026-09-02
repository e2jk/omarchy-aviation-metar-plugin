// Reproduces, in isolation, the exact race the marketplace security review
// flagged in Panel.qml's request-supersession handling: a stale fetch's
// own `exited` handler can synchronously start its replacement *before*
// Quickshell delivers that stale fetch's own `runningChanged(false)` — so
// if the replacement's own exec then fails, a single shared "settled"
// boolean can't tell whether a later runningChanged(false) is reporting
// the old (already-handled) launch or the brand-new (unhandled) one.
//
// This repo has no QML process/event-loop test harness (see README's
// Development section), so this can't run under `npm test`. It's a
// standalone, runnable proof instead: it drives the *exact* mechanism
// Panel.qml uses (metarLaunchSeq/metarSettledSeq, mirrored here as
// launchSeq/settledSeq) through the failure sequence and asserts the
// launch failure is actually detected — not a description of the fix, an
// executable check of it.
//
// Run with: quickshell -p scripts/manual-checks/launch-failure-supersession.qml
// Expect: "PASS" printed, then a clean exit. Any FAIL means the
// launch-identity tracking in Panel.qml (metarLaunchSeq/metarSettledSeq)
// has regressed back to the boolean-flag bug this replaced.

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root

  // ---- Mirrors Panel.qml's metarGeneration/metarProcGeneration/
  // metarLaunchSeq/metarSettledSeq/pendingMetarUrl and
  // startOrQueueMetarFetch/metarResultIsStale exactly, scaled down to a
  // single Process driving arbitrary commands instead of real fetches.
  property int generation: 0
  property int procGeneration: -1
  property int launchSeq: 0
  property int settledSeq: -1
  property var pendingCmd: null
  property int retryCount: 0
  property bool failed: false

  function start(cmd, gen) {
    if (proc.running) {
      root.pendingCmd = cmd
      proc.signal(15)
      return
    }
    root.procGeneration = gen
    root.launchSeq++
    proc.command = cmd
    proc.running = true
  }

  function resultIsStale() {
    if (root.procGeneration === root.generation) return false
    var next = root.pendingCmd
    root.pendingCmd = null
    if (next !== null) root.start(next, root.generation)
    return true
  }

  Process {
    id: proc
    onExited: function(exitCode, exitStatus) {
      root.settledSeq = root.launchSeq
      if (root.resultIsStale()) return
    }
    onRunningChanged: {
      if (proc.running) return
      if (root.settledSeq === root.launchSeq) return
      root.settledSeq = root.launchSeq
      if (root.resultIsStale()) return
      root.retryCount++
    }
  }

  Component.onCompleted: root.start(["/usr/bin/sleep", "5"], 0)

  Timer {
    // Supersede the running sleep with a request whose replacement is a
    // broken path — this is the exact scenario: the cancelled launch's
    // onExited synchronously starts a replacement that itself fails.
    interval: 300
    running: true
    onTriggered: {
      root.generation = 1
      root.pendingCmd = ["/usr/bin/this-path-does-not-exist-launch-failure-check"]
      proc.signal(15)
    }
  }

  Timer {
    interval: 2500
    running: true
    onTriggered: {
      if (root.retryCount === 1) {
        console.log("PASS: launch failure for the replacement was correctly detected (retryCount=1)")
      } else {
        console.log("FAIL: expected retryCount=1, got " + root.retryCount + " -- the launch-failure signal was not correctly attributed")
        root.failed = true
      }
      Qt.exit(root.failed ? 1 : 0)
    }
  }
}
