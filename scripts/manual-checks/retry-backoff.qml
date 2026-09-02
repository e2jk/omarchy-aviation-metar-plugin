// Verifies the retry-backoff schedule (Model.js: retryDelayMs) actually
// drives a Timer's interval the way Panel.qml's scheduleMetarRetry uses
// it, against a persistently-failing command — not just that the pure
// function returns the right numbers (already unit tested in
// test/process-hardening.test.js), but that a real retry loop built on it
// behaves as intended: tight at first, backs off, and keeps trying
// (never gives up). This is the fix for "the bar icon gets stuck showing
// no data after waking from suspend, until I hover over it" — a fetch can
// fire before Wi-Fi has reconnected, and without backing off and
// retrying indefinitely in the background, the bar would sit on stale/no
// data until the next full refreshMinutes cycle or a manual/hover
// refresh.
//
// This repo has no QML process/event-loop test harness (see README's
// Development section), so — same as the other scripts in this
// directory — this is a standalone, runnable proof instead of an
// `npm test` case. It only checks the first four scheduled delays
// (3s/3s/3s/10s — long enough to see the fast-to-backoff transition)
// rather than running the full multi-minute schedule out to its 5-minute
// resting cadence, which is already exhaustively covered by
// retryDelayMs's own unit tests.
//
// Run with: quickshell -p scripts/manual-checks/retry-backoff.qml
// Expect: a PASS line for each observed delay, "went offline after the
// fast attempts: PASS", then a clean exit.

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root

  // Mirrors Model.js's RETRY_BACKOFF_MS/RETRY_FAST_ATTEMPTS — duplicated
  // rather than imported for the same reason as the other scripts here
  // (Quickshell's config loader doesn't resolve a `../../` relative
  // import out of this script's own directory). Keep in sync with
  // Model.js if either ever changes.
  readonly property var retryBackoffMs: [3000, 3000, 3000, 10000, 30000, 60000, 300000]
  readonly property int retryFastAttempts: 3
  function retryDelayMs(attempt) {
    var idx = attempt - 1
    if (idx < 0) idx = 0
    if (idx >= root.retryBackoffMs.length) idx = root.retryBackoffMs.length - 1
    return root.retryBackoffMs[idx]
  }

  property int retries: 0
  property bool offline: false
  property var attemptTimestamps: []
  property bool failed: false
  readonly property int checksToObserve: 4 // 3s, 3s, 3s, 10s

  function scheduleRetry() {
    root.retries++
    if (root.retries === root.retryFastAttempts + 1) root.offline = true
    retryTimer.interval = root.retryDelayMs(root.retries)
    retryTimer.restart()
  }

  Process {
    id: proc
    // Fails immediately and reliably: nothing listens on port 1.
    command: ["/usr/bin/curl", "-fsS", "--max-time", "2", "http://127.0.0.1:1/"]
    onExited: function(exitCode, exitStatus) {
      root.attemptTimestamps.push(Date.now())
      if (root.attemptTimestamps.length > root.checksToObserve) {
        root.finish()
        return
      }
      root.scheduleRetry()
    }
  }

  Timer {
    id: retryTimer
    interval: 3000
    onTriggered: proc.running = true
  }

  function finish() {
    retryTimer.stop()
    var expected = [3000, 3000, 3000, 10000]
    for (var i = 1; i < root.attemptTimestamps.length; i++) {
      var observed = root.attemptTimestamps[i] - root.attemptTimestamps[i - 1]
      // Generous tolerance: this is timing actual OS processes (curl's
      // own connection-refused latency, Qt's event loop), not asserting
      // millisecond precision -- just that it's the right delay, not
      // (say) the next one in the schedule or a fixed interval throughout.
      var ok = Math.abs(observed - expected[i - 1]) < expected[i - 1] * 0.5 + 500
      console.log((ok ? "PASS" : "FAIL") + ": attempt " + (i + 1) + " fired " + observed + "ms after the previous one (expected ~" + expected[i - 1] + "ms)")
      if (!ok) root.failed = true
    }
    if (root.offline) {
      console.log("PASS: went offline after the fast attempts")
    } else {
      console.log("FAIL: never went offline after the fast attempts")
      root.failed = true
    }
    Qt.exit(root.failed ? 1 : 0)
  }

  Component.onCompleted: proc.running = true

  Timer {
    interval: 40000 // generous ceiling: 3+3+3+10s of scheduled delays plus curl/process overhead
    running: true
    onTriggered: {
      console.log("FAIL: did not observe " + root.checksToObserve + " attempts within the time limit")
      Qt.exit(1)
    }
  }
}
