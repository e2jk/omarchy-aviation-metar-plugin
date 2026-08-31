import QtQuick
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

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
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
  readonly property bool imperial: setting("units", "Metric") === "Imperial"
  readonly property bool showTaf: setting("showTaf", true) === true
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 10), 10) || 10)

  onAirportListChanged: Qt.callLater(refresh)
  onShowTafChanged: Qt.callLater(refresh)

  // ---- Fetch state. Kept on failure so stale data stays visible rather than
  //      flashing to "no data" on a transient network hiccup.
  property var metarByIcao: ({})
  property var tafByIcao: ({})
  property double lastUpdated: 0
  property int metarRetries: 0
  property int tafRetries: 0

  readonly property var entries: Model.buildEntries(airportList, metarByIcao)
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
    if (metarRetries >= 3) return
    metarRetries++
    metarRetryTimer.restart()
  }

  function scheduleTafRetry() {
    if (tafRetries >= 3) return
    tafRetries++
    tafRetryTimer.restart()
  }

  function formatTemp(c) { return Model.formatTemp(c, root.imperial) }
  function formatVisibility(v) { return Model.formatVisibility(v, root.imperial) }
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.scheduleMetarRetry(); return }
        try {
          var parsed = JSON.parse(raw)
          root.metarByIcao = Model.buildByIcao(parsed)
          root.metarRetries = 0
          root.lastUpdated = Date.now() / 1000
        } catch (e) {
          root.scheduleMetarRetry()
        }
      }
    }
  }

  Timer {
    id: metarRetryTimer
    interval: 3000
    onTriggered: if (!metarProc.running) root.fetchMetar()
  }

  Process {
    id: tafProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.scheduleTafRetry(); return }
        try {
          var parsed = JSON.parse(raw)
          root.tafByIcao = Model.buildByIcao(parsed)
          root.tafRetries = 0
        } catch (e) {
          root.scheduleTafRetry()
        }
      }
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
    function refresh(): void { root.refresh() }
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
                  onClicked: root.refresh()
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
                  Text { textFormat: Text.PlainText; text: card.metar ? root.formatVisibility(card.metar.visib) : "—"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
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
                text: card.metar ? root.formatClouds(card.clouds) : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // ---- Raw METAR.
              Text {
                visible: card.metar !== null
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                textFormat: Text.PlainText
                text: card.metar ? card.metar.rawOb : ""
                color: Qt.darker(root.bar.foreground, 1.2)
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
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

              // ---- TAF.
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
                  textFormat: Text.PlainText
                  text: card.taf ? card.taf.rawTAF : ""
                  color: Qt.darker(root.bar.foreground, 1.2)
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }
            }
          }
        }
      }
    }
  }
}
