import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "metar-taf"
  ipcTarget: "metar-taf"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget (see omarchy.weather for the same split).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Deliberately no refresh() here: a click is preceded by a hover, and the
  // hover already refreshed if the data was actually stale (see
  // refreshIfStale/hoverRefreshMinutes) — an unconditional refresh on open
  // would just be a second, redundant fetch every single time the popup is
  // opened, whether or not anything needed refreshing.
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Configuration, read live from the widget's shell.json entry.
  readonly property string airportsRaw: setting("airports", "EBAW,EBBR,EBCI")
  readonly property var airportList: Model.parseAirportList(airportsRaw)
  // Entries in `airports` that were silently dropped for being the wrong
  // shape (not exactly 4 alphanumeric characters) — surfaced in the popup
  // so a typo doesn't just make a station quietly vanish with no explanation.
  readonly property var invalidAirportEntries: Model.invalidAirportEntries(airportsRaw)
  readonly property int invalidAirportCount: Model.invalidAirportCount(airportsRaw)
  readonly property bool imperial: setting("units", "Metric") === "Imperial"
  readonly property bool showTaf: setting("showTaf", true) === true
  readonly property int refreshMinutes: Math.max(5, Math.min(60, parseInt(setting("refreshMinutes", 10), 10) || 10))
  readonly property bool showStationNameInTooltip: setting("showStationNameInTooltip", true) === true
  // Decoded English is the default (friendlier for anyone who doesn't read
  // METAR groups); hovering the report always reveals whichever form isn't
  // the primary one.
  readonly property bool decoded: setting("decodeStyle", "Decoded") !== "Coded"
  readonly property int maxAgeMinutes: Math.max(10, Math.min(180, parseInt(setting("maxAgeMinutes", 40), 10) || 40))
  readonly property int hoverRefreshMinutes: Math.max(1, Math.min(30, parseInt(setting("hoverRefreshMinutes", 2), 10) || 2))

  onAirportListChanged: Qt.callLater(refresh)
  onShowTafChanged: Qt.callLater(refresh)

  // Forces `entries` to re-evaluate staleness periodically even when no new
  // fetch happens — otherwise a station whose last report ages past
  // maxAgeMinutes would only flip to "no data" at the next refresh cycle.
  property double nowTick: Date.now() / 1000
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.nowTick = Date.now() / 1000
  }

  // ---- Fetch state. Metar data is kept around even after a failed refresh —
  //      see metarOffline below for how that stale data is presented rather
  //      than silently passed off as current.
  property var metarByIcao: ({})
  property var tafByIcao: ({})
  property double lastUpdated: 0
  property int metarRetries: 0
  property int tafRetries: 0
  // Every ICAO code that has appeared in any successful fetch this session.
  // Unlike metarByIcao (replaced fresh each fetch), this only ever grows —
  // it's what tells "never once a real station" apart from "just missing
  // from the latest response" in buildEntries.
  property var everSeenIcaos: ({})

  // Set once the very first fetch ever completes successfully; used to tell
  // "still loading for the first time" apart from "reachable but no data for
  // this station".
  property bool metarEverSucceeded: false
  // True once the most recent fetch attempt — including its retries — ends
  // without success. This is aviation weather: a stale METAR silently shown
  // as current is worse than an honest "no data", so this is surfaced on the
  // bar itself, not just in a tooltip.
  property bool metarOffline: false
  // True only while a refresh the user explicitly asked for (middle click)
  // is in flight, so triggering it visibly does something. Deliberately not
  // set for the silent background refreshMinutes timer — the bar shouldn't
  // flicker to a placeholder every refresh cycle on its own.
  property bool manualRefreshInFlight: false

  // ---- Hover-triggered background refresh. Hovering the bar when the data
  // is older than hoverRefreshMinutes quietly refreshes in the background —
  // deliberately NOT fed into buildEntries' `loading` (no dash, no visible
  // disruption while it's in flight). Once it settles, the fetched data is
  // fingerprinted (raw METAR+TAF text, not the full API payload — see
  // Model.dataFingerprint) and compared against what was showing before the
  // hover-refresh started; only a genuine change triggers `justUpdated`,
  // which the bar uses to briefly flash — a hover refresh that came back
  // identical stays completely silent, as specified in issue #5.
  property bool hoverRefreshInFlight: false
  property string preHoverFingerprint: ""
  property bool justUpdated: false

  function refreshIfStale() {
    if (root.manualRefreshInFlight || root.hoverRefreshInFlight) return
    if (!root.metarEverSucceeded) return // let the initial-load path own this
    if (root.airportList.length === 0) return
    var now = Date.now() / 1000
    if (root.lastUpdated > 0 && (now - root.lastUpdated) < root.hoverRefreshMinutes * 60) return
    root.hoverRefreshInFlight = true
    root.preHoverFingerprint = Model.dataFingerprint(root.airportList, root.metarByIcao, root.tafByIcao)
    root.refresh()
  }

  // Called after each fetch attempt settles (success or a scheduled-retry
  // gap); only actually resolves once neither fetch is running nor has a
  // retry pending, so a hover refresh's comparison waits for the full
  // picture rather than firing mid-retry.
  function maybeFinishHoverRefresh() {
    if (!root.hoverRefreshInFlight) return
    if (metarProc.running || metarRetryTimer.running) return
    if (root.showTaf && (tafProc.running || tafRetryTimer.running)) return
    root.hoverRefreshInFlight = false
    var newFingerprint = Model.dataFingerprint(root.airportList, root.metarByIcao, root.tafByIcao)
    if (newFingerprint !== root.preHoverFingerprint) {
      root.justUpdated = true
      justUpdatedResetTimer.restart()
    }
  }

  Timer {
    id: justUpdatedResetTimer
    interval: 2000
    onTriggered: root.justUpdated = false
  }

  readonly property var entries: Model.buildEntries(airportList, metarByIcao, {
    loading: root.manualRefreshInFlight,
    everSucceeded: root.metarEverSucceeded,
    offline: root.metarOffline,
    nowSeconds: root.nowTick,
    maxAgeMinutes: root.maxAgeMinutes,
    everSeenIcaos: root.everSeenIcaos
  })
  readonly property string summary: Model.summaryLine(entries)
  readonly property bool loading: metarProc.running || (root.showTaf && tafProc.running)

  // ---- Fetch generation tracking. Each of these Process objects is a
  // single reused instance — it can only ever run one command at a time —
  // but settings can change (or a manual/hover refresh can be requested)
  // while one is still in flight. Without this, overwriting .command and
  // re-setting running=true on an already-running Process is a no-op (the
  // new request is silently dropped) while the *old* one's result still
  // lands in onExited and gets committed as if it reflected the new
  // request — stale data presented as current, or the "actually requested"
  // fetch never happening at all.
  //
  // Fix: every genuinely new request (requestMetarFetch/requestTafFetch)
  // bumps a generation counter. A process's own generation is frozen the
  // moment it actually starts (metarProcGeneration/tafProcGeneration); if
  // that no longer matches the live counter by the time it exits, the
  // result is stale — discarded outright, never committed, never allowed
  // to drive retry/offline state — and whatever was actually requested
  // last (pendingMetarUrl/pendingTafUrl, which a queued request keeps
  // overwriting with the latest desired state) starts as soon as the
  // Process is free. Retries (scheduleMetarRetry/the retry Timers) reuse
  // the current generation rather than minting a new one — a retry
  // continues the same logical request, and is itself skipped if that
  // generation has since been superseded while it was waiting to fire.
  property int metarGeneration: 0
  property int metarProcGeneration: -1
  property int metarRetryGeneration: -1
  property string pendingMetarUrl: ""
  property int tafGeneration: 0
  property int tafProcGeneration: -1
  property int tafRetryGeneration: -1
  property string pendingTafUrl: ""

  // Per-attempt launch identity — distinct from generation (which tracks
  // *logical requests*, i.e. "what settings does this reflect"). This
  // tracks *physical exec attempts*, i.e. "which specific `running = true`
  // was this". Needed because a stale result's own onExited can
  // synchronously start its replacement (see metarResultIsStale) *before*
  // Quickshell delivers the old process's own runningChanged(false) — so a
  // single shared "settled" boolean can't tell, when that (possibly
  // deferred/coalesced) signal finally arrives, whether it's reporting the
  // old launch settling or the brand-new replacement's own exec having
  // just failed. Verified live (quickshell -c against an ad-hoc test
  // shell): with a boolean flag, exactly that sequence — cancel a running
  // launch, restart synchronously with a broken path — leaves the flag
  // already true from the old launch, so the replacement's real exec
  // failure gets silently swallowed as if it were just the old one
  // settling, and no retry ever fires. Comparing the *sequence number* the
  // signal arrives with against the sequence number of whatever is
  // actually running now closes that regardless of delivery order/timing.
  property int metarLaunchSeq: 0
  property int metarSettledSeq: -1
  property int tafLaunchSeq: 0
  property int tafSettledSeq: -1

  function buildMetarUrl() {
    return "https://aviationweather.gov/api/data/metar?ids="
      + encodeURIComponent(airportList.join(",")) + "&format=json"
  }

  function buildTafUrl() {
    return "https://aviationweather.gov/api/data/taf?ids="
      + encodeURIComponent(airportList.join(",")) + "&format=json"
  }

  // The only entry point for "fetch current settings, as a genuinely new
  // request" — used by manual refresh, the periodic timer, hover-refresh,
  // and settings changes. Deliberately not used by retries, which continue
  // the existing generation instead (see scheduleMetarRetry).
  function requestMetarFetch() {
    root.metarGeneration++
    root.metarRetries = 0
    root.startOrQueueMetarFetch(root.buildMetarUrl(), root.metarGeneration)
  }

  function requestTafFetch() {
    root.tafGeneration++
    root.tafRetries = 0
    root.startOrQueueTafFetch(root.buildTafUrl(), root.tafGeneration)
  }

  // If the Process is already busy (an older generation still in flight),
  // remember the latest desired request and cancel the old one rather than
  // silently dropping the new request or letting two overlap on one
  // Process; onExited notices the generation mismatch when the cancelled
  // one actually exits, discards its result, and starts the pending
  // request then — never blocking on it here.
  function startOrQueueMetarFetch(url, generation) {
    if (metarProc.running) {
      root.pendingMetarUrl = url
      root.cancelMetarProc()
      return
    }
    root.metarProcGeneration = generation
    root.metarLaunchSeq++
    metarProc.command = Model.buildFetchCommand(url, root.maxResponseBytes, "fetch-metar")
    metarProc.running = true
  }

  function startOrQueueTafFetch(url, generation) {
    if (tafProc.running) {
      root.pendingTafUrl = url
      root.cancelTafProc()
      return
    }
    root.tafProcGeneration = generation
    root.tafLaunchSeq++
    tafProc.command = Model.buildFetchCommand(url, root.maxResponseBytes, "fetch-taf")
    tafProc.running = true
  }

  // For when the current *desired* state is "nothing should be fetched"
  // (no airports configured, or TAF just turned off) while a fetch for the
  // old state may still be in flight or queued. Bumping the generation and
  // clearing/cancelling here — without starting a replacement — is what
  // refresh() uses for exactly that case; without it, an in-flight fetch's
  // generation would still match (nothing ever advanced it) and its result
  // would be accepted as current, committing data for settings that no
  // longer apply.
  function abandonMetarFetch() {
    root.metarGeneration++
    root.metarRetries = 0
    root.pendingMetarUrl = ""
    root.cancelMetarProc()
  }

  function abandonTafFetch() {
    root.tafGeneration++
    root.tafRetries = 0
    root.pendingTafUrl = ""
    root.cancelTafProc()
  }

  // Signals the *outer timeout process itself* — verified live (see
  // Model.buildFetchCommand) to forward SIGTERM to the whole process group
  // it started, tearing down curl and head along with the wrapper, not
  // just the immediate child. Used both for supersession (a newer request
  // arrived) and for component teardown (see Component.onDestruction
  // below), so an in-flight fetch never outlives what still wants it.
  function cancelMetarProc() {
    if (metarProc.running) metarProc.signal(15) // SIGTERM
  }

  function cancelTafProc() {
    if (tafProc.running) tafProc.signal(15)
  }

  // Shared by onExited and the launch-failure fallback in onRunningChanged
  // below — either way a settled/failed metarProc needs the exact same
  // "does anyone still want this result" check. Returns true (and already
  // started whatever's actually wanted) if this launch was superseded.
  function metarResultIsStale() {
    if (root.metarProcGeneration === root.metarGeneration) return false
    var nextUrl = root.pendingMetarUrl
    root.pendingMetarUrl = ""
    if (nextUrl !== "") root.startOrQueueMetarFetch(nextUrl, root.metarGeneration)
    return true
  }

  function tafResultIsStale() {
    if (root.tafProcGeneration === root.tafGeneration) return false
    var nextUrl = root.pendingTafUrl
    root.pendingTafUrl = ""
    if (nextUrl !== "") root.startOrQueueTafFetch(nextUrl, root.tafGeneration)
    return true
  }

  Component.onDestruction: {
    root.cancelMetarProc()
    root.cancelTafProc()
  }

  // The metar/taf "request" vs "abandon" decision (see Model.fetchPlan) is
  // pure and unit-tested there; what each actually does to the live
  // Process objects (cancel/start/signal) can't be — this just carries out
  // whichever plan was decided. "abandon" supersedes/cancels anything
  // still in flight for the old settings rather than merely clearing
  // already-fetched data, so a fetch started under the old settings can
  // never land and commit after they've changed.
  function refresh() {
    var plan = Model.fetchPlan(root.airportList, root.showTaf)
    if (plan.metar === "abandon") {
      root.abandonMetarFetch()
      root.metarByIcao = {}
    } else {
      root.requestMetarFetch()
    }
    if (plan.taf === "abandon") {
      root.abandonTafFetch()
      root.tafByIcao = {}
    } else {
      root.requestTafFetch()
    }
  }

  // Entry point for the bar's middle-click / explicit "refresh" action —
  // the only path that shows the transient loading dash.
  function refreshManual() {
    manualRefreshInFlight = true
    refresh()
  }

  // Well above any real response (a dozen airports' METAR/TAF is a few KB)
  // but a hard cap on what a faulty/compromised responder can make this
  // shell retain — see Model.buildBoundedFetchScript.
  readonly property int maxResponseBytes: Model.MAX_RESPONSE_BYTES

  function scheduleMetarRetry() {
    if (metarRetries >= 3) {
      root.metarOffline = true
      root.manualRefreshInFlight = false
      Qt.callLater(root.maybeFinishHoverRefresh)
      return
    }
    metarRetries++
    root.metarRetryGeneration = root.metarGeneration
    metarRetryTimer.restart()
  }

  function scheduleTafRetry() {
    if (tafRetries >= 3) {
      Qt.callLater(root.maybeFinishHoverRefresh)
      return
    }
    tafRetries++
    root.tafRetryGeneration = root.tafGeneration
    tafRetryTimer.restart()
  }

  function formatTemp(c) { return Model.formatTemp(c, root.imperial) }
  function formatVisibility(metar) { return Model.formatVisibilityFromMetar(metar, root.imperial) }
  function formatAltimeter(a) { return Model.formatAltimeter(a, root.imperial) }
  function formatWind(dir, spd, gst) { return Model.formatWind(dir, spd, gst) }
  function formatClouds(clouds) { return Model.formatClouds(clouds) }

  function tafForIcao(icao) { return tafByIcao[icao] || null }

  function formatEpoch(seconds) {
    if (!seconds) return ""
    return Qt.formatDateTime(new Date(seconds * 1000), "ddd HH:mm")
  }

  // Header text for "when was this last refreshed" — closer readings get
  // more specific phrasing (see Model.lastUpdatedTier for the tier
  // decision; this only turns that into words, since Qt.formatDateTime for
  // a correct clock time / weekday name isn't available to Model.js).
  function formatLastUpdated() {
    var info = Model.lastUpdatedTier(root.lastUpdated, root.nowTick)
    if (info.tier === "none") return ""
    var clock = Qt.formatDateTime(new Date(root.lastUpdated * 1000), "HH:mm")
    if (info.tier === "justNow") return "Updated just now (" + clock + ")"
    if (info.tier === "minutesAgo") return "Updated " + info.minutes + " min ago (" + clock + ")"
    if (info.tier === "today") return "Updated Today " + clock
    return "Updated " + Qt.formatDateTime(new Date(root.lastUpdated * 1000), "dddd") + " " + clock
  }

  // Native clipboard write via Qt/Quickshell's own clipboard integration —
  // no subprocess, no shell, nothing to resolve via $PATH at all. Confirms
  // via a desktop notification (see sendNotification below).
  function copyToClipboard(value, label) {
    if (!value) return
    Quickshell.clipboardText = value
    root.sendNotification(label + " copied")
  }

  // omarchy-notification-send is itself a #!/bin/bash script — a fixed,
  // trusted *path* alone doesn't stop the kernel from starting Bash for it
  // and that Bash (and the busctl it calls internally) inheriting whatever
  // environment launched it, the same interpreter/loader injection surface
  // (LD_PRELOAD, LD_LIBRARY_PATH, BASH_ENV, ...) already closed for the
  // fetch Processes. Quickshell.execDetached has no environment control
  // (its ProcessContext overload exists in principle, but isn't
  // constructible as a plain JS object at the QML/JS boundary — verified
  // live, and the base Omarchy shell itself never uses it either), so this
  // uses the same supervised, environment-cleared Process pattern as the
  // fetches instead. A fresh Process per call (not a single reused one,
  // unlike metarProc/tafProc) — a dropped/overwritten notification from two
  // firing in close succession would be a silent, low-stakes UX
  // regression, but there's no reason to accept even that when nothing
  // here needs the result, so each call gets an independent, disposable
  // instance that destroys itself once it exits.
  //
  // busctl --user (what the script calls internally to reach the
  // notification daemon over D-Bus) needs XDG_RUNTIME_DIR to find the
  // user's session bus — verified live: PATH alone fails ("$DBUS_SESSION_
  // BUS_ADDRESS and $XDG_RUNTIME_DIR not defined"), PATH + XDG_RUNTIME_DIR
  // succeeds. Read once via Quickshell.env, not inherited wholesale.
  readonly property string notificationXdgRuntimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

  Component {
    id: notifyProcComponent
    Process {
      clearEnvironment: true
      environment: ({ "PATH": Model.TRUSTED_PATH_ENV, "XDG_RUNTIME_DIR": root.notificationXdgRuntimeDir })
      onExited: destroy()
    }
  }

  function sendNotification(text) {
    if (!text) return
    var proc = notifyProcComponent.createObject(root, { command: [Model.TRUSTED_NOTIFICATION_SEND_PATH, text] })
    if (proc) proc.running = true
  }

  Process {
    id: metarProc
    // Fully cleared, not merged: fixed executable paths alone don't stop
    // loader/interpreter-level injection through inherited variables like
    // LD_PRELOAD, LD_LIBRARY_PATH, or bash's own BASH_ENV/ENV (honored by
    // non-interactive `bash -c`, exactly how this is invoked) — those still
    // apply to /usr/bin/timeout and /usr/bin/bash themselves regardless of
    // how trusted their own path is. PATH is added back as the one
    // documented exception (see Model.TRUSTED_PATH_ENV for why nothing
    // else, proxy variables included, is re-added).
    clearEnvironment: true
    environment: ({ "PATH": Model.TRUSTED_PATH_ENV })
    stdout: StdioCollector { id: metarStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      root.metarSettledSeq = root.metarLaunchSeq

      // This specific launch's generation is frozen in metarProcGeneration
      // when it started; if a newer request has since been made, this
      // result belongs to nobody anymore — never commit it, never let it
      // drive retry/offline state for the generation that's actually
      // current. Whatever was actually requested last runs now instead.
      if (root.metarResultIsStale()) return

      // curl -f fails (nonzero) on a transport error or an HTTP error
      // status — that's the only case worth retrying/going offline over.
      // A *successful* request (exit 0) with an empty body happens for a
      // real reason: aviationweather.gov returns HTTP 204 with no content
      // when every requested id is unrecognized (verified live against
      // https://aviationweather.gov/api/data/metar?ids=ZZZZ). Treating
      // that as a transient failure would misreport "your airport list is
      // invalid" as "we're offline" after retries exhaust. A cancelled
      // fetch (superseded/torn down) also exits non-zero, but is already
      // handled by the generation check above before reaching here.
      if (exitCode !== 0) { root.scheduleMetarRetry(); return }

      // Belt-and-braces alongside the fetch-side head -c cap (see
      // buildBoundedFetchScript): explicitly reject rather than parse
      // anything that reached the byte ceiling, instead of relying on
      // JSON.parse to happen to throw on a truncated body.
      var rawFull = String(metarStdout.text || "")
      if (rawFull.length > root.maxResponseBytes) { root.scheduleMetarRetry(); return }
      var raw = rawFull.trim()
      var parsed = []
      if (raw) {
        try {
          parsed = JSON.parse(raw)
        } catch (e) {
          root.scheduleMetarRetry()
          return
        }
      }

      root.metarByIcao = Model.buildByIcao(Model.sanitizeApiList(parsed).map(Model.sanitizeMetarItem))
      // Reassign (not mutate-in-place) so the `entries` binding, which
      // reads this property, actually re-evaluates. Only ever tracks
      // configured airports — the only ones buildEntries ever looks up —
      // so this can't grow past airportList's own 12-entry cap even if a
      // compromised responder returns other stations' ids.
      var seen = {}
      for (var prevIcao in root.everSeenIcaos) {
        if (root.airportList.indexOf(prevIcao) !== -1) seen[prevIcao] = true
      }
      for (var icao in root.metarByIcao) {
        if (root.airportList.indexOf(icao) !== -1) seen[icao] = true
      }
      root.everSeenIcaos = seen
      root.metarRetries = 0
      root.metarEverSucceeded = true
      root.metarOffline = false
      root.manualRefreshInFlight = false
      root.lastUpdated = Date.now() / 1000
      Qt.callLater(root.maybeFinishHoverRefresh)
    }
    onRunningChanged: {
      if (metarProc.running) return
      // metarSettledSeq already matching the *current* launch means
      // `exited` already handled this exact attempt — nothing left to do.
      // A mismatch means either `exited` never fired for this attempt at
      // all (exec itself failed — verified live, see the property comment
      // above), or it fired for an *older* attempt whose synchronous
      // restart (see metarResultIsStale) already moved launchSeq forward
      // before this signal was delivered; either way, this attempt itself
      // has not been resolved yet, so resolve it now rather than mistaking
      // a stale settlement for this one.
      if (root.metarSettledSeq === root.metarLaunchSeq) return
      root.metarSettledSeq = root.metarLaunchSeq
      if (root.metarResultIsStale()) return
      root.scheduleMetarRetry()
    }
  }

  Timer {
    id: metarRetryTimer
    interval: 3000
    // Bound to the generation the retry was scheduled for — if that's
    // since been superseded (settings changed, another refresh requested)
    // while this timer was waiting, it's a no-op: the newer request either
    // already started or will via its own path, and this stale retry must
    // not double-fetch or fight over the shared Process.
    onTriggered: {
      if (metarProc.running) return
      if (root.metarRetryGeneration !== root.metarGeneration) return
      root.startOrQueueMetarFetch(root.buildMetarUrl(), root.metarGeneration)
    }
  }

  Process {
    id: tafProc
    clearEnvironment: true
    environment: ({ "PATH": Model.TRUSTED_PATH_ENV })
    stdout: StdioCollector { id: tafStdout; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      root.tafSettledSeq = root.tafLaunchSeq
      if (root.tafResultIsStale()) return

      if (exitCode !== 0) { root.scheduleTafRetry(); return }

      var rawFull = String(tafStdout.text || "")
      if (rawFull.length > root.maxResponseBytes) { root.scheduleTafRetry(); return }
      var raw = rawFull.trim()
      var parsed = []
      if (raw) {
        try {
          parsed = JSON.parse(raw)
        } catch (e) {
          root.scheduleTafRetry()
          return
        }
      }

      root.tafByIcao = Model.buildByIcao(Model.sanitizeApiList(parsed).map(Model.sanitizeTafItem))
      root.tafRetries = 0
      Qt.callLater(root.maybeFinishHoverRefresh)
    }
    onRunningChanged: {
      if (tafProc.running) return
      if (root.tafSettledSeq === root.tafLaunchSeq) return
      root.tafSettledSeq = root.tafLaunchSeq
      if (root.tafResultIsStale()) return
      root.scheduleTafRetry()
    }
  }

  Timer {
    id: tafRetryTimer
    interval: 3000
    onTriggered: {
      if (tafProc.running) return
      if (root.tafRetryGeneration !== root.tafGeneration) return
      root.startOrQueueTafFetch(root.buildTafUrl(), root.tafGeneration)
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshManual() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(560), metarColumn.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: metarScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: metarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: metarColumn
          width: metarScroll.width
          spacing: Style.space(14)
          topPadding: Style.space(14)
          bottomPadding: Style.space(14)

          // ---- Header: title + refresh.
          Item {
            width: parent.width
            height: headerRow.implicitHeight

            Row {
              id: headerRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "METAR / TAF"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: root.loading ? "Updating…" : root.formatLastUpdated()
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: Style.space(22)
                height: Style.space(22)
                radius: Math.min(4, Style.cornerRadius)
                color: refreshArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "󰑐"
                  font.family: root.bar.fontFamily
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.pixelSize: Style.font.body

                  RotationAnimator on rotation {
                    running: root.loading
                    from: 0; to: 360
                    duration: 900
                    loops: Animation.Infinite
                  }
                }

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshManual()
                }
              }
            }
          }

          Text {
            visible: root.airportList.length === 0
            text: "No airports configured. Add ICAO codes in this widget's settings."
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
          }

          // ICAO codes are always exactly 4 characters — anything else in
          // the `airports` setting was silently dropped by
          // parseAirportList. Surface it instead of letting a typo just
          // make a station vanish with no explanation.
          Text {
            visible: root.invalidAirportCount > 0
            text: "⚠ Ignored invalid airport code" + (root.invalidAirportCount > 1 ? "s" : "")
              + ": " + root.invalidAirportEntries.join(", ")
              + (root.invalidAirportCount > root.invalidAirportEntries.length
                  ? " (+" + (root.invalidAirportCount - root.invalidAirportEntries.length) + " more)"
                  : "")
              + " (ICAO codes are exactly 4 characters)"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            wrapMode: Text.WordWrap
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
          }

          Repeater {
            model: root.entries

            Column {
              id: card
              required property var modelData
              required property int index
              width: metarColumn.width
              spacing: Style.space(8)

              readonly property var taf: root.tafForIcao(modelData.icao)
              readonly property var metar: modelData.metar
              readonly property var clouds: metar ? metar.clouds : []

              // ---- Divider above every card but the first.
              Rectangle {
                visible: index > 0
                width: parent.width
                height: Style.spacing.hairline
                color: root.bar.foreground
                opacity: 0.12
              }

              // ---- Station row: badge + ICAO + name + category word.
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                spacing: Style.space(12)

                Rectangle {
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: Math.min(6, Style.cornerRadius)
                  color: Style.hoverFillFor(root.bar.foreground, Color.accent)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: card.modelData.letter
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.bold: true
                    font.pixelSize: Style.font.title
                  }
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Row {
                    spacing: Style.space(8)
                    Text {
                      textFormat: Text.PlainText
                      text: card.modelData.icao
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.bold: true
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: card.modelData.category
                      color: Qt.darker(root.bar.foreground, 1.3)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }

                  Text {
                    visible: card.modelData.stationName !== ""
                    textFormat: Text.PlainText
                    text: card.modelData.stationName
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              // ---- Stale/offline banner. Cached data is still shown below
              // (useful context), but never silently as if it were current.
              Text {
                visible: card.modelData.stale === true
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                textFormat: Text.PlainText
                text: "⚠ " + (card.modelData.age !== null && card.modelData.age !== undefined
                  ? "Last observation " + Model.formatAge(card.modelData.age) + " ago — treating as no data."
                  : "Unable to reach aviationweather.gov.")
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
                wrapMode: Text.WordWrap
              }

              // ---- Decoded stats row.
              Row {
                visible: card.metar !== null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                spacing: Style.space(28)

                Column {
                  spacing: Style.space(3)
                  Text { text: "WIND"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  Text { textFormat: Text.PlainText; text: card.metar ? root.formatWind(card.metar.wdir, card.metar.wspd, card.metar.wgst) : "—"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
                }
                Column {
                  spacing: Style.space(3)
                  Text { text: "VIS"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  Text { textFormat: Text.PlainText; text: card.metar ? root.formatVisibility(card.metar) : "—"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                }
                Column {
                  spacing: Style.space(3)
                  Text { text: "TEMP"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  Text { textFormat: Text.PlainText; text: card.metar ? (root.formatTemp(card.metar.temp) + " / " + root.formatTemp(card.metar.dewp)) : "—"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
                }
                Column {
                  spacing: Style.space(3)
                  Text { text: "QNH"; color: Qt.darker(root.bar.foreground, 1.5); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  Text { textFormat: Text.PlainText; text: card.metar ? root.formatAltimeter(card.metar.altim) : "—"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
                }
              }

              Text {
                visible: card.metar !== null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                textFormat: Text.PlainText
                text: card.metar ? "Clouds: " + root.formatClouds(card.clouds) : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.WordWrap
              }

              // ---- METAR: coded or decoded is the primary text (decoded by
              // default), hovering always reveals whichever one isn't shown.
              Text {
                id: metarText
                visible: card.metar !== null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                textFormat: Text.PlainText
                text: card.metar ? (root.decoded ? Model.decodeMetarText(card.metar, root.imperial) : card.metar.rawOb) : ""
                color: Qt.darker(root.bar.foreground, 1.2)
                font.family: root.decoded ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap

                HoverHandler { id: metarHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: root.copyToClipboard(metarText.text, card.modelData.icao + " METAR")
                }
                ToolTip {
                  id: metarToolTip
                  // Cursor-relative, not the Popup default of anchoring at
                  // this Text item's own (0,0) — which put the tooltip at a
                  // different spot per airport card purely because each
                  // block sits at a different offset in the popup, not
                  // because of anything about where you're actually
                  // pointing. HoverHandler's point.position already tracks
                  // the cursor continuously while hovering.
                  x: metarHover.point.position.x + 16
                  y: metarHover.point.position.y + 16
                  visible: metarHover.hovered && card.metar !== null
                  delay: 300
                  width: Style.space(360)
                  text: (card.metar ? (root.decoded ? card.metar.rawOb : Model.decodeMetarText(card.metar, root.imperial)) : "")
                    + "\n\nClick copies the " + (root.decoded ? "decoded" : "coded") + " METAR currently displayed, not the " + (root.decoded ? "coded" : "decoded") + " text in this tooltip"
                  contentItem: Text {
                    width: Style.space(360) - metarToolTip.leftPadding - metarToolTip.rightPadding
                    textFormat: Text.PlainText
                    text: metarToolTip.text
                    color: root.bar.foreground
                    font.family: root.decoded ? "monospace" : root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  background: Rectangle {
                    color: root.bar.background
                    border.color: Qt.darker(root.bar.foreground, 1.4)
                    border.width: 1
                    radius: Style.cornerRadius
                  }
                }
              }

              Text {
                visible: card.metar === null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                text: "Fetching METAR…"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }

              // ---- TAF: same coded/decoded + hover-reveals-the-other pattern.
              Column {
                visible: root.showTaf && card.taf !== null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                spacing: Style.space(4)
                topPadding: Style.space(4)

                Text {
                  text: "TAF"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  id: tafText
                  textFormat: Text.PlainText
                  text: card.taf ? (root.decoded ? Model.decodeTafText(card.taf, root.imperial, root.formatEpoch) : card.taf.rawTAF) : ""
                  color: Qt.darker(root.bar.foreground, 1.2)
                  font.family: root.decoded ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width

                  HoverHandler { id: tafHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    onTapped: root.copyToClipboard(tafText.text, card.modelData.icao + " TAF")
                  }
                  ToolTip {
                    id: tafToolTip
                    x: tafHover.point.position.x + 16
                    y: tafHover.point.position.y + 16
                    visible: tafHover.hovered && card.taf !== null
                    delay: 300
                    width: Style.space(360)
                    text: (card.taf ? (root.decoded ? card.taf.rawTAF : Model.decodeTafText(card.taf, root.imperial, root.formatEpoch)) : "")
                      + "\n\nClick copies the " + (root.decoded ? "decoded" : "coded") + " TAF currently displayed, not the " + (root.decoded ? "coded" : "decoded") + " text in this tooltip"
                    contentItem: Text {
                      width: Style.space(360) - tafToolTip.leftPadding - tafToolTip.rightPadding
                      textFormat: Text.PlainText
                      text: tafToolTip.text
                      color: root.bar.foreground
                      font.family: root.decoded ? "monospace" : root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                    background: Rectangle {
                      color: root.bar.background
                      border.color: Qt.darker(root.bar.foreground, 1.4)
                      border.width: 1
                      radius: Style.cornerRadius
                    }
                  }
                }
              }
            }
          }

          // ---- Attribution. The README credits the data source too, but
          // that's invisible to anyone who only ever sees the bar/popup.
          Text {
            id: attribution
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Data: aviationweather.gov"
            color: attributionArea.containsMouse ? Qt.darker(root.bar.foreground, 1.2) : Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: attributionArea.containsMouse

            MouseArea {
              id: attributionArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Qt.openUrlExternally("https://aviationweather.gov")
            }
          }
        }
      }
    }
  }
}
