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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    tooltipText: root.barTooltip

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("omarchy-notification-send " + Util.shellQuote(root.barTooltip.replace(/\n/g, " · ")))
      else if (b === Qt.MiddleButton) root.refreshManual()
      else root.togglePanel()
    }
  }
}
