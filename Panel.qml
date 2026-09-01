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

  function refresh() {
    metarRetries = 0
    tafRetries = 0
    if (airportList.length === 0) return
    fetchMetar()
    if (root.showTaf) fetchTaf()
    else tafByIcao = {}
  }

  // Entry point for the bar's middle-click / explicit "refresh" action —
  // the only path that shows the transient loading dash.
  function refreshManual() {
    manualRefreshInFlight = true
    refresh()
  }

  function fetchMetar() {
    var url = "https://aviationweather.gov/api/data/metar?ids="
      + encodeURIComponent(airportList.join(",")) + "&format=json"
    metarProc.command = ["curl", "-fsS", "--max-time", "8", url]
    metarProc.running = true
  }

  function fetchTaf() {
    var url = "https://aviationweather.gov/api/data/taf?ids="
      + encodeURIComponent(airportList.join(",")) + "&format=json"
    tafProc.command = ["curl", "-fsS", "--max-time", "8", url]
    tafProc.running = true
  }

  function scheduleMetarRetry() {
    if (metarRetries >= 3) {
      root.metarOffline = true
      root.manualRefreshInFlight = false
      Qt.callLater(root.maybeFinishHoverRefresh)
      return
    }
    metarRetries++
    metarRetryTimer.restart()
  }

  function scheduleTafRetry() {
    if (tafRetries >= 3) {
      Qt.callLater(root.maybeFinishHoverRefresh)
      return
    }
    tafRetries++
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

  Process {
    id: metarProc
    stdout: StdioCollector { id: metarStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // curl -f fails (nonzero) on a transport error or an HTTP error
      // status — that's the only case worth retrying/going offline over.
      // A *successful* request (exit 0) with an empty body happens for a
      // real reason: aviationweather.gov returns HTTP 204 with no content
      // when every requested id is unrecognized (verified live against
      // https://aviationweather.gov/api/data/metar?ids=ZZZZ). Treating
      // that as a transient failure would misreport "your airport list is
      // invalid" as "we're offline" after retries exhaust.
      if (exitCode !== 0) { root.scheduleMetarRetry(); return }

      var raw = String(metarStdout.text || "").trim()
      var parsed = []
      if (raw) {
        try {
          parsed = JSON.parse(raw)
        } catch (e) {
          root.scheduleMetarRetry()
          return
        }
      }

      root.metarByIcao = Model.buildByIcao(parsed)
      // Reassign (not mutate-in-place) so the `entries` binding, which
      // reads this property, actually re-evaluates.
      var seen = {}
      for (var prevIcao in root.everSeenIcaos) seen[prevIcao] = true
      for (var icao in root.metarByIcao) seen[icao] = true
      root.everSeenIcaos = seen
      root.metarRetries = 0
      root.metarEverSucceeded = true
      root.metarOffline = false
      root.manualRefreshInFlight = false
      root.lastUpdated = Date.now() / 1000
      Qt.callLater(root.maybeFinishHoverRefresh)
    }
  }

  Timer {
    id: metarRetryTimer
    interval: 3000
    onTriggered: if (!metarProc.running) root.fetchMetar()
  }

  Process {
    id: tafProc
    stdout: StdioCollector { id: tafStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.scheduleTafRetry(); return }

      var raw = String(tafStdout.text || "").trim()
      var parsed = []
      if (raw) {
        try {
          parsed = JSON.parse(raw)
        } catch (e) {
          root.scheduleTafRetry()
          return
        }
      }

      root.tafByIcao = Model.buildByIcao(parsed)
      root.tafRetries = 0
      Qt.callLater(root.maybeFinishHoverRefresh)
    }
  }

  Timer {
    id: tafRetryTimer
    interval: 3000
    onTriggered: if (!tafProc.running) root.fetchTaf()
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
                text: root.loading ? "Updating…" : (root.lastUpdated > 0 ? "Updated " + root.formatEpoch(root.lastUpdated) : "")
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
            visible: root.invalidAirportEntries.length > 0
            text: "⚠ Ignored invalid airport code" + (root.invalidAirportEntries.length > 1 ? "s" : "")
              + ": " + root.invalidAirportEntries.join(", ") + " (ICAO codes are exactly 4 characters)"
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

                HoverHandler { id: metarHover }
                ToolTip {
                  id: metarToolTip
                  visible: metarHover.hovered && card.metar !== null
                  delay: 300
                  width: Style.space(360)
                  text: card.metar ? (root.decoded ? card.metar.rawOb : Model.decodeMetarText(card.metar, root.imperial)) : ""
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

                  HoverHandler { id: tafHover }
                  ToolTip {
                    id: tafToolTip
                    visible: tafHover.hovered && card.taf !== null
                    delay: 300
                    width: Style.space(360)
                    text: card.taf ? (root.decoded ? card.taf.rawTAF : Model.decodeTafText(card.taf, root.imperial, root.formatEpoch)) : ""
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
