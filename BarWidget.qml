import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "metar-taf"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // Middle click / explicit refresh — shows the transient loading dash.
  function refreshManual() {
    if (panelLoader.item && panelLoader.item.refreshManual) panelLoader.item.refreshManual()
  }

  // Hover — silently refreshes in the background if the data is stale
  // enough (see Panel.qml's hoverRefreshMinutes); only flashes if the
  // refreshed data actually differs from what was already showing.
  function refreshIfStale() {
    if (panelLoader.item && panelLoader.item.refreshIfStale) panelLoader.item.refreshIfStale()
  }

  // Routed through Panel.qml, which owns the environment-cleared,
  // fixed-path Process this actually runs under (see its own
  // sendNotification/notifyProcComponent) — not sent directly from here.
  function sendNotification(text) {
    if (panelLoader.item && panelLoader.item.sendNotification) panelLoader.item.sendNotification(text)
  }

  // {ICAO: true} for whichever station(s) a hover-triggered background
  // refresh just found different text for — not a single whole-bar flag,
  // so only that station's own letter flashes (see the per-letter Row/
  // Column below), not the other configured airports that didn't change.
  readonly property var justUpdatedIcaos: panelLoader.item ? panelLoader.item.justUpdatedIcaos : ({})

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing, matching the other
  // popup-backed bar widgets (see omarchy.weather).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Per-airport {icao, letter, category, stationName, metar}, computed by the
  // panel so there is exactly one place that owns fetch state.
  readonly property var entries: panelLoader.item ? panelLoader.item.entries : []

  readonly property string barText: {
    var parts = []
    for (var i = 0; i < entries.length; i++) parts.push(entries[i].letter)
    return parts.join(" ")
  }

  readonly property bool showStationNameInTooltip: setting("showStationNameInTooltip", true) === true

  readonly property string barTooltip: {
    var lines = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      lines.push(e.icao + "  " + e.category + (root.showStationNameInTooltip && e.stationName ? "  (" + e.stationName + ")" : ""))
    }
    return lines.join("\n")
  }

  visible: barText !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // One Text per airport instead of WidgetButton's own single-string
  // label, so only the station(s) that actually changed can flash — not
  // the whole "V M V" together for one station's update. WidgetButton
  // still owns click/hover/tooltip/sizing (its own label stays sized off
  // the same barText, just invisible); this only replaces what's drawn.
  Component {
    id: letterDelegate
    Text {
      id: letterText
      required property var modelData
      textFormat: Text.PlainText
      text: modelData.letter
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      // Bold, not a color change — color-coding severity is exactly what
      // this plugin's letters (V/M/I/L, not colored red/yellow/green)
      // deliberately avoid, and even a neutral accent color still reads
      // as "using color" against that. Bold is typographic weight, not
      // color, and this codebase already uses it the same way elsewhere
      // (Panel.qml's VIS/Clouds stats) — a station's letter goes bold
      // exactly when a hover-triggered background refresh found different
      // text for it than before, nothing about the weather's severity.
      font.bold: root.justUpdatedIcaos[modelData.icao] === true
      renderType: Text.NativeRendering
      horizontalAlignment: Text.AlignHCenter
      color: root.bar ? root.bar.barForeground : Color.foreground
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    labelVisible: false
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    tooltipText: root.barTooltip

    Row {
      visible: !(root.bar && root.bar.vertical)
      anchors.centerIn: parent
      spacing: Style.space(6)
      Repeater { model: root.entries; delegate: letterDelegate }
    }

    Column {
      visible: root.bar && root.bar.vertical
      anchors.centerIn: parent
      spacing: Style.space(2)
      Repeater { model: root.entries; delegate: letterDelegate }
    }

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.sendNotification(root.barTooltip.replace(/\n/g, " · "))
      else if (b === Qt.MiddleButton) root.refreshManual()
      else root.togglePanel()
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.refreshIfStale()
    }
  }
}
