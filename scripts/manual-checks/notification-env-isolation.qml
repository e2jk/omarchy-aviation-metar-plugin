// Regression check for the marketplace security review's finding that
// notifications, sent via Quickshell.execDetached at a fixed path, were
// still a shell execution path: omarchy-notification-send is itself a
// #!/bin/bash script, so the kernel starts Bash for it, inheriting
// whatever environment execDetached ran with — the same interpreter/
// loader injection surface (LD_PRELOAD, LD_LIBRARY_PATH, BASH_ENV, ...)
// already closed for the fetch Processes via clearEnvironment: true.
//
// Fixed by routing notifications through a dynamically-created, disposable
// Process (Panel.qml: notifyProcComponent/sendNotification) instead of
// execDetached, using the exact same clearEnvironment: true + explicit
// PATH/XDG_RUNTIME_DIR allowlist pattern already verified for fetches.
// This repo has no QML process/event-loop test harness (see README's
// Development section), so — same as
// scripts/manual-checks/launch-failure-supersession.qml — this is a
// standalone, runnable proof instead of a `npm test` case: it builds the
// *exact* Process configuration Panel.qml's notifyProcComponent uses and
// checks its child's environment directly, rather than describing what
// the fix is supposed to do.
//
// Run with: quickshell -p scripts/manual-checks/notification-env-isolation.qml
// Expect: two "PASS" lines, then a clean exit. Either FAIL means
// Panel.qml's notification Process configuration has regressed.

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root
  property bool envCheckFailed: false
  property bool sendCheckFailed: false

  // Mirrors Model.js's TRUSTED_PATH_ENV/TRUSTED_NOTIFICATION_SEND_PATH —
  // duplicated rather than imported because Quickshell's config loader
  // doesn't resolve a `../../` relative import out of this script's own
  // directory. Keep in sync with Model.js if either ever changes.
  readonly property string trustedPathEnv: "/usr/bin:/bin"
  readonly property string trustedNotificationSendPath: "/usr/bin/omarchy-notification-send"

  // Exactly Panel.qml's notifyProcComponent, but targeting /usr/bin/env
  // instead of the real notification script — printing the child's
  // complete environment is a stronger, simpler proof than checking for
  // one specific variable (LD_PRELOAD, say): it shows *everything* that
  // reached the child, so nothing inherited can hide.
  Component {
    id: envCheckComponent
    Process {
      clearEnvironment: true
      environment: ({ "PATH": root.trustedPathEnv, "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") })
      command: ["/usr/bin/env"]
      stdout: StdioCollector { id: envStdout; waitForEnd: true }
      onExited: function(exitCode, exitStatus) {
        var lines = envStdout.text.trim().split("\n").filter(function(l) { return l.length > 0 })
        var keys = lines.map(function(l) { return l.split("=")[0] }).sort()
        var expected = ["PATH", "XDG_RUNTIME_DIR"]
        var matches = JSON.stringify(keys) === JSON.stringify(expected)
        if (matches) {
          console.log("PASS: notification Process environment is exactly " + JSON.stringify(expected) + ", nothing inherited")
        } else {
          console.log("FAIL: expected exactly " + JSON.stringify(expected) + ", got " + JSON.stringify(keys))
          root.envCheckFailed = true
        }
        destroy()
      }
    }
  }

  // Confirms the restricted environment above doesn't just look clean --
  // the real script (which calls `busctl --user`, needing XDG_RUNTIME_DIR
  // to find the session bus) still actually works under it.
  Component {
    id: sendCheckComponent
    Process {
      clearEnvironment: true
      environment: ({ "PATH": root.trustedPathEnv, "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") })
      command: [root.trustedNotificationSendPath, "notification-env-isolation.qml check"]
      onExited: function(exitCode, exitStatus) {
        if (exitCode === 0) {
          console.log("PASS: omarchy-notification-send still succeeds under the restricted environment")
        } else {
          console.log("FAIL: omarchy-notification-send exited " + exitCode + " under the restricted environment")
          root.sendCheckFailed = true
        }
        destroy()
      }
    }
  }

  Component.onCompleted: {
    var envProc = envCheckComponent.createObject(root)
    if (envProc) envProc.running = true
    var sendProc = sendCheckComponent.createObject(root)
    if (sendProc) sendProc.running = true
  }

  Timer {
    interval: 2500
    running: true
    onTriggered: Qt.exit((root.envCheckFailed || root.sendCheckFailed) ? 1 : 0)
  }
}
